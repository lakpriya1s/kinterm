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

    enum Viewer: Equatable {
        case none
        case diff(String)
        case file(String)
    }

    weak private(set) var controller: BaseTerminalController?

    @Published var tab: Tab = .changes
    @Published var scope: Scope = .uncommitted { didSet { if scope != oldValue { refresh() } } }

    @Published private(set) var root: String?
    @Published private(set) var branch: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    @Published private(set) var files: [ReviewFileDiff] = []
    @Published var viewer: Viewer = .none { didSet { if viewer != oldValue { loadViewer() } } }
    @Published private(set) var rows: [ReviewRow] = []
    @Published private(set) var viewerNote: String?

    /// Viewed files, by path, with the diff they were viewed at.
    @Published private var viewed: [String: Int] = [:]

    @Published var comments: [ReviewComment] = []
    @Published var composing: ReviewCommentTarget?
    @Published var note = ""

    @Published private(set) var tree: [ReviewTreeNode] = []
    @Published private(set) var allFiles: [String] = []
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

    var repoName: String { root.map { ($0 as NSString).lastPathComponent } ?? "No repository" }

    var tabTitle: String {
        guard let window = controller?.window else { return "Terminal" }
        return window.title.isEmpty ? "Terminal" : window.title
    }

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
            if case .diff(let path) = viewer, path == file.path,
               let next = files.first(where: { !isViewed($0) }) {
                viewer = .diff(next.path)
            }
        }
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
            guard let pwd, let root = await ReviewGit.root(of: pwd) else {
                await MainActor.run {
                    self?.root = nil
                    self?.files = []
                    self?.tree = []
                    self?.loading = false
                    self?.error = pwd == nil
                        ? "This tab hasn't reported its folder yet."
                        : "\(pwd ?? "") isn't in a git repository."
                }
                return
            }

            let branch = await ReviewGit.branch(in: root)
            var base = await ReviewGit.head(in: root)
            var snapshot: ReviewSnapshot?
            var scopeNote: String?
            if scope != .uncommitted {
                let turns = controllerID.flatMap { ReviewSnapshots.shared.turns(for: $0, root: root) }
                snapshot = scope == .session ? turns?.first : turns?.last
                if let snapshot {
                    base = snapshot.commit
                } else {
                    scopeNote = "No agent prompt seen in this tab yet, so this shows everything uncommitted."
                }
            }

            do {
                let files = try await ReviewGit.changes(in: root, against: base, snapshot: snapshot)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let rootChanged = self.root != root
                    self.root = root
                    self.base = base
                    self.branch = branch
                    self.files = files
                    self.error = scopeNote
                    self.loading = false
                    if rootChanged || self.tree.isEmpty { self.loadTree() }
                    self.updateTreeStatus()
                    self.reselect()
                }
            } catch {
                await MainActor.run {
                    self?.root = root
                    self?.files = []
                    self?.loading = false
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    /// What the diff is against: HEAD or a snapshot.
    private(set) var base = ReviewGit.emptyTree

    /// Keep the open file if it's still changed, else open the first one.
    private func reselect() {
        switch viewer {
        case .diff(let path):
            if file(at: path) != nil {
                loadViewer()
            } else {
                viewer = files.first.map { .diff($0.path) } ?? .none
            }
        case .file:
            loadViewer()
        case .none:
            if tab == .changes, let first = files.first { viewer = .diff(first.path) }
        }
    }

    private func loadViewer() {
        viewerTask?.cancel()
        composing = nil
        switch viewer {
        case .none:
            rows = []
            viewerNote = nil

        case .diff(let path):
            guard let file = file(at: path) else { rows = []; return }
            if file.binary {
                rows = []
                viewerNote = "Binary file, not shown."
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
            guard let root else { rows = []; return }
            viewerNote = nil
            viewerTask = Task.detached(priority: .userInitiated) { [weak self] in
                let contents = ReviewGit.contents(of: path, in: root)
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
                case .binary: note = "Binary file, not shown."
                case .tooLarge: note = "This file is over 4 MB, so it isn't shown."
                case .unreadable: note = "This file can't be read."
                }
                guard !Task.isCancelled else { return }
                let done = rows
                await self?.show(done, note: note)
            }
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
        guard let root else { return }
        Task { [weak self] in
            let paths = (try? await ReviewGit.allFiles(in: root)) ?? []
            let tree = await Task.detached { ReviewTreeNode.build(paths.prefix(100_000)) }.value
            await MainActor.run {
                self?.allFiles = paths
                self?.tree = tree
                self?.updateTreeStatus()
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

    // MARK: Undo

    func revert(_ hunk: ReviewHunk, of file: ReviewFileDiff) {
        guard let root else { return }
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
        guard let root else { return }
        let base = base
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
                lines.append("\(i + 1). \(comment.location)")
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

    var isFolder: Bool { children != nil }

    /// Folders first, then files, each sorted the way Finder does.
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [String] = []
    }

    static func build<S: Sequence>(_ paths: S) -> [ReviewTreeNode] where S.Element == String {
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
        return nodes(top, prefix: "")
    }
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
            guard let root = await ReviewGit.root(of: pwd),
                  let snapshot = await ReviewGit.snapshot(in: root) else { return }
            await MainActor.run {
                let key = Key(controller: id, root: root)
                var list = self.turns[key] ?? []
                // Keep the first and the latest; nothing reads the rest.
                if list.count >= 2 { list.removeLast() }
                list.append(snapshot)
                self.turns[key] = list
            }
        }
    }

    func forget(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        turns = turns.filter { $0.key.controller != id }
    }
}
