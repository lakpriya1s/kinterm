import AppKit
import Combine
import SwiftUI

// Where Markdown Viewers are shown, like the browser and the review: beside a
// tab's terminal, one per tab; in Grid View, one more tile in the grid, one
// per tab, opened for the tile you're in; or in a window of its own, popped
// out of either, or when there's no tab to put it with. View › Markdown
// Viewer (⌘⇧M) toggles the front tab's, on its folder; ⌘-clicking a Markdown
// file in a terminal opens it in the tab's; agents open theirs with
// `kinterm-ctl markdown` (KinTermControl).

// Not main-actor isolated as a whole, like BrowserCenter, so the terminal's
// link handler and views can ask it. Everything here runs on the main thread.
final class MarkdownViewerCenter: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = MarkdownViewerCenter()

    /// Each tab's viewer when it's with the tab rather than in a window:
    /// beside the terminal, or a grid tile. By tab.
    private var docked: [ObjectIdentifier: MarkdownViewerModel] = [:]

    /// Tabs showing their viewer beside the terminal.
    @Published private(set) var panels: Set<ObjectIdentifier> = []

    /// Viewer tiles, by grid (tab group): the tabs they're for, in the order
    /// they were opened.
    @Published private(set) var gridTiles: [ObjectIdentifier: [Weak<BaseTerminalController>]] = [:]

    @Published var panelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "MarkdownPanelWidth")
        return saved > 0 ? saved : 560
    }() {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: "MarkdownPanelWidth") }
    }

    private struct Entry {
        let model: MarkdownViewerModel
        let window: NSWindow
        let title: AnyCancellable
        /// The tab it belongs to: the one it popped out of, or opened for.
        /// It goes back to that tab.
        var from: Weak<BaseTerminalController>
        /// Tabs that opened this window by themselves, after their agent
        /// wrote Markdown. Closing the window stops that for them.
        var owners: [Weak<BaseTerminalController>] = []
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var menuItem: NSMenuItem?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in self?.windowWillClose(window) }
        }
    }

    @MainActor
    private func windowWillClose(_ window: NSWindow) {
        if let entry = entries.removeValue(forKey: ObjectIdentifier(window)) {
            for owner in entry.owners { AgentAutoOpen.shared.dismissed(.markdown, for: owner.value) }
            return
        }
        // A tab's viewer goes when the tab does.
        if let controller = window.windowController as? BaseTerminalController {
            undock(controller)
        }
    }

    // MARK: Where

    private func inGrid(_ controller: BaseTerminalController) -> Bool {
        TerminalGridModel.shared.isActive(for: controller.gridWindow ?? controller.window)
    }

    /// The tab's viewer beside its terminal, if it's shown there.
    func panelModel(for controller: BaseTerminalController?) -> MarkdownViewerModel? {
        guard let controller, panels.contains(ObjectIdentifier(controller)) else { return nil }
        return docked[ObjectIdentifier(controller)]
    }

    /// The tab's viewer, wherever it's docked.
    func dockedModel(for controller: BaseTerminalController) -> MarkdownViewerModel? {
        docked[ObjectIdentifier(controller)]
    }

    /// The window that popped out of the tab, if there is one.
    @MainActor
    private func windowEntry(of controller: BaseTerminalController) -> Entry? {
        entries.values.first { $0.from.value === controller }
    }

    /// The tab's viewer, if it has one, shown where the tab is: beside its
    /// terminal or as its tile in Grid View; or the window that popped out
    /// of it.
    @MainActor
    private func existing(for controller: BaseTerminalController) -> (model: MarkdownViewerModel, window: NSWindow?)? {
        if let model = dockedModel(for: controller) {
            // Moved between tabs and Grid View since: show it where it is now.
            dock(model, for: controller)
            return (model, nil)
        }
        if let entry = windowEntry(of: controller) { return (entry.model, entry.window) }
        return nil
    }

    /// The folder a viewer on `url` covers: its repository, or the folder.
    private static func root(for folder: URL) async -> URL {
        await ReviewGit.root(of: folder.path).map { URL(fileURLWithPath: $0) } ?? folder
    }

    // MARK: Opening

    /// Show a Markdown file. For a tab, in its viewer: beside its terminal,
    /// its grid tile, or the window that popped out of it; a new one beside
    /// it or in the grid when it has none. With no tab, in the window that
    /// already has it open, or one whose folder holds it, or a new window.
    @MainActor
    func open(file: URL, for controller: BaseTerminalController? = nil) {
        let file = file.standardizedFileURL
        let controller = controller ?? frontController
        if let controller {
            if let found = existing(for: controller) {
                show(file, in: found.model)
                found.window?.makeKeyAndOrderFront(nil)
                return
            }
            Task {
                let model = MarkdownViewerModel(root: await Self.root(for: file.deletingLastPathComponent()))
                model.open(file)
                self.dock(model, for: controller)
            }
            return
        }
        let ordered = NSApp.orderedWindows.compactMap { entries[ObjectIdentifier($0)] }
        if let entry = ordered.first(where: { $0.model.current == file }) ?? ordered.first(where: { $0.model.contains(file) }) {
            entry.model.open(file)
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            let model = MarkdownViewerModel(root: await Self.root(for: file.deletingLastPathComponent()))
            model.open(file)
            self.present(model, from: nil)
        }
    }

    /// Show Markdown an agent in `controller`'s tab just wrote, without
    /// taking the keyboard: in the tab's viewer, which switches to it where
    /// it is, or a new one beside the terminal or in the grid.
    /// `before` is the file's text before the turn ("" if the turn made
    /// it): the viewer marks what changed and scrolls to the first change.
    @MainActor
    func autoOpen(file: URL, for controller: BaseTerminalController, before: String? = nil) {
        let file = file.standardizedFileURL
        if let found = existing(for: controller) {
            if let window = found.window { adopt(window, by: controller) }
            found.model.compare(file, with: before)
            if found.model.current != file { show(file, in: found.model) }
            return
        }
        Task {
            let model = MarkdownViewerModel(root: await Self.root(for: file.deletingLastPathComponent()))
            model.compare(file, with: before)
            model.open(file)
            self.dock(model, for: controller)
        }
    }

    /// Open `file` in a viewer that may cover another folder.
    @MainActor
    private func show(_ file: URL, in model: MarkdownViewerModel) {
        if model.contains(file) {
            model.open(file)
            return
        }
        Task {
            model.setRoot(await Self.root(for: file.deletingLastPathComponent()))
            model.open(file)
        }
    }

    @MainActor
    private func adopt(_ window: NSWindow, by controller: BaseTerminalController) {
        let id = ObjectIdentifier(window)
        guard var entry = entries[id], !entry.owners.contains(where: { $0.value === controller }) else { return }
        entry.owners.append(Weak(controller))
        entries[id] = entry
    }

    /// A viewer on a folder, opening its README (or the like) first. For a
    /// tab, its own viewer, as `open(file:for:)`.
    @MainActor
    func open(folder: URL, for controller: BaseTerminalController? = nil) {
        let controller = controller ?? frontController
        Task {
            let root = await Self.root(for: folder)
            let model: MarkdownViewerModel
            if let controller, let found = self.existing(for: controller) {
                model = found.model
                model.setRoot(root)
                found.window?.makeKeyAndOrderFront(nil)
            } else if let controller {
                model = MarkdownViewerModel(root: root)
                self.dock(model, for: controller)
            } else if let entry = self.entries.values.first(where: {
                $0.model.root.standardizedFileURL == root.standardizedFileURL
            }) {
                entry.window.makeKeyAndOrderFront(nil)
                return
            } else {
                model = MarkdownViewerModel(root: root)
                self.present(model, from: nil)
            }
            if let current = model.current, model.contains(current) { return }
            let files = await MarkdownViewerModel.markdownFiles(in: root)
            if let first = MarkdownViewerModel.preferred(in: files) {
                model.open(relative: first)
            }
        }
    }

    enum Target: Equatable {
        case file(URL)
        case folder(URL)
        case missing
        case notMarkdown
    }

    /// What an absolute path asked to be shown (`kinterm-ctl markdown`) is.
    nonisolated static func target(_ path: String) -> Target {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isDirectory.boolValue { return .folder(url) }
        return MarkdownRenderer.isMarkdown(path) ? .file(url) : .notMarkdown
    }

    /// Open a ⌘-clicked path here if it's a Markdown file that exists:
    /// absolute, under `~`, or relative to the front terminal's folder.
    /// Returns whether it did. Called on the main thread.
    nonisolated func openLink(_ value: String) -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            var raw = value
            if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
            guard !raw.contains("://"), MarkdownRenderer.isMarkdown(raw) else { return false }
            var path = (raw as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let pwd = frontController?.focusedSurface?.pwd else { return false }
                path = (pwd as NSString).appendingPathComponent(path)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
            open(file: URL(fileURLWithPath: path))
            return true
        }
    }

    // MARK: Docked: beside the terminal, or a grid tile

    /// With the tab: as its tile in Grid View, else beside its terminal. The
    /// keyboard stays in the terminal.
    @MainActor
    private func dock(_ model: MarkdownViewerModel, for controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        if docked[id] !== model { docked[id] = model }
        model.controller = controller
        if inGrid(controller), let window = controller.gridWindow ?? controller.window {
            panels.remove(id)
            if !hasGridTile(of: controller, in: window) {
                setGridTiles(window) { $0.append(Weak(controller)) }
            }
        } else if !panels.contains(id) {
            panels.insert(id)
        }
    }

    /// Take the tab's viewer away from it, panel and tile, without a word to
    /// its agent session.
    @MainActor
    private func undock(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        docked[id] = nil
        panels.remove(id)
        for (key, list) in gridTiles where list.contains(where: { $0.value === controller || $0.value == nil }) {
            let rest = list.filter { $0.value != nil && $0.value !== controller }
            gridTiles[key] = rest.isEmpty ? nil : rest
            TerminalGridModel.shared.changed()
            AgentTabBarModel.setNeedsRefresh()
        }
    }

    /// Close the tab's viewer (panel or tile) and give the keyboard back to
    /// the tab. Closed by the user, it stops Markdown opening by itself for
    /// the tab's agent session.
    @MainActor
    func close(for controller: BaseTerminalController, byUser: Bool = true) {
        let wasTile = gridTiles.values.contains { $0.contains { $0.value === controller } }
        guard docked[ObjectIdentifier(controller)] != nil else { return }
        undock(controller)
        if byUser { AgentAutoOpen.shared.dismissed(.markdown, for: controller) }
        if wasTile && inGrid(controller) {
            TerminalGridModel.shared.focus(controller)
        } else if let surface = controller.focusedSurface {
            controller.focusSurface(surface)
        }
    }

    /// Move the tab's viewer into a window of its own.
    @MainActor
    func popOut(for controller: BaseTerminalController) {
        guard let model = dockedModel(for: controller) else { return }
        undock(controller)
        present(model, from: controller)
    }

    /// Back with the tab it came from (or the front one): beside its
    /// terminal, or its tile in Grid View.
    @MainActor
    private func putBack(_ window: NSWindow) {
        guard let entry = entries[ObjectIdentifier(window)],
              let controller = entry.from.value ?? frontController else { return }
        // Not a close by the user: forget it before it goes.
        entries[ObjectIdentifier(window)] = nil
        window.close()
        dock(entry.model, for: controller)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: In a grid

    private static func gridKey(_ window: NSWindow) -> ObjectIdentifier {
        ObjectIdentifier(TerminalGridModel.groupObject(for: window))
    }

    /// The tabs the window's viewer tiles are for, in tile order.
    func gridTileControllers(for window: NSWindow?) -> [BaseTerminalController] {
        guard let window, TerminalGridModel.shared.isActive(for: window) else { return [] }
        return (gridTiles[Self.gridKey(window)] ?? []).compactMap(\.value).filter { docked[ObjectIdentifier($0)] != nil }
    }

    func hasGridTile(of controller: BaseTerminalController, in window: NSWindow?) -> Bool {
        gridTileControllers(for: window).contains { $0 === controller }
    }

    private func setGridTiles(_ window: NSWindow, _ change: (inout [Weak<BaseTerminalController>]) -> Void) {
        let key = Self.gridKey(window)
        var list = (gridTiles[key] ?? []).filter { $0.value != nil }
        change(&list)
        gridTiles[key] = list.isEmpty ? nil : list
        TerminalGridModel.shared.changed()
        // Tiles move when one comes or goes; the grid re-syncs its
        // terminals on tab bar changes.
        AgentTabBarModel.setNeedsRefresh()
    }

    // MARK: Windows

    @MainActor
    @discardableResult
    private func present(_ model: MarkdownViewerModel, from controller: BaseTerminalController?,
                         activate: Bool = true) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        if let controller { model.controller = controller }
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        window.title = model.title
        window.contentView = NSHostingView(rootView: MarkdownViewerView(
            model: model,
            placement: .window,
            chooseFolder: { [weak self, weak model, weak window] in
                guard let model else { return }
                self?.chooseFolder(for: model, in: window)
            },
            switchPlacement: { [weak self, weak window] in
                guard let self, let window else { return }
                self.putBack(window)
            },
            close: { [weak window] in window?.close() }))
        window.setFrameAutosaveName("KinTermMarkdownViewerWindow")
        if !window.setFrameUsingName("KinTermMarkdownViewerWindow") {
            if let anchor = controller?.window ?? NSApp.keyWindow {
                window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 60, y: anchor.frame.maxY - 60))
            } else {
                window.center()
            }
        } else if !entries.isEmpty, let last = NSApp.orderedWindows.first(where: { entries[ObjectIdentifier($0)] != nil }) {
            // Cascade from the last viewer rather than sitting on top of it.
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        let title = model.objectWillChange.sink { [weak window, weak model] _ in
            DispatchQueue.main.async {
                guard let model else { return }
                window?.title = model.title
                window?.representedURL = model.current
            }
        }
        entries[ObjectIdentifier(window)] = Entry(model: model, window: window, title: title, from: Weak(controller))
        if activate {
            window.makeKeyAndOrderFront(nil)
        } else {
            // In front, but the keyboard stays in the terminal.
            window.orderFront(nil)
        }
        return window
    }

    @MainActor
    func chooseFolder(for model: MarkdownViewerModel, in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.root
        panel.message = "Choose a folder, or a Markdown file"
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                model.setRoot(url)
                Task {
                    let files = await MarkdownViewerModel.markdownFiles(in: url)
                    if let first = MarkdownViewerModel.preferred(in: files) { model.open(relative: first) }
                }
            } else {
                if !model.contains(url) { model.setRoot(url.deletingLastPathComponent()) }
                model.open(url)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    // MARK: Menu

    @MainActor
    func installMenuItem() {
        guard menuItem == nil,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        let item = NSMenuItem(title: "Markdown Viewer", action: #selector(toggleFromMenu(_:)), keyEquivalent: "m")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "doc.richtext")
        // After the browser's items, if they're there.
        let browser = view.items.firstIndex { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command, .shift] }
        let at = browser.map { $0 + 2 } ?? 0
        view.insertItem(item, at: min(at, view.items.count))
        menuItem = item
    }

    /// The tab the menu, links and agents without a tab act on.
    @MainActor
    private var frontController: BaseTerminalController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map(Optional.some)
        for case let window? in windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if TerminalGridModel.shared.isActive(for: window),
               let focused = TerminalGridModel.shared.focusedController(in: window) {
                return focused
            }
            return controller
        }
        return nil
    }

    /// Whether the tab's viewer shows where the tab is now.
    @MainActor
    private func isDockedShown(for controller: BaseTerminalController) -> Bool {
        if inGrid(controller) { return hasGridTile(of: controller, in: controller.gridWindow ?? controller.window) }
        return panelModel(for: controller) != nil
    }

    /// ⌘⇧M: in a viewer's window, closes it; with a tab, closes its viewer
    /// beside it or its tile; otherwise opens the tab's viewer on its folder.
    @MainActor
    @objc private func toggleFromMenu(_ sender: Any?) {
        if let key = NSApp.keyWindow, entries[ObjectIdentifier(key)] != nil {
            key.close()
            return
        }
        let controller = frontController
        if let controller, isDockedShown(for: controller) {
            close(for: controller)
            return
        }
        AgentAutoOpen.shared.reopened(.markdown, for: controller)
        if let pwd = controller?.focusedSurface?.pwd ?? controller?.surfaceTree.first?.pwd {
            open(folder: URL(fileURLWithPath: pwd), for: controller)
        } else {
            open(folder: FileManager.default.homeDirectoryForCurrentUser, for: controller)
        }
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleFromMenu(_:)) else { return true }
        let isViewerWindow = NSApp.keyWindow.map { entries[ObjectIdentifier($0)] != nil } ?? false
        let shown = isViewerWindow || (frontController.map(isDockedShown(for:)) ?? false)
        menuItem.title = shown ? "Hide Markdown Viewer" : "Markdown Viewer"
        return true
    }
}

/// A tab's terminal with its Markdown Viewer beside it when that's on.
struct MarkdownPanelHost<Content: View>: View {
    weak var controller: BaseTerminalController?
    @ViewBuilder let content: () -> Content

    @ObservedObject private var center = MarkdownViewerCenter.shared

    var body: some View {
        // Always an HStack, so showing the panel doesn't rebuild the
        // terminals.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content()
                    .frame(minWidth: 0, maxWidth: .infinity)
                if let controller, let model = center.panelModel(for: controller) {
                    PanelResizeHandle(width: $center.panelWidth, defaultWidth: 560)
                        .zIndex(1)
                    MarkdownViewerView(
                        model: model,
                        placement: .panel,
                        chooseFolder: { [weak model, weak controller] in
                            guard let model else { return }
                            Task { @MainActor in
                                MarkdownViewerCenter.shared.chooseFolder(for: model, in: controller?.window)
                            }
                        },
                        switchPlacement: { [weak controller] in
                            guard let controller else { return }
                            Task { @MainActor in MarkdownViewerCenter.shared.popOut(for: controller) }
                        },
                        close: { [weak controller] in
                            guard let controller else { return }
                            Task { @MainActor in MarkdownViewerCenter.shared.close(for: controller) }
                        })
                    .frame(width: PanelResizeHandle.fit(center.panelWidth, in: geometry.size.width))
                    .clipped()
                    .id(ObjectIdentifier(model))
                }
            }
        }
    }
}
