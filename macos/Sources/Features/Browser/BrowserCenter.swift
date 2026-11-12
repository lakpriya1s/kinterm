import AppKit
import Combine
import SwiftUI

// Where browsers are shown: beside a tab's terminal, one per tab, or as one
// more tile in Grid View, one per grid. ⌘⇧B (View › Browser) toggles it.
// Agents drive the same browsers through `kinterm-browser` and its MCP
// server (BrowserControlServer). See scope/designs/09-browser.md.

// Not main-actor isolated as a whole, like ReviewCenter, so views and menus
// can ask about it. Everything here runs on the main thread.
final class BrowserCenter: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = BrowserCenter()

    /// Browsers beside a tab's terminal, by tab.
    @Published private(set) var panels: [ObjectIdentifier: BrowserPage] = [:]

    /// Browser tiles, by grid (tab group).
    @Published private(set) var gridPages: [ObjectIdentifier: BrowserPage] = [:]

    /// Browsers popped out into windows of their own, with the tab they
    /// came from (where they go back to).
    private var windows: [ObjectIdentifier: (page: BrowserPage, window: NSWindow, from: Weak<BaseTerminalController>)] = [:]
    private var titleWatchers: [ObjectIdentifier: AnyCancellable] = [:]

    @Published var panelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "BrowserPanelWidth")
        return saved > 0 ? saved : 560
    }() {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: "BrowserPanelWidth") }
    }

    /// Docked DevTools' height under the page in a panel.
    @Published var devToolsHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "BrowserDevToolsHeight")
        return saved > 0 ? saved : 320
    }() {
        didSet { UserDefaults.standard.set(Double(devToolsHeight), forKey: "BrowserDevToolsHeight") }
    }

    /// Whether ⌘-clicked localhost links open here instead of in your
    /// default browser.
    var opensLocalLinks: Bool {
        get { UserDefaults.standard.object(forKey: "BrowserOpensLocalLinks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "BrowserOpensLocalLinks") }
    }

    private var lastURL: String {
        UserDefaults.standard.string(forKey: "BrowserLastURL") ?? "about:blank"
    }

    private var menuItem: NSMenuItem?

    private override init() {
        super.init()
        // A tab's browser goes when the tab does.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in self?.windowWillClose(window) }
        }
    }

    /// At launch: listen for `kinterm-browser`. Cheap; nothing of the
    /// browser loads until one is opened.
    @MainActor
    func start() {
        BrowserControlServer.shared.start()
        BrowserAgentInstaller.updateInstalledCLI()
    }

    func remember(url: String) {
        guard url.hasPrefix("http") || url.hasPrefix("file:") else { return }
        UserDefaults.standard.set(url, forKey: "BrowserLastURL")
    }

    // MARK: Panels

    func panelPage(for controller: BaseTerminalController?) -> BrowserPage? {
        guard let controller else { return nil }
        return panels[ObjectIdentifier(controller)]
    }

    @MainActor
    @discardableResult
    func showPanel(for controller: BaseTerminalController, url: String? = nil, focus: Bool = true) -> BrowserPage {
        let page = panels[ObjectIdentifier(controller)] ?? {
            let page = BrowserPage(url: url ?? lastURL)
            panels[ObjectIdentifier(controller)] = page
            return page
        }()
        if let url, url != page.url { page.load(url) }
        if focus { focusLater(page, addressIfBlank: true) }
        return page
    }

    @MainActor
    func hidePanel(for controller: BaseTerminalController) {
        guard let page = panels.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        page.close()
        // Give the keyboard back to the terminal.
        if let surface = controller.focusedSurface { controller.focusSurface(surface) }
    }

    // MARK: In a grid

    private static func gridKey(_ window: NSWindow) -> ObjectIdentifier {
        ObjectIdentifier(TerminalGridModel.groupObject(for: window))
    }

    /// The window's grid browser tile, if its grid has one.
    func gridPage(for window: NSWindow?) -> BrowserPage? {
        guard let window, TerminalGridModel.shared.isActive(for: window) else { return nil }
        return gridPages[Self.gridKey(window)]
    }

    @MainActor
    @discardableResult
    func openGridTile(in window: NSWindow, url: String? = nil, focus: Bool = true) -> BrowserPage {
        let key = Self.gridKey(window)
        let page = gridPages[key] ?? {
            let page = BrowserPage(url: url ?? lastURL)
            gridPages[key] = page
            TerminalGridModel.shared.changed()
            // Tiles move when one comes or goes; the grid re-syncs its
            // terminals on tab bar changes.
            AgentTabBarModel.setNeedsRefresh()
            return page
        }()
        if let url, url != page.url { page.load(url) }
        if focus { focusLater(page, addressIfBlank: true) }
        return page
    }

    @MainActor
    func closeGridTile(in window: NSWindow) {
        guard let page = gridPages.removeValue(forKey: Self.gridKey(window)) else { return }
        page.close()
        TerminalGridModel.shared.changed()
        AgentTabBarModel.setNeedsRefresh()
        if let controller = TerminalGridModel.shared.focusedController(in: window) {
            TerminalGridModel.shared.focus(controller)
        }
    }

    /// The grid's tile left the screen: if that's because the grid closed,
    /// close its browser too, so it doesn't run unseen.
    @MainActor
    func gridTileDisappeared(_ page: BrowserPage) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let key = self.gridPages.first(where: { $0.value === page })?.key else { return }
            let stillShown = NSApp.windows.contains {
                Self.gridKey($0) == key && TerminalGridModel.shared.isActive(for: $0)
            }
            if !stillShown {
                self.gridPages[key] = nil
                page.close()
            }
        }
    }

    /// A page's DevTools opened, closed or moved. In a grid they're a tile
    /// of their own, so the grid lays out again.
    @MainActor
    func devToolsChanged(_ page: BrowserPage) {
        guard gridPages.values.contains(where: { $0 === page }) else { return }
        objectWillChange.send()
        TerminalGridModel.shared.changed()
        AgentTabBarModel.setNeedsRefresh()
    }

    // MARK: Opening

    private func inGrid(_ controller: BaseTerminalController) -> Bool {
        TerminalGridModel.shared.isActive(for: controller.gridWindow ?? controller.window)
    }

    /// The browser for a tab: its grid's tile in Grid View, else its panel.
    /// Opens one if it isn't there.
    @MainActor
    @discardableResult
    func show(for controller: BaseTerminalController, url: String? = nil, focus: Bool = true) -> BrowserPage {
        if inGrid(controller), let window = controller.gridWindow ?? controller.window {
            return openGridTile(in: window, url: url, focus: focus)
        }
        return showPanel(for: controller, url: url, focus: focus)
    }

    @MainActor
    func toggle(for controller: BaseTerminalController) {
        if inGrid(controller), let window = controller.gridWindow ?? controller.window {
            if gridPage(for: window) != nil { closeGridTile(in: window) } else { openGridTile(in: window) }
        } else if panelPage(for: controller) != nil {
            hidePanel(for: controller)
        } else {
            showPanel(for: controller)
        }
    }

    /// The tab browsers open for when nothing says which: the key window's,
    /// or the frontmost terminal window's.
    @MainActor
    var frontController: BaseTerminalController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.orderedWindows.filter { $0.windowController is BaseTerminalController }
        for window in windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if TerminalGridModel.shared.isActive(for: window),
               let focused = TerminalGridModel.shared.focusedController(in: window) {
                return focused
            }
            return controller
        }
        return nil
    }

    /// Open a ⌘-clicked link here if it's a local dev server and that's on.
    /// Returns whether it did.
    func openLink(_ url: URL) -> Bool {
        guard opensLocalLinks, BrowserEngine.isInstalled,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, BrowserPage.isLocal(host: host) else { return false }
        Task { @MainActor in
            guard let controller = self.frontController else {
                NSWorkspace.shared.open(url)
                return
            }
            self.show(for: controller, url: url.absoluteString, focus: false)
        }
        return true
    }

    /// Every open browser, panels and tiles.
    var allPages: [BrowserPage] {
        Array(panels.values) + Array(gridPages.values) + windows.values.map(\.page)
    }

    /// A browser in a window of its own, if there is one: agents use it
    /// when the tab has none beside it.
    var windowedPage: BrowserPage? {
        windows.values.max { $0.window.orderedIndex > $1.window.orderedIndex }?.page
    }

    // MARK: Own window

    func isWindowed(_ page: BrowserPage) -> Bool {
        windows[ObjectIdentifier(page)] != nil
    }

    /// Move a panel's or tile's browser into a window of its own. The page
    /// reopens there at the same address.
    @MainActor
    func popOut(_ page: BrowserPage) {
        page.prepareToMove()
        var from: BaseTerminalController?
        if let entry = panels.first(where: { $0.value === page }) {
            panels[entry.key] = nil
            from = NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
                .first { ObjectIdentifier($0) == entry.key }
        }
        if let key = gridPages.first(where: { $0.value === page })?.key {
            gridPages[key] = nil
            from = frontController
            TerminalGridModel.shared.changed()
            AgentTabBarModel.setNeedsRefresh()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 420, height: 320)
        window.tabbingMode = .disallowed
        window.title = page.displayTitle
        window.contentView = NSHostingView(rootView: BrowserView(
            page: page,
            placement: .window,
            close: { [weak window] in window?.close() },
            popOut: { [weak self, weak page] in
                guard let self, let page else { return }
                self.putBack(page)
            }))
        window.setFrameAutosaveName("KinTermBrowserWindow")
        if !window.setFrameUsingName("KinTermBrowserWindow") {
            if let anchor = from?.window {
                window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 60, y: anchor.frame.maxY - 60))
            } else {
                window.center()
            }
        }

        let id = ObjectIdentifier(page)
        windows[id] = (page, window, Weak(from))
        titleWatchers[id] = page.$title.sink { [weak window, weak page] _ in
            DispatchQueue.main.async { if let page { window?.title = page.displayTitle } }
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { page.focus() }
    }

    /// Back beside the terminal it came from (or the front one), as a
    /// panel, or as the grid's tile in Grid View.
    @MainActor
    func putBack(_ page: BrowserPage) {
        let id = ObjectIdentifier(page)
        guard let entry = windows.removeValue(forKey: id) else { return }
        titleWatchers[id] = nil
        guard let controller = entry.from.value ?? frontController else {
            entry.window.close()
            page.close()
            return
        }
        // Detach the page's view before the window goes, so it isn't
        // closed with it.
        page.prepareToMove()
        entry.window.contentView = nil
        entry.window.close()
        if inGrid(controller), let window = controller.gridWindow ?? controller.window {
            gridPages[Self.gridKey(window)]?.close()
            gridPages[Self.gridKey(window)] = page
            TerminalGridModel.shared.changed()
            AgentTabBarModel.setNeedsRefresh()
        } else {
            panels[ObjectIdentifier(controller)]?.close()
            panels[ObjectIdentifier(controller)] = page
        }
        controller.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { page.focus() }
    }

    @MainActor
    private func focusLater(_ page: BrowserPage, addressIfBlank: Bool) {
        // After SwiftUI has put the view in its window.
        DispatchQueue.main.async {
            if addressIfBlank, page.url == "about:blank" {
                NotificationCenter.default.post(name: .browserFocusAddress, object: page)
            } else {
                page.focus()
            }
        }
    }

    @MainActor
    private func windowWillClose(_ window: NSWindow) {
        // A popped-out browser closes with its window.
        if let (id, entry) = windows.first(where: { $0.value.window === window }) {
            windows[id] = nil
            titleWatchers[id] = nil
            entry.page.close()
            return
        }
        if let controller = window.windowController as? BaseTerminalController,
           let page = panels.removeValue(forKey: ObjectIdentifier(controller)) {
            page.close()
        }
        // The grid's tile goes with the last window of the grid.
        let key = Self.gridKey(window)
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && Self.gridKey($0) == key }
        if others.isEmpty, let page = gridPages.removeValue(forKey: key) {
            page.close()
        }
    }

    // MARK: Menu

    func installMenuItem() {
        guard menuItem == nil,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        let item = NSMenuItem(title: "Browser", action: #selector(toggleFromMenu(_:)), keyEquivalent: "b")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "globe")

        let options = NSMenuItem(title: "Browser Options", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Browser Options")
        let address = NSMenuItem(title: "Go to Address…", action: #selector(focusAddress(_:)), keyEquivalent: "")
        address.target = self
        let devTools = NSMenuItem(title: "DevTools", action: #selector(openDevTools(_:)), keyEquivalent: "i")
        devTools.keyEquivalentModifierMask = [.command, .option]
        devTools.target = self
        let links = NSMenuItem(title: "Open Localhost Links Here", action: #selector(toggleLocalLinks(_:)), keyEquivalent: "")
        links.target = self
        let agents = NSMenuItem(title: "Let Agents Use the Browser…", action: #selector(connectAgents(_:)), keyEquivalent: "")
        agents.target = self
        let profile = NSMenuItem(title: "Show Browser Profile in Finder", action: #selector(showProfile(_:)), keyEquivalent: "")
        profile.target = self
        [address, devTools, .separator(), links, agents, .separator(), profile].forEach(submenu.addItem)
        options.submenu = submenu

        // After Review Changes (⌘⇧R), if it's there.
        let index = view.items.firstIndex { $0.keyEquivalent == "r" && $0.keyEquivalentModifierMask == [.command, .shift] }
        let at = index.map { $0 + 1 } ?? 0
        view.insertItem(item, at: at)
        view.insertItem(options, at: at + 1)
        menuItem = item
    }

    /// The tab the menu acts on.
    @MainActor
    private var menuController: BaseTerminalController? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let controller = window.windowController as? BaseTerminalController else { return nil }
        if TerminalGridModel.shared.isActive(for: window),
           let focused = TerminalGridModel.shared.focusedController(in: window) {
            return focused
        }
        return controller
    }

    /// The browser the menu acts on.
    @MainActor
    private var menuPage: BrowserPage? {
        if let key = NSApp.keyWindow, let entry = windows.values.first(where: { $0.window === key }) {
            return entry.page
        }
        guard let controller = menuController else { return nil }
        if let window = controller.gridWindow ?? controller.window, let page = gridPage(for: window) { return page }
        return panelPage(for: controller)
    }

    @MainActor
    @objc private func toggleFromMenu(_ sender: Any?) {
        guard let controller = menuController else { return }
        toggle(for: controller)
    }

    @MainActor
    @objc private func focusAddress(_ sender: Any?) {
        guard let controller = menuController else { return }
        let page = menuPage ?? show(for: controller)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .browserFocusAddress, object: page)
        }
    }

    @MainActor
    @objc private func openDevTools(_ sender: Any?) {
        menuPage?.toggleDevTools()
    }

    @objc private func toggleLocalLinks(_ sender: Any?) {
        opensLocalLinks.toggle()
    }

    @MainActor
    @objc private func connectAgents(_ sender: Any?) {
        BrowserAgentInstaller.presentConnect()
    }

    @objc private func showProfile(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: BrowserEngine.profileURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([BrowserEngine.profileURL])
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFromMenu(_:)):
            let shown = self.menuPage != nil
            menuItem.title = shown ? "Hide Browser" : "Browser"
            return self.menuController != nil
        case #selector(toggleLocalLinks(_:)):
            menuItem.state = opensLocalLinks ? .on : .off
            return BrowserEngine.isInstalled
        case #selector(openDevTools(_:)):
            return self.menuPage != nil
        case #selector(focusAddress(_:)):
            return BrowserEngine.isInstalled && self.menuController != nil
        case #selector(connectAgents(_:)):
            return BrowserEngine.isInstalled
        default:
            return true
        }
    }
}

/// A tab's terminal with its side panels: the browser, then the review.
struct TerminalSidePanels<Content: View>: View {
    weak var controller: BaseTerminalController?
    @ViewBuilder let content: () -> Content

    @ObservedObject private var browsers = BrowserCenter.shared

    var body: some View {
        // Always an HStack, so showing a panel doesn't rebuild the
        // terminals.
        HStack(spacing: 0) {
            ReviewPanelHost(controller: controller) {
                HStack(spacing: 0) {
                    content()
                    if let controller, let page = browsers.panelPage(for: controller) {
                        PanelResizeHandle(width: $browsers.panelWidth)
                        BrowserView(
                            page: page,
                            close: { [weak controller] in
                                guard let controller else { return }
                                Task { @MainActor in BrowserCenter.shared.hidePanel(for: controller) }
                            },
                            popOut: { [weak page] in
                                guard let page else { return }
                                Task { @MainActor in BrowserCenter.shared.popOut(page) }
                            })
                        .frame(width: browsers.panelWidth)
                        .id(ObjectIdentifier(page))
                    }
                }
            }
        }
    }
}
