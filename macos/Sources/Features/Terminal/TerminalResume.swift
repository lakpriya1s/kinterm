import AppKit
import CryptoKit
import GhosttyKit
import OSLog

/// Brings back what was in terminals when KinTerm reopens them after a
/// restart or a crash. Window restoration (see `TerminalRestorable`) only
/// brings back the layout: each terminal starts a new shell in its old
/// folder. On top of that:
///
/// - An agent tab resumes its session. The status hooks (see
///   `AgentHookInstaller`) record each session in
///   `~/.config/kinterm/sessions/<terminal id>`, and a reopened terminal
///   keeps its id. A session you end yourself is forgotten.
/// - Any other terminal shows its old output again, with its colors, above
///   the new prompt. KinTerm saves the last `maxRows` rows of each terminal
///   every `saveInterval` seconds and when it quits, so a crash loses at most
///   that much.
enum TerminalResume {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "resume")

    /// How many rows of output each terminal keeps for next time.
    static let maxRows: UInt32 = 2000

    /// How often terminals' output is saved, in seconds.
    static let saveInterval: TimeInterval = 20

    /// A session record older than this, from a terminal that isn't open,
    /// is deleted. Records of terminals in another running KinTerm (such as
    /// a development build) share the folder, so they aren't deleted sooner.
    private static let staleSessionAge: TimeInterval = 30 * 24 * 60 * 60

    // MARK: Agent sessions

    struct AgentSession {
        let agent: AgentKind
        let id: String
        /// The account's config folder, or nil for the default one.
        let configFolder: String?
        /// The folder the session started in, where the agent looks for it.
        let folder: String?

        /// The command that resumes it.
        var command: String {
            switch agent {
            case .claude: return "\(agent.command) --resume \(id)"
            case .codex: return "\(agent.command) resume \(id)"
            }
        }
    }

    /// Where the status hooks record sessions; the same path as theirs.
    static var sessionsFolder: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let config = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("kinterm/sessions")
    }

    /// The agent session that was running in terminal `id`, if any.
    static func agentSession(for id: UUID) -> AgentSession? {
        let url = sessionsFolder.appendingPathComponent(id.uuidString)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }

        // The id goes into a command line, so only accept what the hooks
        // write: letters, digits, "-" and "_".
        guard let agent = values["agent"].flatMap(AgentKind.init(rawValue:)),
              let session = values["session"], !session.isEmpty,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }

        let configFolder = values["config"].flatMap { $0.isEmpty ? nil : $0 }
        guard hasConversation(agent: agent, session: session, configFolder: configFolder) else {
            logger.info("not resuming \(session, privacy: .public): nothing saved for it")
            return nil
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let folder = values["cwd"]
        return AgentSession(
            agent: agent,
            id: session,
            configFolder: configFolder,
            folder: folder.flatMap { fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil })
    }

    /// Whether the agent saved the session's conversation, so resuming it
    /// works. Claude Code only saves one after its first message, as
    /// `<config>/projects/<folder>/<id>.jsonl`, in the account's config
    /// folder (`~/.claude` by default). Codex is assumed to have it.
    private static func hasConversation(agent: AgentKind, session: String, configFolder: String?) -> Bool {
        guard agent == .claude else { return true }
        let config = configFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = config.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: projects.path) else { return false }
        return folders.contains {
            fm.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent("\(session).jsonl").path)
        }
    }

    /// Change a reopened terminal's configuration so it resumes its agent
    /// session. Returns false if it had none.
    static func resumeAgent(for id: UUID, in config: inout Ghostty.SurfaceConfiguration) -> Bool {
        guard let session = agentSession(for: id) else { return false }
        if let folder = session.folder { config.workingDirectory = folder }
        if let configFolder = session.configFolder {
            config.environmentVariables[session.agent.configVariable] = configFolder
        }
        // Typed into the shell, like a new agent tab, so the shell stays
        // when the agent exits.
        config.initialInput = "\(session.command)\n"
        logger.info("resuming \(session.agent.rawValue, privacy: .public) session in \(id.uuidString, privacy: .public)")
        return true
    }

    // MARK: Output

    /// Where terminals' output is saved, per app so two KinTerms (such as a
    /// development build) don't mix theirs.
    static var outputFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty")
            .appendingPathComponent("terminal-output")
    }

    private static func outputURL(for id: UUID) -> URL {
        outputFolder.appendingPathComponent("\(id.uuidString).vt")
    }

    /// Show terminal `id`'s saved output in its new surface. Call it right
    /// after creating the surface, before its shell prints anything.
    static func restoreOutput(for id: UUID, into surface: ghostty_surface_t) {
        guard let data = try? Data(contentsOf: outputURL(for: id)), !data.isEmpty else { return }
        // A dim line between the old output and the new shell.
        var bytes = data
        bytes.append(contentsOf: Array("\u{1b}[0m\r\n\u{1b}[2m── restored after restart ──\u{1b}[0m\r\n".utf8))
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_restore_output(surface, base, UInt(raw.count))
        }
        savedHashes[id] = nil
    }

    /// The hash of what was last saved for each terminal, to skip writing
    /// output that hasn't changed.
    private static var savedHashes: [UUID: SHA256.Digest] = [:]
    private static var timer: Timer?

    /// Start saving terminals' output regularly.
    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { _ in
            MainActor.assumeIsolated { saveAll() }
        }
        timer?.tolerance = 5
    }

    /// Every terminal in every window, including the quick terminal.
    private static var surfaces: [Ghostty.SurfaceView] {
        NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { Array($0.surfaceTree) }
    }

    /// Save the output of every open terminal, and delete what was saved
    /// for terminals that are gone.
    @MainActor
    static func saveAll() {
        // Windows aren't restored, so neither is their output.
        if (NSApp.delegate as? AppDelegate)?.ghostty.config.windowSaveState == "never" { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        var live = Set<UUID>()
        for view in surfaces {
            live.insert(view.id)
            guard let surface = view.surface else { continue }
            let url = outputURL(for: view.id)

            // An agent tab resumes its session, which shows the
            // conversation itself.
            if agentSession(for: view.id) != nil {
                if savedHashes.removeValue(forKey: view.id) != nil || fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                continue
            }

            var text = ghostty_text_s()
            guard ghostty_surface_read_restore_text(surface, maxRows, &text) else {
                if savedHashes.removeValue(forKey: view.id) != nil { try? fm.removeItem(at: url) }
                continue
            }
            let data = Data(bytes: text.text, count: Int(text.text_len))
            ghostty_surface_free_text(surface, &text)

            let hash = SHA256.hash(data: data)
            guard savedHashes[view.id] != hash else { continue }
            do {
                try data.write(to: url, options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                savedHashes[view.id] = hash
            } catch {
                logger.warning("saving output failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Output of terminals that were closed.
        if let files = try? fm.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "vt" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      !live.contains(id) else { continue }
                try? fm.removeItem(at: file)
                savedHashes[id] = nil
            }
        }

        // Session records nobody has touched in a long time.
        if let files = try? fm.contentsOfDirectory(
            at: sessionsFolder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-staleSessionAge)
            for file in files {
                guard let id = UUID(uuidString: file.lastPathComponent), !live.contains(id),
                      let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }
}
