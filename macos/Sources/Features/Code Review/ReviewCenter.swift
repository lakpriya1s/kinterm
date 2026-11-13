import AppKit
import SwiftUI

// Where reviews are shown: beside a tab's terminal or in their own window,
// one review per tab. ⌘⇧R (View › Review Changes) toggles the review for the
// focused tab. In Grid View there's no room beside the terminals, so a
// review is one more tile in the grid: one per tab, opened for the tile you're
// in. See scope/designs/08-code-review.md.

// Not main-actor isolated as a whole, like TerminalGridModel, so the tab bar
// can ask about grid reviews. Everything here runs on the main thread.
final class ReviewCenter: NSObject, ObservableObject, NSMenuItemValidation, NSWindowDelegate {
    static let shared = ReviewCenter()

    enum Presentation: String { case panel, window }

    /// Tabs showing the review beside their terminal.
    @Published private(set) var panels: Set<ObjectIdentifier> = []

    @Published var panelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "ReviewPanelWidth")
        return saved > 0 ? saved : 460
    }() {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: "ReviewPanelWidth") }
    }

    /// Where ⌘⇧R opens the review, the last place you used.
    private var preferred: Presentation {
        get { Presentation(rawValue: UserDefaults.standard.string(forKey: "ReviewPresentation") ?? "") ?? .panel }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ReviewPresentation") }
    }

    /// Review tiles, by grid (tab group): the tabs under review, in the
    /// order their tiles were opened.
    @Published private(set) var gridReviews: [ObjectIdentifier: [Weak<BaseTerminalController>]] = [:]

    private var models: [ObjectIdentifier: ReviewModel] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var menuItem: NSMenuItem?

    private override init() {
        super.init()
        // A tab's review goes when the tab does.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  let controller = window.windowController as? BaseTerminalController else { return }
            Task { @MainActor in self?.forget(controller) }
        }
    }

    @MainActor
    func model(for controller: BaseTerminalController) -> ReviewModel {
        let id = ObjectIdentifier(controller)
        if let model = models[id], model.controller === controller { return model }
        let model = ReviewModel(controller: controller)
        models[id] = model
        return model
    }

    /// The tab's review if it's been opened, without making one.
    @MainActor
    func existingModel(for controller: BaseTerminalController) -> ReviewModel? {
        let model = models[ObjectIdentifier(controller)]
        return model?.controller === controller ? model : nil
    }

    func isPanelShown(for controller: BaseTerminalController?) -> Bool {
        guard let controller else { return false }
        return panels.contains(ObjectIdentifier(controller))
    }

    private func isWindowShown(for controller: BaseTerminalController) -> Bool {
        windows[ObjectIdentifier(controller)]?.isVisible ?? false
    }

    /// Whether the tab's window shows every tab in a grid, which leaves no
    /// room for a panel.
    private func inGrid(_ controller: BaseTerminalController) -> Bool {
        TerminalGridModel.shared.isActive(for: controller.gridWindow ?? controller.window)
    }

    // MARK: Showing and hiding

    @MainActor
    func toggle(for controller: BaseTerminalController) {
        if inGrid(controller), let window = controller.gridWindow ?? controller.window {
            if hasGridReview(of: controller, in: window) {
                closeGridReview(of: controller, in: window)
            } else {
                openGridReview(of: controller, in: window)
            }
            return
        }

        if isPanelShown(for: controller) {
            hidePanel(for: controller)
        } else if let window = windows[ObjectIdentifier(controller)], window.isVisible {
            if window.isKeyWindow { window.close() } else { window.makeKeyAndOrderFront(nil) }
        } else if preferred == .window || inGrid(controller) {
            showWindow(for: controller)
        } else {
            showPanel(for: controller)
        }
    }

    @MainActor
    func showPanel(for controller: BaseTerminalController) {
        guard !inGrid(controller) else { toggle(for: controller); return }
        windows[ObjectIdentifier(controller)]?.close()
        panels.insert(ObjectIdentifier(controller))
        preferred = .panel
    }

    func hidePanel(for controller: BaseTerminalController) {
        panels.remove(ObjectIdentifier(controller))
        // Give the keyboard back to the terminal.
        if let surface = controller.focusedSurface { controller.focusSurface(surface) }
    }

    @MainActor
    func showWindow(for controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        panels.remove(id)
        preferred = .window
        let model = model(for: controller)

        let window = windows[id] ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.minSize = NSSize(width: 640, height: 400)
            window.tabbingMode = .disallowed
            window.delegate = self
            window.contentView = NSHostingView(rootView: ReviewView(
                model: model,
                presentation: .window,
                switchPresentation: { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.showPanel(for: controller)
                    controller.window?.makeKeyAndOrderFront(nil)
                },
                close: { [weak window] in window?.close() }))
            window.setFrameAutosaveName("KinTermReviewWindow")
            if !window.setFrameUsingName("KinTermReviewWindow") {
                if let anchor = controller.window { window.setFrameTopLeftPoint(
                    NSPoint(x: anchor.frame.minX + 40, y: anchor.frame.maxY - 40)) } else { window.center() }
            }
            windows[id] = window
            return window
        }()

        window.title = "Review · \(model.tabTitle)"
        window.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    // MARK: In a grid

    private static func gridKey(_ window: NSWindow) -> ObjectIdentifier {
        ObjectIdentifier(TerminalGridModel.groupObject(for: window))
    }

    /// The tabs the window's review tiles are reviewing, in tile order.
    func gridReviewControllers(for window: NSWindow?) -> [BaseTerminalController] {
        guard let window, TerminalGridModel.shared.isActive(for: window) else { return [] }
        return (gridReviews[Self.gridKey(window)] ?? []).compactMap(\.value)
    }

    /// Whether the tab has a review tile in the window's grid.
    func hasGridReview(of controller: BaseTerminalController, in window: NSWindow?) -> Bool {
        gridReviewControllers(for: window).contains { $0 === controller }
    }

    private func setGridReviews(_ window: NSWindow, _ change: (inout [Weak<BaseTerminalController>]) -> Void) {
        let key = Self.gridKey(window)
        var list = (gridReviews[key] ?? []).filter { $0.value != nil }
        change(&list)
        gridReviews[key] = list.isEmpty ? nil : list
        TerminalGridModel.shared.changed()
        // Tiles move when one comes or goes; the grid re-syncs its
        // terminals on tab bar changes.
        AgentTabBarModel.setNeedsRefresh()
    }

    /// Add a review tile for the tab to the window's grid, beside any
    /// other tabs' reviews.
    @MainActor
    func openGridReview(of controller: BaseTerminalController, in window: NSWindow) {
        let id = ObjectIdentifier(controller)
        panels.remove(id)
        windows[id]?.close()
        guard !hasGridReview(of: controller, in: window) else { return }
        setGridReviews(window) { $0.append(Weak(controller)) }
        model(for: controller).refresh()
    }

    /// Take the tab's review tile out of the grid and give the keyboard
    /// back to the tab.
    @MainActor
    func closeGridReview(of controller: BaseTerminalController, in window: NSWindow) {
        setGridReviews(window) { $0.removeAll { $0.value === controller } }
        TerminalGridModel.shared.focus(controller)
    }

    /// Move the tab's review tile into its own window.
    @MainActor
    func popOutGridReview(of controller: BaseTerminalController, in window: NSWindow) {
        setGridReviews(window) { $0.removeAll { $0.value === controller } }
        showWindow(for: controller)
    }

    /// After comments are typed into the agent's prompt, show that prompt.
    @MainActor
    func didSend(from controller: BaseTerminalController, to surface: Ghostty.SurfaceView) {
        if let window = controller.gridWindow ?? controller.window, hasGridReview(of: controller, in: window) {
            // The agent's tile is right there in the grid.
            Ghostty.moveFocus(to: surface, delay: 0.05)
            return
        }
        AgentSummary.focus(controller)
        controller.focusSurface(surface)
    }

    @MainActor
    func windowDidBecomeKey(_ notification: Notification) {
        // Coming back to the window after the agent did more: look again.
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        models[id]?.refresh()
    }

    @MainActor
    private func forget(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        panels.remove(id)
        windows.removeValue(forKey: id)?.close()
        models[id] = nil
        ReviewSnapshots.shared.forget(controller)
        // Its review tile goes too.
        for (key, list) in gridReviews where list.contains(where: { $0.value === controller || $0.value == nil }) {
            let rest = list.filter { $0.value != nil && $0.value !== controller }
            gridReviews[key] = rest.isEmpty ? nil : rest
        }
    }

    // MARK: Menu

    func installMenuItem() {
        guard menuItem == nil,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        let item = NSMenuItem(title: "Review Changes", action: #selector(toggleFromMenu(_:)), keyEquivalent: "r")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "text.badge.checkmark")
        // After Grid View's item and its separator, if they're there.
        let index = view.items.firstIndex { $0.keyEquivalent == "e" && $0.keyEquivalentModifierMask == [.command, .shift] }
        view.insertItem(item, at: index.map { $0 + 1 } ?? 0)
        menuItem = item
    }

    /// The tab the menu acts on: the key window's, the grid's focused tile,
    /// or the tab a review window belongs to.
    @MainActor
    private var menuController: BaseTerminalController? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        if let id = windows.first(where: { $0.value === window })?.key {
            return models[id]?.controller
        }
        guard let controller = window.windowController as? BaseTerminalController else { return nil }
        if TerminalGridModel.shared.isActive(for: window),
           let focused = TerminalGridModel.shared.focusedController(in: window) {
            return focused
        }
        return controller
    }

    @MainActor
    @objc private func toggleFromMenu(_ sender: Any?) {
        guard let controller = menuController else { return }
        toggle(for: controller)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleFromMenu(_:)) else { return true }
        guard let controller = menuController else {
            menuItem.title = "Review Changes"
            return false
        }
        if let window = controller.gridWindow ?? controller.window, hasGridReview(of: controller, in: window) {
            menuItem.title = "Remove Review Tile"
        } else {
            menuItem.title = isPanelShown(for: controller) || isWindowShown(for: controller)
                ? "Hide Review" : "Review Changes"
        }
        return true
    }
}

/// A tab's terminal with its review beside it when that's on.
struct ReviewPanelHost<Content: View>: View {
    weak var controller: BaseTerminalController?
    @ViewBuilder let content: () -> Content

    @ObservedObject private var center = ReviewCenter.shared

    var body: some View {
        // Always an HStack, so showing the panel doesn't rebuild the
        // terminals. The panel gets an exact width, measured here: left to
        // the HStack, it got no more than half, because the terminal's own
        // size counted as much as the panel's.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content()
                    .frame(minWidth: 0, maxWidth: .infinity)
                if let controller, center.isPanelShown(for: controller) {
                    PanelResizeHandle(width: $center.panelWidth, defaultWidth: 460)
                        .zIndex(1)
                    ReviewView(
                        model: center.model(for: controller),
                        presentation: .panel,
                        switchPresentation: { [weak controller] in
                            guard let controller else { return }
                            ReviewCenter.shared.showWindow(for: controller)
                        },
                        close: { [weak controller] in
                            guard let controller else { return }
                            ReviewCenter.shared.hidePanel(for: controller)
                        })
                    .frame(width: PanelResizeHandle.fit(center.panelWidth, in: geometry.size.width))
                    // At its narrowest the header is wider than the panel;
                    // it mustn't spill over the edge and take its clicks.
                    .clipped()
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }
}

/// The edge between the terminal and a side panel (review, browser): drag
/// to resize, double-click to go back to the default width.
struct PanelResizeHandle: View {
    @Binding var width: CGFloat
    let defaultWidth: CGFloat

    static let panelMinWidth: CGFloat = 320
    static let terminalMinWidth: CGFloat = 240

    /// A panel's width in `total` points beside a terminal: what it was
    /// dragged to, or less when that leaves the terminal too little.
    static func fit(_ width: CGFloat, in total: CGFloat) -> CGFloat {
        max(panelMinWidth, min(width, total - terminalMinWidth - 5))
    }

    @State private var active = false

    var body: some View {
        Rectangle()
            .fill(active ? ReviewColors.accent.opacity(0.6) : ReviewColors.border)
            .frame(width: 1)
            .padding(.horizontal, 2)
            // The terminal next to it is an AppKit view and would take the
            // mouse and set its own cursor from a SwiftUI gesture, so the
            // edge is an AppKit view too, a little wider than it looks.
            .overlay(
                PanelResizeEdge(width: $width, defaultWidth: defaultWidth, active: $active)
                    .padding(.horizontal, -3))
    }
}

private struct PanelResizeEdge: NSViewRepresentable {
    @Binding var width: CGFloat
    let defaultWidth: CGFloat
    @Binding var active: Bool

    func makeNSView(context: Context) -> EdgeView { EdgeView() }

    func updateNSView(_ view: EdgeView, context: Context) {
        view.width = { width }
        view.setWidth = { width = $0 }
        view.defaultWidth = defaultWidth
        view.setActive = { value in if active != value { active = value } }
    }

    final class EdgeView: NSView {
        var width: () -> CGFloat = { 0 }
        var setWidth: (CGFloat) -> Void = { _ in }
        var defaultWidth: CGFloat = 460
        var setActive: (Bool) -> Void = { _ in }

        private var start: (mouse: CGFloat, width: CGFloat)?
        private var hovering = false { didSet { update() } }
        private var tracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                setWidth(clamp(defaultWidth))
                start = nil
                return
            }
            start = (event.locationInWindow.x, width())
            update()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            NSCursor.resizeLeftRight.set()
            // The panel is on the right: dragging left makes it wider.
            setWidth(clamp(start.width - (event.locationInWindow.x - start.mouse)))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            update()
        }

        /// No narrower than a panel can be, and no wider than leaves room
        /// for the terminal.
        private func clamp(_ value: CGFloat) -> CGFloat {
            let available = (window?.contentView?.bounds.width ?? 10_000) - PanelResizeHandle.terminalMinWidth
            return max(PanelResizeHandle.panelMinWidth, min(value, available))
        }

        private func update() {
            setActive(hovering || start != nil)
        }
    }
}
