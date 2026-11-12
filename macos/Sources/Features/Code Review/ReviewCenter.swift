import AppKit
import SwiftUI

// Where reviews are shown: beside a tab's terminal or in their own window,
// one review per tab. ⌘⇧R (View › Review Changes) toggles the review for the
// focused tab. In Grid View there's no room beside the terminals, so the
// review is one more tile in the grid, reviewing the agent tile you were last
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

    /// Grids with a review tile, by tab group, with the tab under review.
    @Published private(set) var gridReviews: [ObjectIdentifier: Weak<BaseTerminalController>] = [:]

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
            if gridReviewController(for: window) != nil {
                closeGridReview(for: window)
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

    /// The tab the window's review tile is reviewing, if the grid has one.
    func gridReviewController(for window: NSWindow?) -> BaseTerminalController? {
        guard let window, TerminalGridModel.shared.isActive(for: window) else { return nil }
        return gridReviews[Self.gridKey(window)]?.value
    }

    /// Add a review tile to the window's grid.
    @MainActor
    func openGridReview(of controller: BaseTerminalController, in window: NSWindow) {
        let id = ObjectIdentifier(controller)
        panels.remove(id)
        windows[id]?.close()
        gridReviews[Self.gridKey(window)] = Weak(controller)
        model(for: controller).refresh()
        TerminalGridModel.shared.changed()
        // Tiles move when one comes or goes; the grid re-syncs its
        // terminals on tab bar changes.
        AgentTabBarModel.setNeedsRefresh()
    }

    /// Take the review tile out of the grid and give the keyboard back to
    /// the tab it was reviewing.
    @MainActor
    func closeGridReview(for window: NSWindow) {
        let controller = gridReviews.removeValue(forKey: Self.gridKey(window))?.value
        TerminalGridModel.shared.changed()
        // Tiles move when one comes or goes; the grid re-syncs its
        // terminals on tab bar changes.
        AgentTabBarModel.setNeedsRefresh()
        if let controller { TerminalGridModel.shared.focus(controller) }
    }

    /// The review tile follows the agent tile you're in.
    @MainActor
    func gridFocusChanged(to controller: BaseTerminalController, in window: NSWindow) {
        let key = Self.gridKey(window)
        guard let current = gridReviews[key], current.value !== controller else { return }
        gridReviews[key] = Weak(controller)
        model(for: controller).refresh()
    }

    /// Move the review tile into its own window.
    @MainActor
    func popOutGridReview(for window: NSWindow) {
        guard let controller = gridReviewController(for: window) else { return }
        gridReviews[Self.gridKey(window)] = nil
        TerminalGridModel.shared.changed()
        // Tiles move when one comes or goes; the grid re-syncs its
        // terminals on tab bar changes.
        AgentTabBarModel.setNeedsRefresh()
        showWindow(for: controller)
    }

    /// After comments are typed into the agent's prompt, show that prompt.
    @MainActor
    func didSend(from controller: BaseTerminalController, to surface: Ghostty.SurfaceView) {
        if let window = controller.gridWindow ?? controller.window, gridReviewController(for: window) != nil {
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
        if let reviewed = gridReviewController(for: window) { return reviewed }
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
        if let window = controller.gridWindow ?? controller.window, gridReviewController(for: window) != nil {
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
        // terminals.
        HStack(spacing: 0) {
            content()
            if let controller, center.isPanelShown(for: controller) {
                PanelResizeHandle(width: $center.panelWidth)
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
                .frame(width: center.panelWidth)
                .transition(.move(edge: .trailing))
            }
        }
    }
}

/// The edge between the terminal and a side panel (review, browser): drag
/// to resize.
struct PanelResizeHandle: View {
    @Binding var width: CGFloat

    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? ReviewColors.accent.opacity(0.6) : ReviewColors.border)
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? width
                        if start == nil { start = width }
                        width = min(1400, max(320, from - value.translation.width))
                    }
                    .onEnded { _ in start = nil })
    }
}
