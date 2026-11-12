import AppKit
import Combine
import SwiftUI

/// Grid View: every tab of a window shown at once, side by side, as live
/// terminals you can click into and type in. Toggling it off goes back to
/// ordinary tabs. Nothing about the tabs themselves changes.
///
/// Tabs are native window tabs and only the selected one is on screen, so
/// the selected tab's window hosts the grid. It draws every tab's split tree,
/// which moves the other tabs' terminal views into it for as long as the grid
/// is shown. Those tabs draw an empty placeholder meanwhile, since a view can
/// only be in one place, and take their terminals back when the grid closes.
///
/// Each terminal still belongs to its own tab: titles, agent faces, splits and
/// closing all go to the tab whose split tree holds the terminal.
final class TerminalGridModel: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = TerminalGridModel()

    /// What a terminal window's content should draw.
    enum Layout {
        /// The window's own split tree, as usual.
        case normal

        /// The grid of every tab in the window's tab group, in tab order.
        case host([BaseTerminalController])

        /// Nothing: another tab's window is showing this tab in its grid.
        case hidden
    }

    /// The tab groups (or lone windows) in Grid View.
    private var active: [ObjectIdentifier: Weak<AnyObject>] = [:]

    /// Bumped whenever tabs, selection or focus change, so every terminal
    /// window redraws and works out its layout again.
    @Published private(set) var revision = 0

    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
        let center = NotificationCenter.default
        let windowChanges = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
        ].map { center.publisher(for: $0).map { _ in () }.eraseToAnyPublisher() }

        Publishers.MergeMany(windowChanges + [AgentTabBarModel.changesPublisher])
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] in
                // Only grids care, and redrawing every window for nothing
                // isn't free.
                guard let self, !self.active.isEmpty else { return }
                self.prune()
                self.revision += 1

                // A new host (another tab selected, a tab opened or closed)
                // moves terminals between windows.
                for group in self.active.values.compactMap(\.value) {
                    let window = (group as? NSWindowTabGroup)?.selectedWindow ?? (group as? NSWindow)
                    if let window { self.syncSurfaces(of: window, after: 0.05) }
                }
            }
            .store(in: &cancellables)

        // Each tab tells its terminals whether they have the keyboard and are
        // on screen when its own window changes. In a grid the terminals are
        // in the host window instead, so tell every tab when that changes.
        let hostChanges = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ].map { center.publisher(for: $0).eraseToAnyPublisher() }

        Publishers.MergeMany(hostChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      self.isActive(for: window) else { return }
                self.syncSurfaces(of: window)
            }
            .store(in: &cancellables)
    }

    /// The windows' tabs, sizes saved before a grid made them fill the
    /// screen, by tab group. See `fillScreen`.
    private var savedFrames: [ObjectIdentifier: (saved: NSRect, filled: NSRect)] = [:]

    // MARK: State

    /// The object that identifies a window's tabs: its tab group, or the
    /// window itself when it can't have tabs.
    static func groupObject(for window: NSWindow) -> AnyObject {
        window.tabGroup ?? window
    }

    func isActive(for window: NSWindow?) -> Bool {
        guard let window else { return false }
        return active[ObjectIdentifier(Self.groupObject(for: window))]?.value != nil
    }

    /// The window's tabs as the grid shows them, skipping ones that are
    /// closing.
    static func tabWindows(of window: NSWindow) -> [NSWindow] {
        (window.tabbedWindows ?? [window]).filter { $0.isVisible || $0 === window }
    }

    func layout(for window: NSWindow?) -> Layout {
        guard let window, isActive(for: window) else { return .normal }
        let selected = window.tabGroup?.selectedWindow ?? window
        guard selected === window else { return .hidden }
        let controllers = Self.tabWindows(of: window)
            .compactMap { $0.windowController as? BaseTerminalController }
        return .host(controllers)
    }

    /// Tell every tab's terminals whether they have the keyboard and are on
    /// screen, once SwiftUI has moved them into or out of the grid.
    private func syncSurfaces(of window: NSWindow, after delay: TimeInterval = 0) {
        let controllers = Self.tabWindows(of: window)
            .compactMap { $0.windowController as? BaseTerminalController }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for controller in controllers {
                controller.syncFocusToSurfaceTree()
                controller.syncSurfaceTreeOcclusionState()
            }
        }
    }

    // MARK: Window size

    /// Grow the window to fill its screen, so the tiles have room. Does
    /// nothing in full screen or when the window already fills it.
    private func fillScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let filled = screen.visibleFrame
        guard window.frame != filled else { return }
        savedFrames[ObjectIdentifier(Self.groupObject(for: window))] = (window.frame, filled)
        window.setFrame(filled, display: true, animate: true)
    }

    /// Put the window back to its size before the grid, unless it was
    /// moved or resized while in the grid.
    private func restoreFrame(_ window: NSWindow) {
        let key = ObjectIdentifier(Self.groupObject(for: window))
        guard let frames = savedFrames.removeValue(forKey: key),
              !window.styleMask.contains(.fullScreen),
              window.frame == frames.filled else { return }
        window.setFrame(frames.saved, display: true, animate: true)
    }

    private func prune() {
        active = active.filter { $0.value.value != nil }
    }

    // MARK: Menu

    private var menuItem: NSMenuItem?

    /// "Show Tabs in Grid" (⌘⇧E) at the top of the View menu.
    func installMenuItem() {
        guard menuItem == nil,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        let item = NSMenuItem(title: "Show Tabs in Grid", action: #selector(toggleFromMenu(_:)), keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "square.grid.2x2")
        view.insertItem(item, at: 0)
        view.insertItem(.separator(), at: 1)
        menuItem = item
    }

    /// The terminal window the menu acts on.
    private var menuWindow: NSWindow? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return (window?.windowController as? BaseTerminalController)?.gridWindow
    }

    @objc private func toggleFromMenu(_ sender: Any?) {
        toggle(for: menuWindow)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleFromMenu(_:)) else { return true }
        guard let window = menuWindow else {
            menuItem.title = "Show Tabs in Grid"
            return false
        }
        let active = isActive(for: window)
        menuItem.title = active ? "Back to Tabs" : "Show Tabs in Grid"
        return active || Self.tabWindows(of: window).count > 1
    }

    // MARK: Actions

    /// Turn Grid View on or off for the window's tabs. Turning it off
    /// selects the tab that had focus in the grid.
    func toggle(for window: NSWindow?) {
        guard let window else { return }
        if isActive(for: window) {
            exit(for: window, selecting: focusedController(in: window))
        } else {
            enter(for: window)
        }
    }

    func enter(for window: NSWindow) {
        let group = Self.groupObject(for: window)
        active[ObjectIdentifier(group)] = Weak(group)
        changed()

        // Moving into the grid takes the terminal out of its old view, which
        // also takes its focus. Give it back.
        let host = window.tabGroup?.selectedWindow ?? window
        fillScreen(host)
        syncSurfaces(of: host, after: 0.1)
        if let surface = (host.windowController as? BaseTerminalController)?.focusedSurface {
            Ghostty.moveFocus(to: surface, delay: 0.02)
        }
    }

    /// Back to tabs, with `controller`'s tab selected if given.
    func exit(for window: NSWindow, selecting controller: BaseTerminalController? = nil) {
        active[ObjectIdentifier(Self.groupObject(for: window))] = nil
        if let target = controller?.window {
            window.tabGroup?.selectedWindow = target
            target.makeKeyAndOrderFront(nil)
        }
        changed()

        let host = window.tabGroup?.selectedWindow ?? window
        restoreFrame(host)
        syncSurfaces(of: host, after: 0.1)

        let target = controller ?? ((window.tabGroup?.selectedWindow ?? window).windowController as? BaseTerminalController)
        if let surface = target?.focusedSurface {
            Ghostty.moveFocus(to: surface, delay: 0.02)
        }
    }

    /// Put the keyboard in one tab's tile, without leaving the grid.
    func focus(_ controller: BaseTerminalController) {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else { return }
        Ghostty.moveFocus(to: surface)
        controller.window?.tabGroup?.selectedWindow?.makeKeyAndOrderFront(nil)
    }

    /// The tab whose terminal has the keyboard in the window's grid, if any.
    func focusedController(in window: NSWindow) -> BaseTerminalController? {
        let host = window.tabGroup?.selectedWindow ?? window
        guard let surface = host.firstResponder as? Ghostty.SurfaceView else { return nil }
        return BaseTerminalController.controller(owning: surface)
    }

    /// Something changed what the grid shows. Redraw now rather than after
    /// the debounce, so the terminals move in one step.
    func changed() {
        revision += 1
        AgentTabBarModel.setNeedsRefresh()
    }
}
