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
            if mode != oldValue { selection = nil; render(keepScroll: false) }
        }
    }

    /// Whether the file list shows in a window of its own. On by default:
    /// there's room for it.
    @Published var showsSidebar: Bool =
        UserDefaults.standard.object(forKey: "MarkdownViewerSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "MarkdownViewerSidebar") }
    }

    /// Whether the file list shows beside a terminal or as a grid tile. Off
    /// by default: there it takes room from the page you opened.
    @Published var showsDockedSidebar: Bool =
        UserDefaults.standard.object(forKey: "MarkdownViewerPanelSidebar") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showsDockedSidebar, forKey: "MarkdownViewerPanelSidebar") }
    }

    @Published private(set) var back: [URL] = []
    @Published private(set) var forward: [URL] = []

    /// A heading to scroll to once the page loads.
    @Published private(set) var anchor: String?

    /// Files as they were before an agent's turn changed them, to show
    /// what it changed. Empty: the turn made the file.
    private var baselines: [URL: String] = [:]
    /// How many changes the open file shows, and which one was last shown.
    @Published private(set) var changeCount = 0
    @Published private(set) var changeIndex = 0
    /// The open file is one the agent made: all of it is new.
    @Published private(set) var isNewFile = false
    /// Whether changes are marked. Off, the page reads as it is.
    @Published var showsChanges = true {
        didSet { if showsChanges != oldValue { render(keepScroll: true) } }
    }
    /// A file whose first change to scroll to once it's rendered.
    private var revealing: URL?

    // Comments for the agent, and the picture being looked at closely. See
    // MarkdownViewerComments.swift.

    /// The text selected on the page, offered for a comment.
    @Published var selection: MarkdownSelection?
    /// The passage a comment is being written on.
    @Published var composing: MarkdownSelection?
    @Published var comments: [MarkdownComment] = []
    /// Whether the comments waiting to be sent are listed.
    @Published var showsComments = false
    /// A picture on the page shown large.
    @Published var zoomedImage: MarkdownImage?
    /// The tab whose agent the comments go to.
    weak var controller: BaseTerminalController?

    private(set) var text = ""
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
        selection = nil
        composing = nil
        zoomedImage = nil
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
        let baseline = baselines[current]
        isNewFile = baseline?.isEmpty == true
        var changes: MarkdownLineChanges?
        if showsChanges, let baseline, !baseline.isEmpty {
            changes = MarkdownLineChanges.between(baseline, text)
        }
        let page = mode == .rendered
            ? MarkdownRenderer.page(text, file: current, changes: changes)
            : MarkdownRenderer.sourcePage(text, changes: changes)
        changeCount = page.changes
        if changeIndex >= changeCount { changeIndex = 0 }
        if revealing == current {
            revealing = nil
            if changeCount > 0 {
                changeIndex = 0
                anchor = Self.changeID(0)
            }
        }
        html = page.html
        if keepScroll { revision += 1 } else { revision = 0 }
    }

    // MARK: Changes

    nonisolated static func changeID(_ index: Int) -> String { "kt-change-\(index)" }

    /// Show what changed in `url` since `before`, its text before an
    /// agent's turn ("" when the turn made it; nil when it isn't known),
    /// and scroll to the first change when it's shown.
    func compare(_ url: URL, with before: String?) {
        let url = url.standardizedFileURL
        baselines[url] = before
        guard before != nil else { return }
        showsChanges = true
        revealing = url
        if url == current { load(keepScroll: true) }
    }

    func nextChange() { goToChange(changeIndex + 1) }
    func previousChange() { goToChange(changeIndex - 1) }

    private func goToChange(_ index: Int) {
        guard changeCount > 0 else { return }
        changeIndex = (index % changeCount + changeCount) % changeCount
        anchor = Self.changeID(changeIndex)
    }

    /// Done reading the changes: show the page as it is.
    func dismissChanges() {
        guard let current else { return }
        baselines[current] = nil
        render(keepScroll: true)
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
