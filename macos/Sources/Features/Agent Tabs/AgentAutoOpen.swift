import AppKit
import Darwin
import Foundation

// What an agent made, shown without being asked for. When an agent's turn
// ends (it finished, or it stopped to ask you something), KinTerm looks at
// what the turn changed and opens:
//
// - the Markdown Viewer on a Markdown file the turn wrote,
// - Review Changes when it changed other files,
// - the browser on a dev server the tab started listening during the turn.
//
// None of them takes the keyboard. Close one and it stays closed for that
// tab until its agent starts again or you open it yourself: closing it is
// how you say you don't want it.

@MainActor
final class AgentAutoOpen: NSObject {
    static let shared = AgentAutoOpen()

    enum Kind: String, CaseIterable {
        case markdown, review, browser

        var menuTitle: String {
            switch self {
            case .markdown: return "Markdown the Agent Writes"
            case .review: return "Review Changes After a Turn"
            case .browser: return "Dev Servers the Agent Starts"
            }
        }

        fileprivate var defaultsKey: String { "AutoOpen.\(rawValue)" }
    }

    func isEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ kind: Kind, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: kind.defaultsKey)
    }

    private struct Session {
        /// What the user closed in this agent session.
        var dismissed: Set<Kind> = []
        /// The tab's listening ports when the turn started.
        var portsAtStart: Set<Int>?
        /// Ports already opened, so a restarted server doesn't reopen.
        var openedPorts: Set<Int> = []
    }

    private var sessions: [ObjectIdentifier: Session] = [:]
    private var menuItem: NSMenuItem?

    // MARK: The user's say

    /// The user closed `kind` for the tab: don't bring it back this session.
    func dismissed(_ kind: Kind, for controller: BaseTerminalController?) {
        guard let controller else { return }
        dismiss(kind, id: ObjectIdentifier(controller))
    }

    func dismiss(_ kind: Kind, id: ObjectIdentifier) {
        sessions[id, default: Session()].dismissed.insert(kind)
    }

    /// The user opened `kind` for the tab themselves: they want it again.
    func reopened(_ kind: Kind, for controller: BaseTerminalController?) {
        guard let controller else { return }
        reopen(kind, id: ObjectIdentifier(controller))
    }

    func reopen(_ kind: Kind, id: ObjectIdentifier) {
        sessions[id]?.dismissed.remove(kind)
    }

    func isDismissed(_ kind: Kind, for controller: BaseTerminalController) -> Bool {
        isDismissed(kind, id: ObjectIdentifier(controller))
    }

    func isDismissed(_ kind: Kind, id: ObjectIdentifier) -> Bool {
        sessions[id]?.dismissed.contains(kind) ?? false
    }

    /// The tab's agent exited: the next one starts with nothing dismissed.
    func agentEnded(id: ObjectIdentifier) {
        sessions[id] = nil
    }

    func forget(_ controller: BaseTerminalController) {
        sessions[ObjectIdentifier(controller)] = nil
    }

    private func wants(_ kind: Kind, _ controller: BaseTerminalController) -> Bool {
        isEnabled(kind) && !isDismissed(kind, for: controller)
    }

    // MARK: Turns

    /// Called whenever a tab's agent status changes.
    func statusChanged(_ controller: BaseTerminalController,
                       from old: Ghostty.Action.ProgramStatus.State?,
                       to new: Ghostty.Action.ProgramStatus.State?) {
        let id = ObjectIdentifier(controller)
        switch new {
        case nil, .clear?:
            // The agent is gone: the next one starts a new session.
            if old != nil, old != .clear { agentEnded(id: id) }
        case .working?:
            guard old != .working else { return }
            sessions[id, default: Session()].portsAtStart = nil
            guard wants(.browser, controller) else { return }
            let ttys = Self.ttys(of: controller)
            Task {
                let ports = await Self.listeningPorts(on: ttys)
                self.sessions[id, default: Session()].portsAtStart = ports
            }
        case .done?, .blocked?:
            guard old == .working else { return }
            turnEnded(controller)
        default:
            break
        }
    }

    private func turnEnded(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        let wantsMarkdown = wants(.markdown, controller)
        let wantsReview = wants(.review, controller)
        let browserPage = BrowserCenter.shared.page(for: controller)
        let wantsBrowser = wants(.browser, controller) && BrowserEngine.isInstalled
        let pwd = controller.focusedSurface?.pwd ?? controller.surfaceTree.first?.pwd
        let ttys = Self.ttys(of: controller)
        let baseline = sessions[id]?.portsAtStart
        let opened = sessions[id]?.openedPorts ?? []

        Task { [weak controller] in
            // What the turn changed, in every repository the review covers.
            var markdown: [URL] = []
            var code = false
            if wantsMarkdown || wantsReview || browserPage != nil, let pwd,
               let workspace = await ReviewWorkspace.discover(from: pwd) {
                for repo in workspace.repos {
                    guard let snapshot = ReviewSnapshots.shared.turns(for: id, root: repo.root)?.last else { continue }
                    for path in await ReviewGit.changedPaths(in: repo.root, since: snapshot) {
                        if MarkdownRenderer.isMarkdown(path) {
                            markdown.append(URL(fileURLWithPath: repo.root).appendingPathComponent(path))
                        } else {
                            code = true
                        }
                    }
                }
            }

            // A dev server the turn started. Shown when the tab has no
            // browser, or its browser is blank or on a server that's gone.
            var server: Int?
            if wantsBrowser, let baseline {
                let now = await Self.listeningPorts(on: ttys)
                let shownPort = browserPage.flatMap { Self.localPort($0.url) }
                var pageIsStale = browserPage == nil || browserPage?.url == "about:blank"
                if !pageIsStale, let shownPort { pageIsStale = await !Self.answersHTTP(shownPort) }
                if pageIsStale {
                    for port in now.subtracting(baseline).subtracting(opened).sorted()
                    where await Self.answersHTTP(port) {
                        server = port
                        break
                    }
                }
            }

            guard let controller else { return }
            if wantsMarkdown, let file = Self.newest(markdown) {
                MarkdownViewerCenter.shared.autoOpen(file: file, for: controller)
            }
            if wantsReview, code {
                ReviewCenter.shared.autoShow(for: controller)
            }
            if let server {
                self.sessions[id, default: Session()].openedPorts.insert(server)
                BrowserCenter.shared.show(for: controller, url: "http://localhost:\(server)/", focus: false)
            } else if code, let page = browserPage, Self.isLocal(page.url) {
                // The tab's page shows its dev server: show the change.
                page.run(.reload)
            }
        }
    }

    // MARK: Looking around

    private static func newest(_ files: [URL]) -> URL? {
        files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    /// The port of a local page's address, like 5173 for localhost:5173.
    private static func localPort(_ url: String) -> Int? {
        guard let parsed = URL(string: url), let host = parsed.host, BrowserPage.isLocal(host: host) else { return nil }
        return parsed.port ?? (parsed.scheme == "https" ? 443 : 80)
    }

    private static func isLocal(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return BrowserPage.isLocal(host: host)
    }

    /// The terminal devices of the tab's panes: the agent's, and the panes
    /// it ran things in.
    private static func ttys(of controller: BaseTerminalController) -> [dev_t] {
        controller.surfaceTree.compactMap { surface in
            guard let name = surface.surfaceModel?.ttyName else { return nil }
            return ControlPeer.device(ofTTY: name.hasPrefix("/") ? name : "/dev/\(name)")
        }
    }

    /// TCP ports that processes started in the tab's panes listen on.
    nonisolated static func listeningPorts(on ttys: [dev_t]) async -> Set<Int> {
        guard !ttys.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let output = lsof()
                continuation.resume(returning: ports(output) { pid in
                    ttys.contains { ControlPeer.runs(pid, on: $0) == true }
                })
            }
        }
    }

    /// The ports in `lsof -F pn` output ("p<pid>", then an "n<address>"
    /// per socket) that processes `isOurs` listen on. Below 1024 is left
    /// out: those are system services, not dev servers.
    nonisolated static func ports(_ output: String, isOurs: (pid_t) -> Bool) -> Set<Int> {
        var result: Set<Int> = []
        var pid: pid_t = 0
        var ours = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst()) ?? 0
                ours = pid > 0 && isOurs(pid)
            } else if line.hasPrefix("n"), ours,
                      let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]), port >= 1024 {
                result.insert(port)
            }
        }
        return result
    }

    private nonisolated static func lsof() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Whether something on the port speaks HTTP: a web server, not a
    /// debugger or a database.
    private nonisolated static func answersHTTP(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    // MARK: Menu

    /// View › Open Automatically, with a switch for each kind.
    func installMenuItem() {
        guard menuItem == nil,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        let menu = NSMenu(title: "Open Automatically")
        for kind in Kind.allCases {
            let item = NSMenuItem(title: kind.menuTitle, action: #selector(toggleKind(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "Open Automatically", action: nil, keyEquivalent: "")
        item.submenu = menu
        item.setImageIfDesired(systemSymbolName: "sparkles.rectangle.stack")
        // After the Markdown Viewer's item, if it's there.
        let viewer = view.items.firstIndex { $0.keyEquivalent == "m" && $0.keyEquivalentModifierMask == [.command, .shift] }
        view.insertItem(item, at: viewer.map { $0 + 1 } ?? view.items.count)
        menuItem = item
    }

    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = Kind(rawValue: raw) else { return }
        setEnabled(kind, !isEnabled(kind))
    }
}

extension AgentAutoOpen: NSMenuItemValidation {
    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            if let raw = menuItem.representedObject as? String, let kind = Kind(rawValue: raw) {
                menuItem.state = isEnabled(kind) ? .on : .off
            }
            return true
        }
    }
}
