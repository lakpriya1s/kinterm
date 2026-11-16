import AppKit
import Foundation

/// The `kinterm-ctl` commands that act on terminals rather than the browser:
/// panes and agent tabs a terminal starts, reading and typing into them,
/// its own scrollback, status, notifications, the review and the Markdown
/// Viewer. They come in
/// over the browser's socket (`BrowserControlServer`), which hands them
/// here.
///
/// Every one of them acts as the terminal it came from, and only once that
/// is proven (see `ControlPeer`): a terminal controls itself and the
/// terminals it started ("workers"), never the user's other tabs. A worker
/// can't start workers of its own unless it was allowed to.
@MainActor
enum KinTermControl {
    static let commands: Set<String> = [
        "spawn", "workers", "read", "send", "kill", "release",
        "scrollback", "notify", "set-status", "review", "markdown",
    ]

    /// At most this many workers per terminal, so a runaway loop can't
    /// fill the screen with tabs.
    static let maxWorkers = 12

    static func handle(_ request: [String: Any], peer: pid_t?) -> [String: Any] {
        func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

        // Who's asking, proven.
        guard let id = request["surface"] as? String else {
            return fail("Run this in a KinTerm terminal (KINTERM_SURFACE_ID isn't set).")
        }
        guard let (controller, caller) = Self.surface(id: id) else {
            return fail("The terminal this came from is closed.")
        }
        guard ControlPeer.isFrom(peer, surface: caller) == true else {
            return fail("KinTerm couldn't confirm this came from the terminal it names, so it won't act for it.")
        }

        let workers = AgentWorkers.shared
        let command = request["cmd"] as? String ?? ""
        var reply: [String: Any] = ["ok": true]

        func worker() -> AgentWorkers.Worker? {
            guard let name = request["name"] as? String else { return nil }
            return workers.worker(named: name, of: caller)
        }

        switch command {
        case "spawn":
            switch workers.spawn(request, from: caller, in: controller) {
            case .success(let made): reply["worker"] = made.summary
            case .failure(let error): return fail(error.message)
            }

        case "workers":
            reply["workers"] = workers.workers(of: caller).map(\.summary)

        case "read":
            guard let worker = worker() else { return fail(noWorker(request)) }
            guard let surface = worker.surface else { return fail("\(worker.name) has exited.") }
            reply["text"] = tail(surface.cachedScreenContents.get(), lines: request["lines"] as? Int)

        case "send":
            guard let worker = worker() else { return fail(noWorker(request)) }
            guard let surface = worker.surface, let model = surface.surfaceModel else {
                return fail("\(worker.name) has exited.")
            }
            let text = request["text"] as? String ?? ""
            if !text.isEmpty { model.sendText(text) }
            if request["enter"] as? Bool ?? true {
                // After the text lands: a prompt that takes it as a paste
                // would otherwise read Return as part of it.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(text.isEmpty ? 0 : 150)) {
                    surface.surfaceModel?.sendKeyEvent(.init(key: .enter, text: "\r"))
                }
            }
            worker.lastInput = Date()

        case "kill":
            guard let worker = worker() else { return fail(noWorker(request)) }
            workers.kill(worker)

        case "release":
            guard let worker = worker() else { return fail(noWorker(request)) }
            workers.release(worker)

        case "scrollback":
            reply["text"] = tail(caller.cachedScreenContents.get(), lines: request["lines"] as? Int)

        case "notify":
            let body = request["body"] as? String ?? ""
            guard !body.isEmpty else { return fail("Say what to notify about.") }
            caller.showUserNotification(
                title: request["title"] as? String ?? "KinTerm",
                body: body,
                requireFocus: false)

        case "set-status":
            guard let state = (request["state"] as? String).flatMap(Self.state) else {
                return fail("State is one of: idle, working, done, blocked, error, clear.")
            }
            let previous = caller.programStatus
            caller.updateProgramStatus(.init(
                state: state, kind: state == .blocked ? .question : nil, progress: nil,
                app: previous?.app ?? "kinterm", title: previous?.title,
                msg: (request["msg"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(180)) },
                account: nil, context: nil, shells: nil, last: nil, id: nil))

        case "review":
            let files = request["files"] as? [String] ?? []
            let directory = (request["directory"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            ReviewCenter.shared.show(for: controller, files: files, directory: directory)

        case "markdown":
            guard let path = request["path"] as? String, path.hasPrefix("/") else {
                return fail("Say which Markdown file or folder to show.")
            }
            switch MarkdownViewerCenter.target(path) {
            case .file(let url): MarkdownViewerCenter.shared.open(file: url, for: controller)
            case .folder(let url): MarkdownViewerCenter.shared.open(folder: url, for: controller)
            case .missing: return fail("There's nothing at \(path).")
            case .notMarkdown: return fail("\(path) isn't a Markdown file (.md, .markdown, .mdx).")
            }

        default:
            return fail("Unknown command \(command).")
        }

        return reply
    }

    private static func noWorker(_ request: [String: Any]) -> String {
        let name = request["name"] as? String ?? ""
        return name.isEmpty
            ? "Say which worker (a name from `kinterm-ctl agent list`)."
            : "No worker named \(name) started from this terminal. See `kinterm-ctl agent list`."
    }

    private static func state(_ name: String) -> Ghostty.Action.ProgramStatus.State? {
        switch name {
        case "idle": return .idle
        case "working": return .working
        case "done": return .done
        case "blocked": return .blocked
        case "error": return .error
        case "clear": return .clear
        default: return nil
        }
    }

    /// The last `lines` lines of a terminal's text, without the blank rows
    /// below the cursor.
    static func tail(_ text: String, lines: Int?) -> String {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        let count = min(max(lines ?? 200, 1), 10000)
        return rows.suffix(count).joined(separator: "\n")
    }

    /// A terminal by its KINTERM_SURFACE_ID, and the tab it's in.
    static func surface(id: String) -> (BaseTerminalController, Ghostty.SurfaceView)? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController,
                  let surface = controller.surfaceTree.first(where: { $0.id == uuid }) else { continue }
            return (controller, surface)
        }
        return nil
    }
}

// MARK: Workers

/// The terminals each terminal started: agent tabs (`kinterm-ctl agent spawn`)
/// and panes beside it (`kinterm-ctl run`). The grant to control a worker is
/// this record, kept here in the app where nothing in a terminal can
/// change it. It lasts while KinTerm runs: after a restart the tabs come
/// back as ordinary tabs.
@MainActor
final class AgentWorkers {
    static let shared = AgentWorkers()

    final class Worker {
        enum Kind: String { case tab, pane }

        let name: String
        let kind: Kind
        let parent: UUID
        let command: String
        let allowSpawn: Bool
        let started = Date()
        weak var surface: Ghostty.SurfaceView?
        /// When the parent last typed into it. A turn that ended before
        /// this was for an earlier message.
        var lastInput = Date()
        /// When a command in it last ended and the shell was back at its
        /// prompt (shell integration tells), and how: a worker that runs
        /// one command (`codex exec`, `make test`) is done then.
        var commandEnded: (at: Date, exitCode: Int?)?

        init(name: String, kind: Kind, parent: UUID, command: String, allowSpawn: Bool, surface: Ghostty.SurfaceView) {
            self.name = name
            self.kind = kind
            self.parent = parent
            self.command = command
            self.allowSpawn = allowSpawn
            self.surface = surface
        }

        var summary: [String: Any] {
            var out: [String: Any] = [
                "name": name,
                "kind": kind.rawValue,
                "command": command,
                "started": started.timeIntervalSince1970,
            ]
            guard let surface else {
                out["state"] = "exited"
                out["settled"] = true
                return out
            }
            if let pwd = surface.pwd { out["cwd"] = pwd }
            guard let status = surface.programStatus else {
                // Nothing reporting a status. Back at the shell's prompt
                // since it was last given something: its command ended.
                if let ended = commandEnded, ended.at >= lastInput {
                    out["state"] = "exited-command"
                    if let code = ended.exitCode { out["exitCode"] = code }
                    out["settled"] = true
                } else {
                    out["state"] = "none"
                    out["settled"] = false
                }
                return out
            }
            out["state"] = Self.stateName(status.state)
            out["since"] = status.since.timeIntervalSince1970
            if let app = status.app { out["app"] = app }
            if let msg = status.msg { out["msg"] = msg }
            if let last = status.last { out["last"] = last }
            if let kind = status.kind { out["needs"] = "\(kind)" }
            // Finished, or waiting on someone, since it was last given
            // something to do.
            let resting: Set<Ghostty.Action.ProgramStatus.State> = [.done, .blocked, .error]
            out["settled"] = resting.contains(status.state) && status.since >= lastInput
            return out
        }

        private static func stateName(_ state: Ghostty.Action.ProgramStatus.State) -> String {
            switch state {
            case .idle: return "idle"
            case .working: return "working"
            case .done: return "done"
            case .blocked: return "blocked"
            case .error: return "error"
            case .clear: return "none"
            }
        }
    }

    struct Failure: Error { let message: String }

    /// By the worker's terminal.
    private var all: [UUID: Worker] = [:]

    func workers(of parent: Ghostty.SurfaceView) -> [Worker] {
        prune()
        return all.values.filter { $0.parent == parent.id }.sorted { $0.started < $1.started }
    }

    func worker(named name: String, of parent: Ghostty.SurfaceView) -> Worker? {
        workers(of: parent).first { $0.name == name }
    }

    /// Start a worker: a tab next to the parent's, or a pane beside it.
    /// Its command is typed into a shell, so the terminal stays open after
    /// the command ends and you can see how it ended.
    func spawn(
        _ request: [String: Any],
        from parent: Ghostty.SurfaceView,
        in controller: BaseTerminalController
    ) -> Result<Worker, Failure> {
        let kind: Worker.Kind = (request["kind"] as? String) == "pane" ? .pane : .tab
        let command = (request["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Workers start workers only when allowed: one bad prompt shouldn't
        // turn into forty tabs.
        if let me = all[parent.id], !me.allowSpawn, kind == .tab {
            return .failure(.init(message:
                "This terminal is a worker started by another agent, and wasn't allowed to start agents of its own."))
        }
        guard workers(of: parent).filter({ $0.surface != nil }).count < KinTermControl.maxWorkers else {
            return .failure(.init(message:
                "This terminal already runs \(KinTermControl.maxWorkers) workers. Stop some with `kinterm-ctl agent kill`."))
        }

        var name = (request["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = uniqueName(base: kind == .pane ? "pane" : "agent", for: parent) }
        guard name.count <= 32,
              name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            return .failure(.init(message: "A name is letters, digits, '.', '_' and '-', at most 32."))
        }
        if let existing = worker(named: name, of: parent) {
            guard existing.surface == nil else {
                return .failure(.init(message: "There's already a worker named \(name)."))
            }
            forget(existing)
        }

        var config = Ghostty.SurfaceConfiguration()
        if let cwd = request["cwd"] as? String, !cwd.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.init(message: "No folder at \(cwd)."))
            }
            config.workingDirectory = cwd
        } else if let pwd = parent.pwd {
            config.workingDirectory = pwd
        }
        if !command.isEmpty { config.initialInput = command + "\n" }
        config.environmentVariables["KINTERM_PARENT_SURFACE_ID"] = parent.id.uuidString
        config.environmentVariables["KINTERM_WORKER_NAME"] = name

        let made: Ghostty.SurfaceView
        switch kind {
        case .pane:
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
            switch request["direction"] as? String {
            case "left": direction = .left
            case "up": direction = .up
            case "down": direction = .down
            default: direction = .right
            }
            guard let view = controller.newSplit(at: parent, direction: direction, baseConfig: config) else {
                return .failure(.init(message: "KinTerm couldn't split this terminal."))
            }
            made = view

        case .tab:
            guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty,
                  let tab = TerminalController.newTab(ghostty, from: controller.window, withBaseConfig: config),
                  let view = tab.surfaceTree.first(where: { _ in true }) else {
                return .failure(.init(message: "KinTerm couldn't open a tab."))
            }
            tab.titleOverride = "⤷ \(name)"
            made = view
        }

        // Starting a worker doesn't take the keyboard from you.
        let keepFocus = { [weak controller, weak parent] in
            guard let controller, let parent else { return }
            if kind == .tab { controller.window?.makeKeyAndOrderFront(nil) }
            controller.focusSurface(parent)
        }
        keepFocus()
        DispatchQueue.main.async(execute: keepFocus)

        let worker = Worker(
            name: name, kind: kind, parent: parent.id, command: command,
            allowSpawn: request["allowSpawn"] as? Bool ?? false, surface: made)
        all[made.id] = worker
        return .success(worker)
    }

    func commandFinished(in surface: Ghostty.SurfaceView, exitCode: Int) {
        guard let worker = all[surface.id] else { return }
        worker.commandEnded = (Date(), exitCode >= 0 ? exitCode : nil)
    }

    /// Close the worker's terminal, without asking: it's the parent's.
    func kill(_ worker: Worker) {
        defer { forget(worker) }
        guard let surface = worker.surface,
              let controller = BaseTerminalController.controller(owning: surface) else { return }
        controller.closeSurface(surface, withConfirmation: false)
    }

    /// Hand the worker to you: the parent can't control it any more.
    func release(_ worker: Worker) {
        if worker.kind == .tab, let surface = worker.surface,
           let controller = BaseTerminalController.controller(owning: surface),
           controller.titleOverride == "⤷ \(worker.name)" {
            controller.titleOverride = nil
        }
        forget(worker)
    }

    private func forget(_ worker: Worker) {
        all = all.filter { $0.value !== worker }
        // Its own workers go with it: nothing could reach them any more.
        if let surface = worker.surface {
            for child in all.values where child.parent == surface.id { forget(child) }
        }
    }

    /// Workers whose parent is gone: nothing can ask about them, so let
    /// them be ordinary terminals.
    private func prune() {
        all = all.filter { _, worker in
            KinTermControl.surface(id: worker.parent.uuidString) != nil
                && (worker.surface != nil || Date().timeIntervalSince(worker.started) < 3600)
        }
    }

    private func uniqueName(base: String, for parent: Ghostty.SurfaceView) -> String {
        let taken = Set(workers(of: parent).map(\.name))
        var n = 1
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
