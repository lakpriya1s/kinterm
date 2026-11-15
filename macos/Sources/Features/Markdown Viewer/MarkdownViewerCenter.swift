import AppKit
import Combine
import SwiftUI

// Markdown Viewer windows, like the browser's own window: View › Markdown
// Viewer (⌘⇧M) opens one on the front terminal's folder, ⌘-clicking a
// Markdown file in a terminal opens it in one, and agents open one with
// `kinterm-ctl markdown` (KinTermControl).

// Not main-actor isolated as a whole, like BrowserCenter, so the terminal's
// link handler can ask it. Everything here runs on the main thread.
final class MarkdownViewerCenter: NSObject, NSMenuItemValidation {
    static let shared = MarkdownViewerCenter()

    private struct Entry {
        let model: MarkdownViewerModel
        let window: NSWindow
        let title: AnyCancellable
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var menuItem: NSMenuItem?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in self?.entries[ObjectIdentifier(window)] = nil }
        }
    }

    // MARK: Opening

    /// Show a Markdown file: in the window that already has it open, or one
    /// whose folder holds it, or a new window on its repository.
    @MainActor
    func open(file: URL) {
        let file = file.standardizedFileURL
        let ordered = NSApp.orderedWindows.compactMap { entries[ObjectIdentifier($0)] }
        if let entry = ordered.first(where: { $0.model.current == file }) ?? ordered.first(where: { $0.model.contains(file) }) {
            entry.model.open(file)
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        let folder = file.deletingLastPathComponent()
        Task {
            let root = await ReviewGit.root(of: folder.path).map { URL(fileURLWithPath: $0) } ?? folder
            let model = MarkdownViewerModel(root: root)
            model.open(file)
            self.present(model)
        }
    }

    /// A window on a folder, opening its README (or the like) first.
    @MainActor
    func open(folder: URL) {
        Task {
            let root = await ReviewGit.root(of: folder.path).map { URL(fileURLWithPath: $0) } ?? folder
            if let entry = entries.values.first(where: { $0.model.root.standardizedFileURL == root.standardizedFileURL }) {
                entry.window.makeKeyAndOrderFront(nil)
                return
            }
            let model = MarkdownViewerModel(root: root)
            self.present(model)
            let files = await MarkdownViewerModel.markdownFiles(in: root)
            if model.current == nil, let first = MarkdownViewerModel.preferred(in: files) {
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

    @MainActor
    private func present(_ model: MarkdownViewerModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        window.title = model.title
        window.contentView = NSHostingView(rootView: MarkdownViewerView(
            model: model,
            chooseFolder: { [weak self, weak model, weak window] in
                guard let model else { return }
                self?.chooseFolder(for: model, in: window)
            }))
        window.setFrameAutosaveName("KinTermMarkdownViewerWindow")
        if !window.setFrameUsingName("KinTermMarkdownViewerWindow") {
            if let anchor = NSApp.keyWindow {
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
        entries[ObjectIdentifier(window)] = Entry(model: model, window: window, title: title)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func chooseFolder(for model: MarkdownViewerModel, in window: NSWindow?) {
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
        let item = NSMenuItem(title: "Markdown Viewer", action: #selector(openFromMenu(_:)), keyEquivalent: "m")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "doc.richtext")
        // After the browser's items, if they're there.
        let browser = view.items.firstIndex { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command, .shift] }
        let at = browser.map { $0 + 2 } ?? 0
        view.insertItem(item, at: min(at, view.items.count))
        menuItem = item
    }

    /// The terminal the menu acts on.
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

    @MainActor
    @objc private func openFromMenu(_ sender: Any?) {
        let controller = frontController
        if let pwd = controller?.focusedSurface?.pwd ?? controller?.surfaceTree.first?.pwd {
            open(folder: URL(fileURLWithPath: pwd))
        } else {
            open(folder: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}
