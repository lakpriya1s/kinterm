import CryptoKit
import Foundation

/// Installs KinTerm's status hooks, which report what an agent is doing for
/// its tab's face:
/// - Claude Code: the same as `agents/claude-code/install.sh`, but without
///   needing `jq`. The hook (bundled in the app) is copied to
///   `~/.config/kinterm/agents/claude-code/`, and a Claude config folder's
///   `settings.json` runs it for every event it reports.
/// - Codex: the hook is copied to `~/.config/kinterm/agents/codex/`, a Codex
///   home's `hooks.json` runs it, and its `config.toml` records that you
///   trust it, as Codex's `/hooks` would, so it runs without asking.
enum AgentHookInstaller {
    enum InstallError: LocalizedError {
        case hookMissing(AgentKind)
        case unreadableSettings(URL)

        var errorDescription: String? {
            switch self {
            case .hookMissing(let agent):
                return "This copy of KinTerm doesn't include the \(agent.displayName) hook."
            case .unreadableSettings(let url):
                return "\((url.path as NSString).abbreviatingWithTildeInPath) isn't valid JSON, so it was left alone."
            }
        }
    }

    /// The hook's file name, bundled and installed.
    private static func hookName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "kinterm-agent-status"
        case .codex: return "kinterm-codex-status"
        }
    }

    /// Claude hook entries from before the rename are replaced too.
    private static let ourClaudeHooks = ["kinterm-agent-status", "ghostty-agent-status"]

    /// The Claude Code events the hook reports, with their matcher.
    private static let claudeEvents: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"),
        ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]

    /// The Codex events the hook reports: their name in `hooks.json`, their
    /// key in Codex's trust records, and the timeout (Codex allows at most
    /// 3 seconds for SessionEnd and Interrupt).
    private static let codexEvents: [(name: String, key: String, timeout: Int)] = [
        ("SessionStart", "session_start", 5), ("UserPromptSubmit", "user_prompt_submit", 5),
        ("PreToolUse", "pre_tool_use", 5), ("PostToolUse", "post_tool_use", 5),
        ("PermissionRequest", "permission_request", 5), ("PostModelRequest", "post_model_request", 5),
        ("Stop", "stop", 5), ("Interrupt", "interrupt", 3), ("SessionEnd", "session_end", 3),
    ]

    /// Where an agent's hook is installed, which its config points at.
    static func hookURL(_ agent: AgentKind) -> URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let config = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let folder = agent == .claude ? "claude-code" : "codex"
        return config.appendingPathComponent("kinterm/agents/\(folder)/\(hookName(agent))")
    }

    /// The file in a config folder that runs the hook.
    private static func configFile(_ agent: AgentKind, in folder: URL) -> URL {
        folder.appendingPathComponent(agent == .claude ? "settings.json" : "hooks.json")
    }

    /// Whether a config folder already runs the hook.
    static func isInstalled(in folder: URL, for agent: AgentKind) -> Bool {
        guard let data = try? Data(contentsOf: configFile(agent, in: folder)),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(hookName(agent))
    }

    /// Copy the hook into place and add it to `folder`'s config. Before the
    /// first change, the config file is copied to `<file>.before-kinterm`.
    /// Installing twice is safe.
    static func install(into folder: URL, for agent: AgentKind) throws {
        try installHook(agent)

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let configURL = configFile(agent, in: folder)
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings(configURL)
            }
            config = object
            let backup = folder.appendingPathComponent(configURL.lastPathComponent + ".before-kinterm")
            if !fm.fileExists(atPath: backup.path) {
                try data.write(to: backup)
            }
        }

        let command = hookURL(agent).path
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        // Where our entry is in each event's list, for Codex's trust records.
        var positions: [(key: String, index: Int, timeout: Int)] = []
        switch agent {
        case .claude:
            for event in claudeEvents {
                var entries = (hooks[event.name] as? [[String: Any]] ?? []).filter { !isOurs($0, agent) }
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if let matcher = event.matcher { entry["matcher"] = matcher }
                entries.append(entry)
                hooks[event.name] = entries
            }
        case .codex:
            for event in codexEvents {
                var entries = (hooks[event.name] as? [[String: Any]] ?? []).filter { !isOurs($0, agent) }
                entries.append(["hooks": [["type": "command", "command": command, "timeout": event.timeout]]])
                hooks[event.name] = entries
                positions.append((event.key, entries.count - 1, event.timeout))
            }
        }
        config["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)

        if agent == .codex {
            try trustCodexHooks(in: folder, hooksFile: configURL, command: command, positions: positions)
        }
    }

    /// Replace installed hooks that differ from the ones in this app, so an
    /// update's hook changes reach configs that already run them. Does
    /// nothing for a hook that isn't installed. (Codex trusts a hook by its
    /// entry in `hooks.json`, not the script's contents, so this needs no
    /// new trust.)
    static func updateInstalledHook() {
        DispatchQueue.global(qos: .utility).async {
            for agent in AgentKind.allCases {
                let url = hookURL(agent)
                guard FileManager.default.fileExists(atPath: url.path),
                      let bundled = Bundle.main.url(forResource: hookName(agent), withExtension: nil),
                      let new = try? Data(contentsOf: bundled),
                      (try? Data(contentsOf: url)) != new else { continue }
                try? installHook(agent)
            }
        }
    }

    /// Copy the bundled hook to `hookURL`, replacing an older copy.
    private static func installHook(_ agent: AgentKind) throws {
        guard let bundled = Bundle.main.url(forResource: hookName(agent), withExtension: nil) else {
            throw InstallError.hookMissing(agent)
        }
        let url = hookURL(agent)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.copyItem(at: bundled, to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A hook entry that runs our hook (for Claude, also the one from
    /// before the rename).
    private static func isOurs(_ entry: [String: Any], _ agent: AgentKind) -> Bool {
        let commands = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        let names = agent == .claude ? ourClaudeHooks : [hookName(agent)]
        return commands.contains { command in names.contains { command.contains($0) } }
    }

    // MARK: Codex trust

    /// Record in the Codex home's `config.toml` that the hook's entries are
    /// trusted, the way Codex's `/hooks` does: under
    /// `[hooks.state."<hooks.json>:<event>:<group>:<handler>"]`, the hash of
    /// the entry (Codex's `hook_hash`: SHA-256 of the entry as JSON with
    /// sorted keys). Codex runs a hook only when that hash matches.
    private static func trustCodexHooks(
        in folder: URL,
        hooksFile: URL,
        command: String,
        positions: [(key: String, index: Int, timeout: Int)]
    ) throws {
        let configURL = folder.appendingPathComponent("config.toml")
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let backup = folder.appendingPathComponent("config.toml.before-kinterm")
        if !original.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try original.write(to: backup, atomically: true, encoding: .utf8)
        }

        // Codex names the file by its path; a home reached through a
        // symlink may be named either way.
        let paths = Array(Set([hooksFile.path, hooksFile.resolvingSymlinksInPath().path]))
        var records: [(key: String, hash: String)] = []
        for path in paths {
            for position in positions {
                let identity: [String: Any] = [
                    "event_name": position.key,
                    "hooks": [["type": "command", "command": command, "timeout": position.timeout, "async": false]],
                ]
                let json = try JSONSerialization.data(
                    withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
                let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
                records.append(("\(path):\(position.key):\(position.index):0", "sha256:\(digest)"))
            }
        }

        // Replace earlier records for these keys. Records left from other
        // positions do no harm: the hash is of our entry, so it matches no
        // other hook.
        let keys = Set(records.map { "[hooks.state.\"\(tomlEscape($0.key))\"]" })
        var lines: [String] = []
        var skipping = false
        for line in original.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { skipping = keys.contains(trimmed) }
            if !skipping { lines.append(line) }
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }

        for record in records {
            lines.append("")
            lines.append("[hooks.state.\"\(tomlEscape(record.key))\"]")
            lines.append("trusted_hash = \"\(record.hash)\"")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func tomlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
