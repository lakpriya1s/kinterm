import AppKit

/// Connects agents to KinTerm's tools, only when you ask (the Setup
/// Assistant's Connect Agents, or Browser Options › Let Agents Use the
/// Browser…):
/// - the KinTerm skill (agents/skills/kinterm/SKILL.md), into each Claude
///   Code account's `skills/kinterm/`, which tells agents about the browser
///   and Review Changes;
/// - the browser's MCP server: `kinterm-browser` is copied to
///   `~/.config/kinterm/browser/` (a path that stays put when KinTerm moves)
///   and added to Claude Code, for each account, and to Codex, with their
///   own `mcp add` commands.
enum BrowserAgentInstaller {
    static let serverName = "kinterm-browser"

    private static let files = ["kinterm-browser", "kinterm-browser-mcp.mjs"]

    static var directory: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let config = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("kinterm/browser")
    }

    static var cliURL: URL { directory.appendingPathComponent("kinterm-browser") }

    /// The bundled copy of a file: the CLI is in Contents/MacOS (on the
    /// terminals' PATH), the MCP script in Resources/browser.
    private static func bundled(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent("browser/\(name)"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// After an update, refresh copies that are already installed: the CLI
    /// and the skill.
    @MainActor
    static func updateInstalledCLI() {
        let folders = claudeFolders
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: cliURL.path) { try? installCLI() }
            for folder in folders where isSkillInstalled(in: folder) { try? installSkill(into: folder) }
        }
    }

    // MARK: The skill

    private static var bundledSkill: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("agents/skills/kinterm/SKILL.md")
    }

    private static func skillURL(in folder: URL) -> URL {
        folder.appendingPathComponent("skills/kinterm/SKILL.md")
    }

    static func isSkillInstalled(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: skillURL(in: folder).path)
    }

    private static func installSkill(into folder: URL) throws {
        guard let bundled = bundledSkill, let data = try? Data(contentsOf: bundled) else {
            throw InstallError.skillMissing
        }
        let target = skillURL(in: folder)
        if (try? Data(contentsOf: target)) == data { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    enum InstallError: LocalizedError {
        case skillMissing
        var errorDescription: String? { "This copy of KinTerm doesn't include the KinTerm skill." }
    }

    private static func installCLI() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in files {
            guard let source = bundled(name) else { throw BrowserEngine.Failure.notInstalled }
            let target = directory.appendingPathComponent(name)
            if let new = try? Data(contentsOf: source), (try? Data(contentsOf: target)) == new { continue }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
    }

    /// Claude Code config folders: ~/.claude and each account's.
    @MainActor
    static var claudeFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var ids = [".claude"]
        for account in AgentAccountStore.shared.accounts where !ids.contains(account.id) {
            ids.append(account.id)
        }
        return ids.map { home.appendingPathComponent($0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: Connecting

    @MainActor
    static func presentConnect() {
        let folders = claudeFolders
        let alert = NSAlert()
        alert.messageText = "Let agents use KinTerm's browser?"
        // The skill comes along: it's what tells agents the browser is there.
        let accounts = folders.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        alert.informativeText = """
            Adds a "\(serverName)" MCP server to Claude Code (\(accounts.isEmpty ? "no config folder yet" : accounts)) \
            and Codex, if they're installed. Agents can then open pages, click and type, and read the console, \
            network requests and performance of the browser in your KinTerm window.

            It runs `claude mcp add` and `codex mcp add`. Remove it any time with `claude mcp remove \(serverName)`. \
            Restart running agents to pick it up. Needs Node.js.
            """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        connect(claudeFolders: folders) { report in
                let done = NSAlert()
                done.messageText = report.allSatisfy(\.ok) ? "Agents can use the browser" : "Some agents weren't set up"
                done.informativeText = report.map { "\($0.ok ? "✓" : "✗") \($0.name): \($0.detail)" }
                    .joined(separator: "\n")
                done.runModal()
        }
    }

    /// Install everything, off the main thread, then report on the main
    /// thread.
    static func connect(claudeFolders: [URL], completion: @escaping ([Outcome]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = connect(claudeFolders: claudeFolders)
            DispatchQueue.main.async { completion(report) }
        }
    }

    struct Outcome {
        let name: String
        let ok: Bool
        let detail: String
    }

    private static func connect(claudeFolders: [URL]) -> [Outcome] {
        var outcomes: [Outcome] = []
        for folder in claudeFolders {
            let name = "KinTerm skill (\((folder.path as NSString).abbreviatingWithTildeInPath))"
            do {
                try installSkill(into: folder)
                outcomes.append(Outcome(name: name, ok: true, detail: "installed"))
            } catch {
                outcomes.append(Outcome(name: name, ok: false, detail: error.localizedDescription))
            }
        }

        // The browser's tools, if this KinTerm has the browser.
        guard BrowserEngine.isInstalled else { return outcomes }
        do {
            try installCLI()
        } catch {
            return outcomes + [Outcome(name: "kinterm-browser", ok: false, detail: error.localizedDescription)]
        }
        let cli = shellQuote(cliURL.path)
        let socket = shellQuote("KINTERM_BROWSER_SOCKET=\(BrowserControlServer.socketPath)")

        let haveClaude = shell("command -v claude").status == 0
        if haveClaude {
            for folder in claudeFolders.isEmpty ? [nil] : claudeFolders.map(Optional.some) {
                let env = folder.map { "CLAUDE_CONFIG_DIR=\(shellQuote($0.path)) " } ?? ""
                _ = shell("\(env)claude mcp remove --scope user \(serverName)")
                let result = shell("\(env)claude mcp add \(serverName) --scope user -e \(socket) -- \(cli) mcp")
                let name = "Claude Code" + (folder.map { " (\(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? "")
                outcomes.append(Outcome(name: name, ok: result.status == 0, detail: result.status == 0 ? "added" : result.output))
            }
        } else {
            outcomes.append(Outcome(name: "Claude Code", ok: true, detail: "not installed, skipped"))
        }

        if shell("command -v codex").status == 0 {
            _ = shell("codex mcp remove \(serverName)")
            let result = shell("codex mcp add \(serverName) --env \(socket) -- \(cli) mcp")
            outcomes.append(Outcome(name: "Codex", ok: result.status == 0, detail: result.status == 0 ? "added" : result.output))
        } else {
            outcomes.append(Outcome(name: "Codex", ok: true, detail: "not installed, skipped"))
        }
        return outcomes
    }

    /// Run a command in your login shell, so `claude` and `codex` are on
    /// the PATH as they are in a terminal.
    private static func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, String(output.suffix(300)))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
