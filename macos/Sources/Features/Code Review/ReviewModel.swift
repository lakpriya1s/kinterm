import AppKit
import Combine
import SwiftUI

// The state behind one tab's review: which repository, which changes, what
// you've looked at, and the comments you're writing for the agent. See
// scope/designs/08-code-review.md.

enum ReviewColors {
    static let background = Color(hex: 0x1B1C21)
    static let surface = Color(hex: 0x22242A)
    static let card = Color(hex: 0x24262D)
    static let border = Color(hex: 0x3A3D47)
    static let selected = Color(hex: 0x363944)
    static let hovered = Color(hex: 0x2C2E35)
    static let text = Color(hex: 0xE6EDF3)
    static let secondary = Color(hex: 0x8B9099)
    static let accent = Color(hex: 0x5CA0FF)

    static let addedText = Color(hex: 0x3FB950)
    static let removedText = Color(hex: 0xF85149)
    static let renamedText = Color(hex: 0xD29922)
    static let addedLine = Color(hex: 0x2EA043).opacity(0.16)
    static let removedLine = Color(hex: 0xF85149).opacity(0.16)
    static let addedGutter = Color(hex: 0x2EA043).opacity(0.28)
    static let removedGutter = Color(hex: 0xF85149).opacity(0.28)
    static let hunkLine = Color(hex: 0x388BFD).opacity(0.12)

    static let keyword = Color(hex: 0xFF7B72)
    static let string = Color(hex: 0xA5D6FF)
    static let comment = Color(hex: 0x8B949E)
    static let number = Color(hex: 0x79C0FF)
    static let function = Color(hex: 0xD2A8FF)
    static let type = Color(hex: 0xFFA657)

    static func status(_ status: ReviewFileDiff.Status) -> Color {
        switch status {
        case .added: return addedText
        case .deleted: return removedText
        case .renamed: return renamedText
        case .modified: return Color(hex: 0xE3B341)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// A comment on one line, for the agent.
struct ReviewComment: Identifiable, Hashable {
    let id = UUID()
    let path: String
    /// The line number in the file as it is now, or in the old file for a
    /// removed line.
    let line: Int
    let removed: Bool
    /// The line's code, quoted so the agent finds it even if lines moved.
    let code: String
    var text: String

    var location: String { removed ? "\(path) (removed line \(line))" : "\(path):\(line)" }
}

/// Where a line comment is being written.
struct ReviewCommentTarget: Hashable {
    let path: String
    let line: Int
    let removed: Bool
    let code: String
}

/// A line ready to draw: its colors are worked out once, off the main thread.
struct ReviewRow: Identifiable {
    enum Kind { case hunk(ReviewHunk), line(ReviewDiffLine), plain(Int) }

    let id: Int
    let kind: Kind
    let text: AttributedString
}

@MainActor
final class ReviewModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case uncommitted, session, lastTurn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .uncommitted: return "Uncommitted"
            case .session: return "This Session"
            case .lastTurn: return "Last Turn"
            }
        }
        var help: String {
            switch self {
            case .uncommitted: return "Everything not committed yet, compared with HEAD"
            case .session: return "What changed since the agent's first prompt in this tab"
            case .lastTurn: return "What changed since your last prompt to the agent"
            }
        }
    }

    enum Tab: String { case changes, files }

    /// How the Changes tab lays out files: one flat list, or folders.
    enum ChangesLayout: String { case list, tree }

    enum Viewer: Equatable {
        case none
        case diff(String)
        case file(String)
    }

    weak private(set) var controller: BaseTerminalController?

    @Published var tab: Tab = .changes
    @Published var scope: Scope = .uncommitted { didSet { if scope != oldValue { refresh() } } }

    /// The folder paths are relative to: the terminal's repository, or the
    /// folder of the workspace it's in.
    @Published private(set) var root: String?
    @Published private(set) var workspace: ReviewWorkspace?
    /// Branch and diff base of each repository, by prefix.
    @Published private(set) var repoStates: [String: ReviewRepoState] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// The repository of the terminal itself, for paths in messages.
    private var terminalRoot: String?

    /// Show only this repository, by prefix; nil for all of them.
    @Published var focusedRepo: String? {
        didSet { if focusedRepo != oldValue { applyFilter(); rebuildFileTree() } }
    }
    /// Show files that `files.exclude` hides.
    @Published var showExcluded = false {
        didSet { if showExcluded != oldValue { applyFilter(); rebuildFileTree() } }
    }

    /// Every change, in every repository.
    private var allChanges: [ReviewFileDiff] = []
    /// The changes shown: in the focused repository, and not excluded.
    @Published private(set) var files: [ReviewFileDiff] = [] { didSet { rebuildChangeTree() } }
    /// Changes left out because `files.exclude` hides them.
    @Published private(set) var excludedCount = 0
    /// Changes shown per repository, by prefix, for the repository menu.
    @Published private(set) var repoCounts: [String: Int] = [:]
    /// Whether the Files tab's tree is being built.
    @Published private(set) var treeLoading = false
    private var treeGeneration = 0
    @Published var viewer: Viewer = .none {
        didSet {
            guard viewer != oldValue else { return }
            if case .diff(let path) = viewer { reveal(path) }
            loadViewer()
        }
    }

    @Published var changesLayout: ChangesLayout =
        ChangesLayout(rawValue: UserDefaults.standard.string(forKey: "ReviewChangesLayout") ?? "") ?? .tree {
        didSet { UserDefaults.standard.set(changesLayout.rawValue, forKey: "ReviewChangesLayout") }
    }
    /// Collapsed folders in the Changes tree, by id. Kept across refreshes so
    /// folders you've put away stay put away while the agent works.
    @Published var collapsed: Set<String> = []
    @Published private(set) var changeTree: [ReviewChangeNode] = []
    /// The changed files in the order the tree shows them.
    private var treeOrder: [ReviewFileDiff] = []
    @Published private(set) var rows: [ReviewRow] = []
    @Published private(set) var viewerNote: String?
    /// A Quick Look preview, for files that aren't text.
    @Published private(set) var preview: ReviewPreview?
    /// Where the old side of a previewed diff is written; removed when the
    /// preview changes.
    private var previewTemp: URL?

    /// Viewed files, by path, with the diff they were viewed at.
    @Published private var viewed: [String: Int] = [:]

    @Published var comments: [ReviewComment] = []
    @Published var composing: ReviewCommentTarget?
    @Published var note = ""

    @Published private(set) var tree: [ReviewTreeNode] = []
    @Published private(set) var allFiles: [String] = []
    /// Each repository's files, by prefix, with workspace paths.
    private var repoFiles: [String: [String]] = [:]
    @Published var fileQuery = ""

    private var refreshTask: Task<Void, Never>?
    private var viewerTask: Task<Void, Never>?
    private var statusCancellable: AnyCancellable?
    private var lastState: Ghostty.Action.ProgramStatus.State?

    init(controller: BaseTerminalController) {
        self.controller = controller
        // Look again when the agent finishes or stops to ask something.
        statusCancellable = controller.$programStatus
            .map { $0?.state }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                defer { self.lastState = state }
                if self.lastState == .working, state != .working { self.refresh() }
            }
    }

    var repoName: String {
        if let headerRepo { return headerRepo.name }
        return workspace?.name ?? "No repository"
    }

    var tabTitle: String {
        guard let window = controller?.window else { return "Terminal" }
        return window.title.isEmpty ? "Terminal" : window.title
    }

    var repos: [ReviewRepo] { workspace?.repos ?? [] }
    var isMultiRepo: Bool { repos.count > 1 }

    func repo(_ prefix: String) -> ReviewRepo? { repos.first { $0.prefix == prefix } }

    /// The repository a workspace path is in: the one with the longest
    /// matching prefix.
    func repo(containing path: String) -> ReviewRepo? {
        repos.filter { path.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
    }

    /// Where a workspace path is on disk.
    func url(for path: String) -> URL? {
        guard let repo = repo(containing: path) else { return nil }
        return URL(fileURLWithPath: repo.root).appendingPathComponent(String(path.dropFirst(repo.prefix.count)))
    }

    /// How many changes a repository has, not counting excluded ones.
    func changeCount(_ repo: ReviewRepo) -> Int { repoCounts[repo.prefix] ?? 0 }

    /// The repository the header is about: the focused one, or the only one.
    var headerRepo: ReviewRepo? {
        if let focusedRepo { return repo(focusedRepo) }
        return isMultiRepo ? nil : repos.first
    }

    var branch: String? { headerRepo.flatMap { repoStates[$0.prefix]?.branch } }

    var totals: (added: Int, removed: Int) {
        files.reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }

    func isViewed(_ file: ReviewFileDiff) -> Bool { viewed[file.path] == file.fingerprint }

    var viewedCount: Int { files.filter(isViewed).count }

    func toggleViewed(_ file: ReviewFileDiff) {
        if isViewed(file) {
            viewed[file.path] = nil
        } else {
            viewed[file.path] = file.fingerprint
            // Like GitHub: marking a file viewed moves you on to the next.
            if case .diff(let path) = viewer, path == file.path { openNextUnviewed() }
        }
    }

    /// The changed files in the order the Changes tab shows them.
    var orderedFiles: [ReviewFileDiff] { changesLayout == .tree ? treeOrder : files }

    private func openNextUnviewed() {
        if let next = orderedFiles.first(where: { !isViewed($0) }) { viewer = .diff(next.path) }
    }

    // MARK: Changes tree

    /// How many files under a folder have been viewed.
    func viewedCount(_ node: ReviewChangeNode) -> Int { node.files.filter(isViewed).count }

    /// Marks everything in a folder viewed and puts the folder away, or, if
    /// it's all viewed already, marks it all not viewed again.
    func toggleViewed(folder node: ReviewChangeNode) {
        let allViewed = node.files.allSatisfy(isViewed)
        var viewed = viewed
        for file in node.files { viewed[file.path] = allViewed ? nil : file.fingerprint }
        self.viewed = viewed
        guard !allViewed else { return }
        collapsed.insert(node.id)
        if case .diff(let path) = viewer, node.files.contains(where: { $0.path == path }) { openNextUnviewed() }
    }

    func toggleCollapsed(_ node: ReviewChangeNode) {
        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
    }

    func collapseAll() {
        var ids = Set<String>()
        func walk(_ nodes: [ReviewChangeNode]) {
            for node in nodes where node.isFolder {
                ids.insert(node.id)
                walk(node.children)
            }
        }
        walk(changeTree)
        collapsed = ids
    }

    func expandAll() { collapsed = [] }

    /// The tree's rows that aren't inside a collapsed folder.
    var visibleChangeRows: [ReviewChangeRow] {
        var rows: [ReviewChangeRow] = []
        func walk(_ nodes: [ReviewChangeNode], depth: Int) {
            for node in nodes {
                rows.append(ReviewChangeRow(node: node, depth: depth))
                if node.isFolder, !collapsed.contains(node.id) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(changeTree, depth: 0)
        return rows
    }

    /// Opens the folders around a file so it can be seen.
    private func reveal(_ path: String) {
        var around: [String] = []
        var level = changeTree
        while let folder = level.first(where: { $0.isFolder && $0.files.contains { $0.path == path } }) {
            if collapsed.contains(folder.id) { around.append(folder.id) }
            level = folder.children
        }
        if !around.isEmpty { collapsed.subtract(around) }
    }

    private func rebuildChangeTree() {
        if isMultiRepo, focusedRepo == nil {
            // One group per repository, in the workspace's order.
            changeTree = repos.compactMap { repo in
                let mine = files.filter { $0.repo == repo.prefix }
                guard !mine.isEmpty else { return nil }
                return ReviewChangeNode(
                    id: "repo:" + repo.prefix, name: repo.name, file: nil,
                    children: ReviewChangeNode.build(mine, prefix: repo.prefix),
                    files: mine, repo: repo.prefix)
            }
        } else {
            changeTree = ReviewChangeNode.build(files, prefix: focusedRepo ?? "")
        }
        var order: [ReviewFileDiff] = []
        func walk(_ nodes: [ReviewChangeNode]) {
            for node in nodes {
                if let file = node.file { order.append(file) } else { walk(node.children) }
            }
        }
        walk(changeTree)
        treeOrder = order
    }

    func file(at path: String) -> ReviewFileDiff? { files.first { $0.path == path } }

    // MARK: Loading

    /// The repository of the tab's focused terminal.
    private var pwd: String? {
        controller?.focusedSurface?.pwd ?? controller?.surfaceTree.first?.pwd
    }

    func refresh() {
        refreshTask?.cancel()
        let pwd = pwd
        let scope = scope
        let controllerID = controller.map(ObjectIdentifier.init)
        loading = true
        refreshTask = Task { [weak self] in
            guard let pwd, let workspace = await ReviewWorkspace.discover(from: pwd) else {
                await MainActor.run {
                    self?.root = nil
                    self?.workspace = nil
                    self?.allChanges = []
                    self?.applyFilter()
                    self?.tree = []
                    self?.loading = false
                    self?.error = pwd == nil
                        ? "This tab hasn't reported its folder yet."
                        : "\(pwd ?? "") isn't in a git repository."
                }
                return
            }
            let terminalRoot = await ReviewGit.root(of: pwd)

            // Each repository's snapshot for this scope, if one was taken.
            var snapshots: [String: ReviewSnapshot] = [:]
            var missingSnapshot = false
            if scope != .uncommitted {
                for repo in workspace.repos {
                    let turns = controllerID.flatMap { ReviewSnapshots.shared.turns(for: $0, root: repo.root) }
                    if let snapshot = scope == .session ? turns?.first : turns?.last {
                        snapshots[repo.prefix] = snapshot
                    } else {
                        missingSnapshot = true
                    }
                }
            }

            let results = await withTaskGroup(of: (Int, ReviewRepoResult).self) { group in
                for (i, repo) in workspace.repos.enumerated() {
                    let snapshot = snapshots[repo.prefix]
                    group.addTask { (i, await Self.load(repo, snapshot: snapshot)) }
                }
                var results = [ReviewRepoResult?](repeating: nil, count: workspace.repos.count)
                for await (i, result) in group { results[i] = result }
                return results.compactMap { $0 }
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                let reposChanged = self.workspace != workspace
                self.root = workspace.root
                self.workspace = workspace
                self.terminalRoot = terminalRoot
                if let focused = self.focusedRepo, workspace.repos.allSatisfy({ $0.prefix != focused }) {
                    self.focusedRepo = nil
                }
                var states: [String: ReviewRepoState] = [:]
                var errors: [String] = []
                for (repo, result) in zip(workspace.repos, results) {
                    states[repo.prefix] = result.state
                    if let error = result.error {
                        errors.append(workspace.repos.count > 1 ? "\(repo.name): \(error)" : error)
                    }
                }
                if missingSnapshot {
                    errors.insert("No agent prompt seen in this tab yet, so this shows everything uncommitted.", at: 0)
                }
                self.repoStates = states
                self.allChanges = results.flatMap(\.files)
                self.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
                self.loading = false
                self.applyFilter()
                if reposChanged || self.tree.isEmpty { self.loadTree() }
            }
        }
    }

    /// One repository's branch and changes, with workspace paths.
    nonisolated private static func load(_ repo: ReviewRepo, snapshot: ReviewSnapshot?) async -> ReviewRepoResult {
        let branch = await ReviewGit.branch(in: repo.root)
        var base = await ReviewGit.head(in: repo.root)
        if let snapshot { base = snapshot.commit }
        let state = ReviewRepoState(branch: branch, base: base)
        do {
            let files = try await ReviewGit.changes(in: repo.root, against: base, snapshot: snapshot)
            return ReviewRepoResult(state: state, files: files.map { $0.inRepo(repo.prefix) }, error: nil)
        } catch {
            return ReviewRepoResult(state: state, files: [], error: error.localizedDescription)
        }
    }

    /// Picks the changes to show from all of them, and keeps the open file
    /// open if it's still among them.
    private func applyFilter() {
        let reposByPrefix = Dictionary(repos.map { ($0.prefix, $0) }, uniquingKeysWith: { a, _ in a })
        var excluded = 0
        var counts: [String: Int] = [:]
        var shown: [ReviewFileDiff] = []
        for file in allChanges {
            if !showExcluded, let repo = reposByPrefix[file.repo], repo.isExcluded(file.gitPath) {
                if focusedRepo == nil || focusedRepo == file.repo { excluded += 1 }
                continue
            }
            counts[file.repo, default: 0] += 1
            if focusedRepo == nil || focusedRepo == file.repo { shown.append(file) }
        }
        repoCounts = counts
        files = shown
        excludedCount = excluded
        updateTreeStatus()
        reselect()
    }

    /// The diff base of the repository a file is in.
    private func base(of file: ReviewFileDiff) -> String {
        repoStates[file.repo]?.base ?? ReviewGit.emptyTree
    }

    /// Keep the open file if it's still changed, else open the first one.
    private func reselect() {
        switch viewer {
        case .diff(let path):
            if let file = file(at: path) {
                // Reload only if the diff itself changed.
                if file.fingerprint != shownFingerprint { loadViewer() }
            } else {
                viewer = orderedFiles.first.map { .diff($0.path) } ?? .none
            }
        case .file:
            loadViewer()
        case .none:
            if tab == .changes, let first = orderedFiles.first { viewer = .diff(first.path) }
        }
    }

    /// The diff the viewer shows, to tell when it needs loading again.
    private var shownFingerprint: Int?

    private func loadViewer() {
        viewerTask?.cancel()
        composing = nil
        shownFingerprint = nil
        clearPreview()
        switch viewer {
        case .none:
            rows = []
            viewerNote = nil

        case .diff(let path):
            guard let file = file(at: path) else { rows = []; return }
            shownFingerprint = file.fingerprint
            if file.binary {
                rows = []
                viewerNote = nil
                previewDiff(of: file)
                return
            }
            if file.hunks.isEmpty {
                rows = []
                viewerNote = file.status == .renamed ? "Renamed without changes." : "No changes to show."
                return
            }
            viewerNote = file.lineCount > 20000 ? "Large diff: showing the first 20,000 lines." : nil
            viewerTask = Task.detached(priority: .userInitiated) { [weak self] in
                let rows = Self.rows(for: file)
                guard !Task.isCancelled else { return }
                await self?.show(rows, note: nil)
            }

        case .file(let path):
            guard let repo = repo(containing: path) else { rows = []; return }
            let root = repo.root
            let gitPath = String(path.dropFirst(repo.prefix.count))
            viewerNote = nil
            viewerTask = Task.detached(priority: .userInitiated) { [weak self] in
                let contents = ReviewGit.contents(of: gitPath, in: root)
                var rows: [ReviewRow] = []
                var note: String?
                switch contents {
                case .text(let text):
                    var highlighter = ReviewHighlighter(path: path)
                    var n = 0
                    text.enumerateLines { line, _ in
                        n += 1
                        rows.append(ReviewRow(id: n, kind: .plain(n), text: highlighter.highlight(line)))
                    }
                case .binary, .tooLarge:
                    // Quick Look shows what it can: images, PDFs, movies...
                    let url = URL(fileURLWithPath: root).appendingPathComponent(gitPath)
                    guard !Task.isCancelled else { return }
                    await self?.showPreview(ReviewPreview(before: nil, after: url))
                    return
                case .unreadable: note = "This file can't be read."
                }
                guard !Task.isCancelled else { return }
                let done = rows
                await self?.show(done, note: note)
            }
        }
    }

    /// A changed file that isn't text: the old and new versions side by side.
    private func previewDiff(of file: ReviewFileDiff) {
        guard let repo = repo(file.repo) else { return }
        let root = repo.root
        let after = file.status == .deleted ? nil : URL(fileURLWithPath: root).appendingPathComponent(file.gitPath)
        preview = ReviewPreview(before: nil, after: after)
        guard file.status != .added, !file.untracked else { return }
        let base = base(of: file)
        let oldPath = file.gitOldPath ?? file.gitPath
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinterm-review", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        previewTemp = dir
        viewerTask = Task { [weak self] in
            let before = await ReviewGit.export(oldPath, at: base, in: root, to: dir)
            guard !Task.isCancelled, let before else { return }
            await MainActor.run { self?.preview = ReviewPreview(before: before, after: after) }
        }
    }

    private func showPreview(_ preview: ReviewPreview) {
        rows = []
        viewerNote = nil
        self.preview = preview
    }

    private func clearPreview() {
        preview = nil
        if let previewTemp {
            try? FileManager.default.removeItem(at: previewTemp)
            self.previewTemp = nil
        }
    }

    private func show(_ rows: [ReviewRow], note: String?) {
        self.rows = rows
        if note != nil || rows.isEmpty { viewerNote = note }
    }

    nonisolated private static func rows(for file: ReviewFileDiff) -> [ReviewRow] {
        var rows: [ReviewRow] = []
        var id = 0
        var total = 0
        for hunk in file.hunks {
            rows.append(ReviewRow(id: id, kind: .hunk(hunk), text: AttributedString(hunk.header)))
            id += 1
            // Each side of the diff is its own text, so color them apart.
            var old = ReviewHighlighter(path: file.oldPath ?? file.path)
            var new = ReviewHighlighter(path: file.path)
            for line in hunk.lines {
                let text: AttributedString
                switch line.kind {
                case .context:
                    text = new.highlight(line.text)
                    _ = old.highlight(line.text)
                case .added: text = new.highlight(line.text)
                case .removed: text = old.highlight(line.text)
                case .noNewline:
                    var note = AttributedString(line.text)
                    note.foregroundColor = ReviewColors.secondary
                    text = note
                }
                rows.append(ReviewRow(id: id, kind: .line(line), text: text))
                id += 1
                total += 1
                if total >= 20000 { return rows }
            }
        }
        return rows
    }

    // MARK: Files tab

    private func loadTree() {
        guard let workspace else { return }
        treeLoading = true
        Task { [weak self] in
            let lists = await withTaskGroup(of: (String, [String]).self) { group in
                for repo in workspace.repos {
                    group.addTask {
                        let paths = (try? await ReviewGit.allFiles(in: repo.root)) ?? []
                        return (repo.prefix, paths.map { repo.prefix + $0 })
                    }
                }
                var lists: [String: [String]] = [:]
                for await (prefix, paths) in group { lists[prefix] = paths }
                return lists
            }
            await MainActor.run {
                guard let self, self.workspace == workspace else { return }
                self.repoFiles = lists
                self.rebuildFileTree()
            }
        }
    }

    /// The Files tab's tree, from the files already listed: one top folder
    /// per repository when there are several.
    private func rebuildFileTree() {
        let shown = repos.filter { focusedRepo == nil || $0.prefix == focusedRepo }
        let lists = shown.map { ($0, repoFiles[$0.prefix] ?? []) }
        let showExcluded = showExcluded
        treeGeneration += 1
        let generation = treeGeneration
        treeLoading = true
        Task { [weak self] in
            // Off the main thread: a workspace can have hundreds of
            // thousands of files.
            let (files, tree) = await Task.detached { () -> ([String], [ReviewTreeNode]) in
                var perRepo: [(ReviewRepo, [String])] = []
                var budget = 100_000
                for (repo, all) in lists {
                    var paths: [String] = []
                    for path in all where budget > 0 {
                        let inRepo = String(path.dropFirst(repo.prefix.count))
                        if showExcluded || !repo.isExcluded(inRepo) {
                            paths.append(inRepo)
                            budget -= 1
                        }
                    }
                    perRepo.append((repo, paths))
                }
                let files = perRepo.flatMap { repo, paths in paths.map { repo.prefix + $0 } }
                if perRepo.count == 1, let (repo, paths) = perRepo.first {
                    return (files, ReviewTreeNode.build(paths, prefix: repo.prefix))
                }
                let tree = perRepo.map { repo, paths in
                    ReviewTreeNode(
                        id: "repo:" + repo.prefix, name: repo.name,
                        children: ReviewTreeNode.build(paths, prefix: repo.prefix),
                        repo: repo.prefix)
                }
                return (files, tree)
            }.value
            await MainActor.run {
                guard let self, self.treeGeneration == generation else { return }
                self.allFiles = files
                self.tree = tree
                self.treeLoading = false
            }
        }
    }

    /// Status of changed files, for marking them in the tree.
    @Published private(set) var statusByPath: [String: ReviewFileDiff.Status] = [:]

    private func updateTreeStatus() {
        statusByPath = Dictionary(files.map { ($0.path, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// Files whose path contains the query, for the Files tab's filter.
    var filteredFiles: [String] {
        let query = fileQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Array(allFiles.lazy.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(500))
    }

    func reloadFiles() {
        tree = []
        loadTree()
    }

    /// How a path is written in a message to the agent: relative to the
    /// workspace when the agent works there, else in full.
    func messagePath(_ path: String) -> String {
        guard let root, terminalRoot != root else { return path }
        return url(for: path)?.path ?? path
    }

    // MARK: Undo

    func revert(_ hunk: ReviewHunk, of file: ReviewFileDiff) {
        guard let root = repo(file.repo)?.root else { return }
        Task { [weak self] in
            do {
                try await ReviewGit.revert(hunk, of: file, in: root)
            } catch {
                await MainActor.run { self?.showError("Couldn't revert that change", error) }
            }
            await MainActor.run { self?.refresh() }
        }
    }

    func revert(_ file: ReviewFileDiff) {
        guard let root = repo(file.repo)?.root else { return }
        let base = base(of: file)
        Task { [weak self] in
            do {
                try await ReviewGit.revert(file, to: base, in: root)
            } catch {
                await MainActor.run { self?.showError("Couldn't revert \(file.fileName)", error) }
            }
            await MainActor.run { self?.refresh() }
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Comments

    func startComment(on line: ReviewDiffLine, path: String) {
        guard let number = line.new ?? line.old else { return }
        composing = ReviewCommentTarget(path: path, line: number, removed: line.new == nil, code: line.text)
    }

    func startComment(onFileLine number: Int, text: String, path: String) {
        composing = ReviewCommentTarget(path: path, line: number, removed: false, code: text)
    }

    func saveComment(_ text: String) {
        guard let target = composing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        composing = nil
        guard !trimmed.isEmpty else { return }
        comments.append(ReviewComment(
            path: target.path, line: target.line, removed: target.removed, code: target.code, text: trimmed))
    }

    func comments(at path: String, line: Int, removed: Bool) -> [ReviewComment] {
        comments.filter { $0.path == path && $0.line == line && $0.removed == removed }
    }

    func delete(_ comment: ReviewComment) {
        comments.removeAll { $0.id == comment.id }
    }

    var canSend: Bool {
        !comments.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The message the agent gets: the overall note, then each comment with
    /// the line it's about.
    var message: String {
        var parts: [String] = []
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        if !comments.isEmpty {
            var lines = ["Review comments on your changes:"]
            let sorted = comments.sorted {
                $0.path == $1.path ? $0.line < $1.line : $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            for (i, comment) in sorted.enumerated() {
                lines.append("")
                let path = messagePath(comment.path)
                lines.append("\(i + 1). " + (comment.removed ? "\(path) (removed line \(comment.line))" : "\(path):\(comment.line)"))
                let code = comment.code.trimmingCharacters(in: .whitespaces)
                if !code.isEmpty { lines.append("   > \(code.prefix(200))") }
                for textLine in comment.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("   \(textLine)")
                }
            }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Type the review into the agent's prompt, without pressing Return, and
    /// switch to it so you can read it over and send it.
    func sendToAgent() {
        guard canSend, let controller else { return }
        let surface = controller.surfaceTree.first { $0.programStatus != nil } ?? controller.focusedSurface
        guard let surface, let model = surface.surfaceModel else { return }
        model.sendText(message)
        comments = []
        note = ""
        composing = nil
        ReviewCenter.shared.didSend(from: controller, to: surface)
    }
}

/// A folder or file in the Files tab.
struct ReviewTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [ReviewTreeNode]?
    /// For a repository's top folder in a workspace, its prefix.
    var repo: String?

    var isFolder: Bool { children != nil }

    /// Folders first, then files, each sorted the way Finder does.
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [String] = []
    }

    /// `paths` are relative to a repository; ids get its `prefix`.
    static func build<S: Sequence>(_ paths: S, prefix root: String = "") -> [ReviewTreeNode] where S.Element == String {
        let top = Folder()
        for path in paths {
            var folder = top
            let parts = path.split(separator: "/")
            for part in parts.dropLast() {
                let name = String(part)
                if let next = folder.folders[name] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[name] = next
                    folder = next
                }
            }
            if let last = parts.last { folder.files.append(String(last)) }
        }

        func nodes(_ folder: Folder, prefix: String) -> [ReviewTreeNode] {
            let folders = folder.folders.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    ReviewTreeNode(
                        id: prefix + name + "/",
                        name: name,
                        children: nodes(folder.folders[name]!, prefix: prefix + name + "/"))
                }
            let files = folder.files
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { ReviewTreeNode(id: prefix + $0, name: $0, children: nil) }
            return folders + files
        }
        return nodes(top, prefix: root)
    }
}

/// What the review knows about one repository besides its changes.
struct ReviewRepoState: Hashable {
    let branch: String?
    /// What its diff is against: HEAD or a snapshot.
    let base: String
}

struct ReviewRepoResult {
    let state: ReviewRepoState
    let files: [ReviewFileDiff]
    let error: String?
}

/// A file shown with Quick Look rather than as text. A new id each time, so
/// the view reloads it even when the path is the same but the file changed.
struct ReviewPreview: Equatable {
    let id = UUID()
    /// The old version, for a changed file. Nil for a new file.
    let before: URL?
    /// The file as it is now. Nil for a deleted file.
    let after: URL?
}

/// A folder or changed file in the Changes tab's tree.
struct ReviewChangeNode: Identifiable {
    /// A folder's path with a trailing slash, or a file's path.
    let id: String
    /// A folder's name, or several joined with "/" when each holds only the
    /// next, the way VS Code shows them.
    let name: String
    /// Nil for a folder.
    let file: ReviewFileDiff?
    let children: [ReviewChangeNode]
    /// Every changed file in the folder, however deep, or the file itself.
    let files: [ReviewFileDiff]
    /// For a repository's group in a workspace, its prefix.
    var repo: String?

    var isFolder: Bool { file == nil }
    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [ReviewFileDiff] = []
    }

    /// Folders first, then files, each sorted the way Finder does.
    /// Paths are split after `root`, a repository's prefix, which every
    /// file's path starts with.
    static func build(_ diffs: [ReviewFileDiff], prefix root: String = "") -> [ReviewChangeNode] {
        let top = Folder()
        for diff in diffs {
            var folder = top
            for part in diff.path.dropFirst(root.count).split(separator: "/").dropLast() {
                let name = String(part)
                if let next = folder.folders[name] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[name] = next
                    folder = next
                }
            }
            folder.files.append(diff)
        }

        func nodes(_ folder: Folder, prefix: String) -> [ReviewChangeNode] {
            let folders = folder.folders.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { key -> ReviewChangeNode in
                    var name = key
                    var path = prefix + key + "/"
                    var inner = folder.folders[key]!
                    while inner.files.isEmpty, inner.folders.count == 1, let only = inner.folders.first {
                        name += "/" + only.key
                        path += only.key + "/"
                        inner = only.value
                    }
                    let children = nodes(inner, prefix: path)
                    return ReviewChangeNode(
                        id: path, name: name, file: nil, children: children,
                        files: children.flatMap(\.files))
                }
            let files = folder.files
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                .map { ReviewChangeNode(id: $0.path, name: $0.fileName, file: $0, children: [], files: [$0]) }
            return folders + files
        }
        return nodes(top, prefix: root)
    }
}

/// One row of the Changes tree as shown, with how deep it sits.
struct ReviewChangeRow: Identifiable {
    let node: ReviewChangeNode
    let depth: Int
    var id: String { node.id }
}

/// The working tree as it was when each prompt to an agent started, per tab
/// and repository, so "This Session" and "Last Turn" have something to
/// compare against.
@MainActor
final class ReviewSnapshots {
    static let shared = ReviewSnapshots()

    private struct Key: Hashable {
        let controller: ObjectIdentifier
        let root: String
    }

    /// The first snapshot and the latest, per tab and repository.
    private var turns: [Key: [ReviewSnapshot]] = [:]

    func turns(for controller: ObjectIdentifier, root: String) -> [ReviewSnapshot]? {
        turns[Key(controller: controller, root: root)]
    }

    /// Called whenever a tab's agent status changes. A prompt starting is
    /// the move into "working".
    func statusChanged(_ controller: BaseTerminalController,
                       from old: Ghostty.Action.ProgramStatus.State?,
                       to new: Ghostty.Action.ProgramStatus.State?) {
        guard new == .working, old != .working,
              let pwd = controller.focusedSurface?.pwd ?? controller.surfaceTree.first?.pwd else { return }
        let id = ObjectIdentifier(controller)
        Task {
            // Every repository the review covers, so a workspace's "This
            // Session" includes changes in all of them.
            guard let workspace = await ReviewWorkspace.discover(from: pwd) else { return }
            for repo in workspace.repos {
                Task {
                    guard let snapshot = await ReviewGit.snapshot(in: repo.root) else { return }
                    await MainActor.run { self.add(snapshot, for: Key(controller: id, root: repo.root)) }
                }
            }
        }
    }

    private func add(_ snapshot: ReviewSnapshot, for key: Key) {
        var list = turns[key] ?? []
        // Keep the first and the latest; nothing reads the rest.
        if list.count >= 2 { list.removeLast() }
        list.append(snapshot)
        turns[key] = list
    }

    func forget(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        turns = turns.filter { $0.key.controller != id }
    }
}
