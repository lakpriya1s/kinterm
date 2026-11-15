import AppKit
import Combine
import Foundation

// One Markdown Viewer window: the Markdown files in a folder down the side,
// the open one rendered (or as source), and the file watched so an agent's
// edits show as they land.

@MainActor
final class MarkdownViewerModel: ObservableObject {
    enum Mode: String { case rendered, source }

    /// The folder the side list covers: the repository, or a plain folder.
    @Published private(set) var root: URL
    @Published private(set) var files: [String] = []
    @Published private(set) var listing = false
    @Published var query = ""

    @Published private(set) var current: URL?
    /// The page the web view shows.
    @Published private(set) var html = ""
    /// Bumped when the same file is shown again, so the view keeps its
    /// scroll position; a new file starts at the top.
    @Published private(set) var revision = 0
    @Published private(set) var problem: String?

    @Published var mode: Mode =
        Mode(rawValue: UserDefaults.standard.string(forKey: "MarkdownViewerMode") ?? "") ?? .rendered {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "MarkdownViewerMode")
            if mode != oldValue { render(keepScroll: false) }
        }
    }

    @Published var showsSidebar: Bool =
        UserDefaults.standard.object(forKey: "MarkdownViewerSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "MarkdownViewerSidebar") }
    }

    @Published private(set) var back: [URL] = []
    @Published private(set) var forward: [URL] = []

    /// A heading to scroll to once the page loads.
    @Published private(set) var anchor: String?

    private var text = ""
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var listTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        listFiles()
    }

    deinit {
        watcher?.cancel()
        listTask?.cancel()
    }

    var title: String {
        current?.lastPathComponent ?? root.lastPathComponent
    }

    /// The open file, relative to the root when it's inside it.
    var currentPath: String? {
        guard let current else { return nil }
        return relativePath(current) ?? (current.path as NSString).abbreviatingWithTildeInPath
    }

    var filteredFiles: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return files }
        return files.filter { $0.lowercased().contains(q) }
    }

    func relativePath(_ url: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    func contains(_ url: URL) -> Bool { relativePath(url) != nil }

    // MARK: Opening

    /// Show `url`, remembering where we were for Back.
    func open(_ url: URL, anchor: String? = nil) {
        let url = url.standardizedFileURL
        if url == current {
            if let anchor { self.anchor = anchor; revision += 1 }
            return
        }
        if let current {
            back.append(current)
            forward = []
        }
        show(url, anchor: anchor)
    }

    func open(relative path: String) {
        open(root.appendingPathComponent(path))
    }

    func goBack() {
        guard let url = back.popLast() else { return }
        if let current { forward.append(current) }
        show(url, anchor: nil)
    }

    func goForward() {
        guard let url = forward.popLast() else { return }
        if let current { back.append(current) }
        show(url, anchor: nil)
    }

    /// Change the folder the side list covers.
    func setRoot(_ url: URL) {
        guard url.standardizedFileURL != root.standardizedFileURL else { return }
        root = url.standardizedFileURL
        listFiles()
    }

    private func show(_ url: URL, anchor: String?) {
        current = url
        self.anchor = anchor
        load(keepScroll: false)
        watch(url)
        // A file made since the list was built, like a plan an agent just
        // wrote: list it.
        if !listing, let path = relativePath(url), !files.contains(path) { listFiles() }
    }

    func reload() {
        load(keepScroll: true)
        listFiles()
    }

    private func load(keepScroll: Bool) {
        guard let current else { return }
        guard let data = try? Data(contentsOf: current) else {
            problem = FileManager.default.fileExists(atPath: current.path)
                ? "This file can't be read."
                : "This file isn't there any more."
            text = ""
            html = ""
            return
        }
        problem = nil
        // swiftlint:disable:next optional_data_string_conversion
        text = String(decoding: data, as: UTF8.self)
        render(keepScroll: keepScroll)
    }

    private func render(keepScroll: Bool) {
        guard let current, problem == nil else { return }
        html = mode == .rendered
            ? MarkdownRenderer.page(text, file: current)
            : MarkdownRenderer.sourcePage(text)
        if keepScroll { revision += 1 } else { revision = 0 }
    }

    // MARK: Watching

    /// Reload when the file changes. Editors and agents often write a new
    /// file and rename it over the old one, so watch again after a rename or
    /// delete.
    private func watch(_ url: URL) {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            self.scheduleReload(rewatch: replaced)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload(rewatch: Bool) {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.current else { return }
            self.load(keepScroll: true)
            if rewatch { self.watch(current) }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Listing

    private func listFiles() {
        listTask?.cancel()
        listing = true
        let root = root
        listTask = Task { [weak self] in
            let files = await Self.markdownFiles(in: root)
            guard !Task.isCancelled else { return }
            self?.files = files
            self?.listing = false
        }
    }

    /// Markdown files under `root`: git's view of them when it's a
    /// repository (so ignored folders stay out), else a walk of the folder.
    nonisolated static func markdownFiles(in root: URL) async -> [String] {
        let path = root.path
        var all: [String]
        if await ReviewGit.root(of: path) != nil, let files = try? await ReviewGit.allFiles(in: path) {
            all = files
        } else {
            all = walk(root)
        }
        all = all.filter(MarkdownRenderer.isMarkdown)
        return all.sorted { a, b in
            // Top-level files first, then by folder.
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if (da == 1) != (db == 1) { return da == 1 }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private nonisolated static func walk(_ root: URL) -> [String] {
        let skip: Set<String> = ["node_modules", "build", "dist", "target", "Pods", "DerivedData", "vendor"]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.level > 6 { enumerator.skipDescendants() }
            guard MarkdownRenderer.isMarkdown(url.path) else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base + "/") { out.append(String(path.dropFirst(base.count + 1))) }
            if out.count >= 5000 { break }
        }
        return out
    }

    /// The file to start with in a folder: a README, the agent notes, or
    /// the first one listed.
    static func preferred(in files: [String]) -> String? {
        let names = ["README.md", "readme.md", "Readme.md", "AGENTS.md", "CLAUDE.md"]
        for name in names where files.contains(name) { return name }
        return files.first
    }

    // MARK: Actions

    func openInEditor() {
        guard let current else { return }
        NSWorkspace.shared.open(current)
    }

    func revealInFinder() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    func copyPath() {
        guard let current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.path, forType: .string)
    }

    /// A link clicked in the page.
    func follow(_ url: URL) {
        if url.isFileURL {
            let file = URL(fileURLWithPath: url.path)
            if MarkdownRenderer.isMarkdown(file.path), FileManager.default.fileExists(atPath: file.path) {
                open(file, anchor: url.fragment)
            } else if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.open(file)
            }
            return
        }
        if !BrowserCenter.shared.openLink(url) {
            NSWorkspace.shared.open(url)
        }
    }

    func anchorShown() { anchor = nil }
}
