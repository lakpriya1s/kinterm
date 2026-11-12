import AppKit
import Combine

/// One browser: a Chromium view and what it's showing. Chromium only starts
/// when the first page is put on screen.
@MainActor
final class BrowserPage: ObservableObject {
    @Published private(set) var url: String
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// Console errors since the last navigation, newest last.
    @Published private(set) var consoleErrors: [String] = []

    /// Why the page or the browser didn't load, if it didn't.
    @Published private(set) var problem: String?

    /// The view Chromium draws into. The same one for the life of the page,
    /// so moving between panel and tile keeps the page as it is.
    let container = BrowserContainerView()

    enum DevToolsPlacement { case docked, window }

    /// Where the page's DevTools are, if open: docked (under the page in
    /// the panel, a tile of its own in a grid) or in a window.
    @Published private(set) var devTools: DevToolsPlacement? {
        didSet { if devTools != oldValue { BrowserCenter.shared.devToolsChanged(self) } }
    }

    /// The view docked DevTools draw into.
    let devToolsContainer = BrowserContainerView()

    /// The docked DevTools: Chromium's DevTools front end, served by its
    /// own debug server on 127.0.0.1, as an ordinary page in
    /// devToolsContainer. (Chromium can't put its DevTools browser in a
    /// view.)
    private var devToolsHandle: UnsafeMutableRawPointer?
    private var devToolsURL: String?

    /// Whether an agent is driving the page right now (MCP tool calls).
    /// The page shows its cursor and clicks while it is.
    @Published private(set) var agentActive = false
    private var agentIdle: DispatchWorkItem?

    private var handle: UnsafeMutableRawPointer?
    private var closed = false

    init(url: String) {
        self.url = url
        container.page = self
        devToolsContainer.page = self
    }

    var displayTitle: String {
        if !title.isEmpty, title != url { return title }
        return URL(string: url)?.host ?? "Browser"
    }

    /// Start Chromium if needed and make the browser, once the view is in a
    /// window.
    fileprivate func containerMovedToWindow(_ view: BrowserContainerView) {
        if view === devToolsContainer {
            openDockedDevTools()
            return
        }
        guard handle == nil, !closed, container.window != nil else { return }
        switch BrowserEngine.start() {
        case .failure(let failure):
            problem = failure.localizedDescription
        case .success:
            let context = Unmanaged.passUnretained(self).toOpaque()
            handle = BrowserEngine.create(in: container, url: url, events: browserPageEvent, context: context)
            if handle == nil { problem = "The browser couldn't open a page." }
        }
    }

    // MARK: Actions

    func load(_ input: String) {
        guard let target = Self.normalize(input) else { return }
        url = target
        problem = nil
        consoleErrors = []
        BrowserCenter.shared.remember(url: target)
        if let handle { BrowserEngine.navigate(handle, to: target) } else { containerMovedToWindow(container) }
    }

    func run(_ command: BrowserEngine.Command) {
        if command == .reload || command == .hardReload { problem = nil; consoleErrors = [] }
        guard let handle else {
            if command == .reload { containerMovedToWindow(container) }
            return
        }
        BrowserEngine.run(command, on: handle)
    }

    /// Open DevTools, docked or in their own window, or move them there.
    func showDevTools(docked: Bool = true) {
        guard let handle else { return }
        closeDevTools()
        if docked {
            devTools = .docked
            findDevToolsTarget()
        } else {
            devTools = .window
            BrowserEngine.showDevToolsWindow(handle)
        }
    }

    func closeDevTools() {
        devTools = nil
        devToolsURL = nil
        if let devToolsHandle { BrowserEngine.close(devToolsHandle) }
        devToolsHandle = nil
        if let handle { BrowserEngine.closeDevTools(handle) }
    }

    /// Find this page in the debug server's list, for the DevTools front
    /// end's address.
    private func findDevToolsTarget() {
        let port = BrowserEngine.debugPort
        let pageURL = url
        guard let list = URL(string: "http://127.0.0.1:\(port)/json/list") else { return }
        URLSession.shared.dataTask(with: list) { [weak self] data, _, _ in
            let targets = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
            let pages = targets.filter {
                $0["type"] as? String == "page"
                    && !(($0["url"] as? String ?? "").hasPrefix("devtools:"))
                    && !(($0["url"] as? String ?? "").hasPrefix("http://127.0.0.1:\(port)/devtools/"))
            }
            let trimmed = { (url: String) in url.hasSuffix("/") ? String(url.dropLast()) : url }
            let match = pages.first { trimmed($0["url"] as? String ?? "") == trimmed(pageURL) }
                ?? (pages.count == 1 ? pages.first : nil)
            guard let id = match?["id"] as? String else { return }
            let frontEnd = "http://127.0.0.1:\(port)/devtools/devtools_app.html?ws=127.0.0.1:\(port)/devtools/page/\(id)"
            Task { @MainActor in
                guard let self, self.devTools == .docked else { return }
                self.devToolsURL = frontEnd
                self.openDockedDevTools()
            }
        }.resume()
    }

    private func openDockedDevTools() {
        guard devTools == .docked, devToolsHandle == nil, let devToolsURL, devToolsContainer.window != nil else { return }
        devToolsHandle = BrowserEngine.create(
            in: devToolsContainer, url: devToolsURL, events: ignoreBrowserEvent, context: nil)
    }

    // MARK: Agents

    /// An agent started or finished a tool call. Shows its cursor on the
    /// page while it works, and for a moment after.
    func agentActivity(_ active: Bool) {
        agentIdle?.cancel()
        if active {
            setAgentActive(true)
        } else {
            let idle = DispatchWorkItem { [weak self] in self?.setAgentActive(false) }
            agentIdle = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: idle)
        }
    }

    private func setAgentActive(_ active: Bool) {
        agentActive = active
        installAgentCursor()
    }

    /// The cursor script, put in each page as it loads. It draws only while
    /// an agent is active, so your own clicks don't get a second cursor.
    private func installAgentCursor() {
        guard let handle else { return }
        BrowserEngine.execute(handle, AgentCursor.script + "window.__kintermAgent(\(agentActive));")
    }

    /// Before the page moves to another window (panel ↔ own window): close
    /// its browser, so a new one opens at the same address where it lands.
    /// Chromium doesn't draw a view that moved to another window, so the
    /// page reloads on the move. Docked DevTools come back with it.
    func prepareToMove() {
        let docked = devTools == .docked
        closeDevTools()
        if let handle { BrowserEngine.close(handle) }
        handle = nil
        if docked { devTools = .docked }
    }

    func toggleDevTools() {
        if devTools != nil { closeDevTools() } else { showDevTools() }
    }

    func focus() {
        guard let handle else { return }
        container.window?.makeFirstResponder(container)
        BrowserEngine.setFocus(handle, true)
    }

    /// Close the browser, which ends its page's process.
    func close() {
        closeDevTools()
        closed = true
        if let handle { BrowserEngine.close(handle) }
        handle = nil
        devTools = nil
        container.page = nil
        devToolsContainer.page = nil
    }

    // MARK: Events

    fileprivate func handle(kind: Int32, value: String?, a: Int32, b: Int32) {
        switch kind {
        case 1:
            if let value, value != url {
                url = value
                BrowserCenter.shared.remember(url: value)
            }
        case 2:
            title = value ?? ""
        case 3:
            isLoading = a != 0
            canGoBack = b & 1 != 0
            canGoForward = b & 2 != 0
            if isLoading {
                problem = nil
            } else {
                if agentActive { installAgentCursor() }
                // DevTools docked before a move: back, on the new page.
                if devTools == .docked, devToolsHandle == nil, devToolsURL == nil { findDevToolsTarget() }
            }
        case 4:
            handle = nil
            devTools = nil
        case 7:
            // The DevTools window was closed.
            if a == 0, devTools == .window { devTools = nil }
        case 5:
            if let value {
                consoleErrors.append(value)
                if consoleErrors.count > 50 { consoleErrors.removeFirst() }
            }
        case 6:
            problem = value.map { Self.describe(loadError: $0) }
        default:
            break
        }
    }

    // MARK: Addresses

    /// What was typed, as a URL: `3000` and `localhost:3000` are local dev
    /// servers, a bare domain gets https, and anything else is a search.
    nonisolated static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil
            || text.hasPrefix("about:") || text.hasPrefix("data:") {
            return text
        }
        if let port = Int(text), (1...65535).contains(port) { return "http://localhost:\(port)" }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).absoluteString
        }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if !text.contains(" "), isLocal(host: host.split(separator: ":").first.map(String.init) ?? host)
            || host.range(of: "^[^:]+:[0-9]+$", options: .regularExpression) != nil {
            return "http://\(text)"
        }
        if !text.contains(" "), host.contains(".") { return "https://\(text)" }
        var query = URLComponents(string: "https://duckduckgo.com/")!
        query.queryItems = [URLQueryItem(name: "q", value: text)]
        return query.url?.absoluteString
    }

    /// localhost and loopback addresses, where dev servers run.
    nonisolated static func isLocal(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0"
            || host == "::1" || host.hasPrefix("127.")
    }

    private static func describe(loadError: String) -> String {
        switch loadError {
        case "net::ERR_CONNECTION_REFUSED":
            return "Nothing is running there. Is the dev server started?"
        case "net::ERR_NAME_NOT_RESOLVED":
            return "That address couldn't be found."
        case "net::ERR_INTERNET_DISCONNECTED":
            return "You're offline."
        default:
            return "The page didn't load (\(loadError))."
        }
    }
}

/// Events from the browser module, on the main thread.
private func browserPageEvent(
    context: UnsafeMutableRawPointer?, kind: Int32, value: UnsafePointer<CChar>?, a: Int32, b: Int32
) {
    guard let context else { return }
    let page = Unmanaged<BrowserPage>.fromOpaque(context).takeUnretainedValue()
    let text = value.map { String(cString: $0) }
    // Already on the main thread; this just gets back onto the main actor.
    // The task keeps the page alive until it runs.
    Task { @MainActor in page.handle(kind: kind, value: text, a: a, b: b) }
}

/// Events from the docked DevTools front end: none needed.
private func ignoreBrowserEvent(
    context: UnsafeMutableRawPointer?, kind: Int32, value: UnsafePointer<CChar>?, a: Int32, b: Int32
) {}

/// The view a page's Chromium view lives in.
final class BrowserContainerView: NSView {
    fileprivate weak var page: BrowserPage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        fitChromium()
        page?.containerMovedToWindow(self)
    }

    // Chromium's view always fills this one, also after moving between
    // the panel, a tile and a window, and never draws outside it.
    override func layout() {
        super.layout()
        fitChromium()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fitChromium()
    }

    private func fitChromium() {
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}
