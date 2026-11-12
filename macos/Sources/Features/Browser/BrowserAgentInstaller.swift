import AppKit

/// Connects agents to KinTerm's tools, only when you ask (the Setup
/// Assistant's Connect Agents, or Browser Options › Let Agents Use the
/// Browser…):
/// - the KinTerm skill (agents/skills/kinterm/SKILL.md), into each Claude
///   Code and Codex account's `skills/kinterm/`, which tells agents about
///   the browser and Review Changes;
/// - the browser's MCP server: `kinterm-browser` is copied to
///   `~/.config/kinterm/browser/` (a path that stays put when KinTerm moves)
///   and added to each Claude Code and Codex account, with their own
///   `mcp add` commands.
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
        let folders = claudeFolders + codexFolders
        let codex = codexFolders
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: cliURL.path) { try? installCLI() }
            for folder in folders where isSkillInstalled(in: folder) { try? installSkill(into: folder) }
            // Added by an older KinTerm: Codex doesn't yet pass on which
            // terminal it runs in.
            for home in codex where codexNeedsSurfaceForwarding(home) { _ = forwardSurfaceToCodex(home) }
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
    static var claudeFolders: [URL] { folders(of: .claude) }

    /// Codex homes: ~/.codex and each account's.
    @MainActor
    static var codexFolders: [URL] { folders(of: .codex) }

    @MainActor
    private static func folders(of agent: AgentKind) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = [home.appendingPathComponent(agent.folderPrefix)]
        for account in AgentAccountStore.shared.accounts(of: agent) {
            let url = account.folder.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(account.id)
            if !urls.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { urls.append(url) }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Connecting

    @MainActor
    static func presentConnect() {
        let folders = claudeFolders
        let codex = codexFolders
        let alert = NSAlert()
        alert.messageText = "Let agents use KinTerm's browser?"
        // The skill comes along: it's what tells agents the browser is there.
        let list = { (urls: [URL]) in
            urls.isEmpty ? "no config folder yet"
                : urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        }
        alert.informativeText = """
            Adds a "\(serverName)" MCP server to Claude Code (\(list(folders))) and Codex (\(list(codex))), \
            if they're installed. Agents can then open pages, click and type, and read the console, \
            network requests and performance of the browser in your KinTerm window.

            It runs `claude mcp add` and `codex mcp add`. Remove it any time with `claude mcp remove \(serverName)` \
            or `codex mcp remove \(serverName)`. Restart running agents to pick it up. Needs Node.js.
            """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        connect(claudeFolders: folders, codexFolders: codex) { report in
                let done = NSAlert()
                done.messageText = report.allSatisfy(\.ok) ? "Agents can use the browser" : "Some agents weren't set up"
                done.informativeText = report.map { "\($0.ok ? "✓" : "✗") \($0.name): \($0.detail)" }
                    .joined(separator: "\n")
                done.runModal()
        }
    }

    /// Install everything, off the main thread, then report on the main
    /// thread.
    static func connect(claudeFolders: [URL], codexFolders: [URL], completion: @escaping ([Outcome]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = connect(claudeFolders: claudeFolders, codexFolders: codexFolders)
            DispatchQueue.main.async { completion(report) }
        }
    }

    struct Outcome {
        let name: String
        let ok: Bool
        let detail: String
    }

    private static func connect(claudeFolders: [URL], codexFolders: [URL]) -> [Outcome] {
        var outcomes: [Outcome] = []
        for folder in claudeFolders + codexFolders {
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
            for folder in codexFolders.isEmpty ? [nil] : codexFolders.map(Optional.some) {
                let env = folder.map { "CODEX_HOME=\(shellQuote($0.path)) " } ?? ""
                _ = shell("\(env)codex mcp remove \(serverName)")
                let result = shell("\(env)codex mcp add \(serverName) --env \(socket) -- \(cli) mcp")
                var detail = result.status == 0 ? "added" : result.output
                if result.status == 0, let folder, !forwardSurfaceToCodex(folder) {
                    detail = "added; update Codex so each agent gets its own tab's browser"
                }
                let name = "Codex" + (folder.map { " (\(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? "")
                outcomes.append(Outcome(name: name, ok: result.status == 0, detail: detail))
            }
        } else {
            outcomes.append(Outcome(name: "Codex", ok: true, detail: "not installed, skipped"))
        }
        return outcomes
    }

    // MARK: Codex

    /// Codex gives MCP servers only the environment it's told to, unlike
    /// Claude Code, which passes its own on. Without KINTERM_SURFACE_ID the
    /// browser can't tell which tab a Codex agent is in, so it would get
    /// the tab in front, and every tab's page; without KINTERM_SOCKET, an
    /// agent in another KinTerm (a debug build) would reach this one.
    private static let codexForwardedVariables = ["KINTERM_SURFACE_ID", "KINTERM_SOCKET"]

    private static func codexConfigURL(_ home: URL) -> URL {
        home.appendingPathComponent("config.toml")
    }

    private static var codexEnvVarsLine: String {
        "env_vars = [" + codexForwardedVariables.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    /// Where the server's table is in Codex's config, its `env_vars` line
    /// if it has one, and whether that forwards everything needed.
    private static func codexServerTable(in lines: [String]) -> (header: Int, envVars: Int?, forwards: Bool)? {
        let headers = ["[mcp_servers.\(serverName)]", "[mcp_servers.\"\(serverName)\"]"]
        guard let header = lines.firstIndex(where: { headers.contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        for index in (header + 1)..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if trimmed.hasPrefix("env_vars") {
                let forwards = codexForwardedVariables.allSatisfy { trimmed.contains("\"\($0)\"") }
                return (header, index, forwards)
            }
        }
        return (header, nil, false)
    }

    /// Whether Codex has the browser's MCP server but doesn't forward the
    /// terminal to it.
    static func codexNeedsSurfaceForwarding(_ home: URL) -> Bool {
        guard let text = try? String(contentsOf: codexConfigURL(home), encoding: .utf8),
              let table = codexServerTable(in: text.components(separatedBy: "\n")) else { return false }
        return !table.forwards
    }

    /// Have Codex pass KINTERM_SURFACE_ID and KINTERM_SOCKET on to the
    /// browser's MCP server (its `env_vars`). If this Codex doesn't understand that, its config
    /// is put back as it was. Returns whether Codex now forwards it.
    @discardableResult
    static func forwardSurfaceToCodex(_ home: URL) -> Bool {
        let url = codexConfigURL(home)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = original.components(separatedBy: "\n")
        guard let table = codexServerTable(in: lines) else { return false }
        if table.forwards { return true }
        if let existing = table.envVars {
            // Ours, from an earlier KinTerm, short of a variable.
            guard lines[existing].contains("KINTERM_") else { return false }
            lines[existing] = codexEnvVarsLine
        } else {
            lines.insert(codexEnvVarsLine, at: table.header + 1)
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        // An older Codex rejects keys it doesn't know; it must still start.
        if shell("CODEX_HOME=\(shellQuote(home.path)) codex mcp get \(serverName)").status == 0 { return true }
        try? original.write(to: url, atomically: true, encoding: .utf8)
        return false
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
