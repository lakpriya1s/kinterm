import Foundation

// git output is decoded leniently: a stray non-UTF-8 byte in one file
// shouldn't blank out the whole diff.
// swiftlint:disable optional_data_string_conversion

// Everything the review view asks of git. Runs the real `git` binary off the
// main thread and parses its output; nothing here keeps state. See
// scope/designs/08-code-review.md.

/// One line of a unified diff.
struct ReviewDiffLine: Hashable {
    enum Kind: Hashable { case context, added, removed, noNewline }

    let kind: Kind
    let text: String
    /// Line number in the old file, for context and removed lines.
    let old: Int?
    /// Line number in the new file, for context and added lines.
    let new: Int?
}

/// One `@@ … @@` block of a diff.
struct ReviewHunk: Hashable, Identifiable {
    let id: Int
    /// The `@@ -a,b +c,d @@ section` line.
    let header: String
    let lines: [ReviewDiffLine]

    var added: Int { lines.lazy.filter { $0.kind == .added }.count }
    var removed: Int { lines.lazy.filter { $0.kind == .removed }.count }

    /// The hunk as git prints it, for `git apply`.
    var patchText: String {
        var out = header + "\n"
        for line in lines {
            switch line.kind {
            case .context: out += " " + line.text + "\n"
            case .added: out += "+" + line.text + "\n"
            case .removed: out += "-" + line.text + "\n"
            case .noNewline: out += "\\ No newline at end of file\n"
            }
        }
        return out
    }
}

/// One file in a diff.
struct ReviewFileDiff: Hashable, Identifiable {
    enum Status: String, Hashable { case modified = "M", added = "A", deleted = "D", renamed = "R" }

    var id: String { path }

    /// Path in the new tree, or the old one for a deleted file. Starts with
    /// its repository's prefix once the review has placed it in a workspace.
    private(set) var path: String
    /// Where a renamed file came from.
    private(set) var oldPath: String?
    /// The prefix of the repository the file is in; see `ReviewRepo`.
    private(set) var repo = ""
    let status: Status
    let binary: Bool
    let hunks: [ReviewHunk]
    /// Whether the file isn't tracked by git, so reverting it deletes it.
    var untracked = false

    var added: Int { hunks.reduce(0) { $0 + $1.added } }
    var removed: Int { hunks.reduce(0) { $0 + $1.removed } }
    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    /// Changes whenever the diff does, so "Viewed" resets when the agent
    /// touches the file again.
    var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(binary)
        for hunk in hunks { hasher.combine(hunk.patchText) }
        return hasher.finalize()
    }

    /// The path as git knows it, inside its own repository.
    var gitPath: String { String(path.dropFirst(repo.count)) }
    var gitOldPath: String? { oldPath.map { String($0.dropFirst(repo.count)) } }

    /// The same file, with paths relative to the workspace.
    func inRepo(_ prefix: String) -> ReviewFileDiff {
        var file = self
        file.repo = prefix
        file.path = prefix + path
        file.oldPath = oldPath.map { prefix + $0 }
        return file
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// What the agent's tree looked like at some point: a commit holding the
/// working tree (made with `git stash create`, which touches nothing), plus
/// the untracked files that existed then.
struct ReviewSnapshot: Hashable {
    let commit: String
    let untracked: Set<String>
    let date: Date
}

enum ReviewGitError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "git wasn't found. Install the Xcode Command Line Tools."
        case .failed(let message): return message
        }
    }
}

enum ReviewGit {
    /// The tree of an empty repository, for diffing before the first commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Diffs bigger than this are cut off rather than parsed.
    static let maxDiffBytes = 24 << 20

    private static let executable: String? = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: Running git

    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String

        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Run git in `dir` and collect what it prints. Never on the main thread.
    static func run(_ args: [String], in dir: String, input: String? = nil) async throws -> Output {
        guard let executable else { throw ReviewGitError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=false"] + args
                process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
                var env = ProcessInfo.processInfo.environment
                env["GIT_OPTIONAL_LOCKS"] = "0" // Don't fight the agent for index.lock.
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let inPipe = input.map { _ in Pipe() }
                process.standardInput = inPipe ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let inPipe, let input {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(Data(input.utf8))
                        try? inPipe.fileHandleForWriting.close()
                    }
                }

                // Read both pipes at once so a full one can't stall git.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: outData,
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    /// Run git and fail with its message if it does.
    @discardableResult
    static func check(_ args: [String], in dir: String, input: String? = nil) async throws -> Output {
        let output = try await run(args, in: dir, input: input)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReviewGitError.failed(message.isEmpty ? "git \(args.first ?? "") failed" : message)
        }
        return output
    }

    // MARK: Questions

    /// The top of the repository `path` is in, or nil if it isn't in one.
    static func root(of path: String) async -> String? {
        guard let output = try? await run(["rev-parse", "--show-toplevel"], in: path),
              output.status == 0 else { return nil }
        let root = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    static func branch(in root: String) async -> String? {
        guard let output = try? await run(["rev-parse", "--abbrev-ref", "HEAD"], in: root),
              output.status == 0 else { return nil }
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// HEAD, or the empty tree in a repository with no commits yet.
    static func head(in root: String) async -> String {
        if let output = try? await run(["rev-parse", "--verify", "-q", "HEAD"], in: root), output.status == 0 {
            let sha = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return emptyTree
    }

    /// Files git doesn't track and doesn't ignore.
    static func untracked(in root: String) async throws -> [String] {
        let output = try await check(["ls-files", "-z", "--others", "--exclude-standard"], in: root)
        // A repository inside this one is listed as its folder, ending in
        // "/". The review shows it as a repository of its own.
        return split0(output.stdout).filter { !$0.hasSuffix("/") }
    }

    /// Every file in the repository that isn't ignored, tracked or not.
    static func allFiles(in root: String) async throws -> [String] {
        let output = try await check(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        var seen = Set<String>()
        // Unmerged files are listed once per stage.
        return split0(output.stdout).filter { !$0.hasSuffix("/") && seen.insert($0).inserted }
    }

    /// Record the working tree as it is now, without touching it.
    static func snapshot(in root: String) async -> ReviewSnapshot? {
        let untracked = (try? await untracked(in: root)) ?? []
        var commit = ""
        if let output = try? await run(["stash", "create"], in: root), output.status == 0 {
            commit = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A clean tree has nothing to stash: HEAD is the snapshot.
        if commit.isEmpty { commit = await head(in: root) }
        return ReviewSnapshot(commit: commit, untracked: Set(untracked), date: Date())
    }

    /// The working tree's changes against `base`, untracked files included.
    /// With a snapshot, untracked files that were already there and haven't
    /// changed since are left out.
    static func changes(in root: String, against base: String, snapshot: ReviewSnapshot?) async throws -> [ReviewFileDiff] {
        let output = try await check(
            ["diff", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/", base, "--"],
            in: root)
        var files = parse(output.stdout.prefix(maxDiffBytes))

        // git diff only knows tracked files. Show new ones as additions.
        var untracked = try await untracked(in: root)
        if let snapshot {
            untracked = untracked.filter { path in
                guard snapshot.untracked.contains(path) else { return true }
                let url = URL(fileURLWithPath: root).appendingPathComponent(path)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (modified ?? .distantPast) > snapshot.date
            }
        }
        let tracked = Set(files.map(\.path))
        for path in untracked.prefix(300) where !tracked.contains(path) {
            if var file = await newFileDiff(path, in: root) {
                file.untracked = true
                files.append(file)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func newFileDiff(_ path: String, in root: String) async -> ReviewFileDiff? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 2 << 20 {
            return ReviewFileDiff(path: path, oldPath: nil, status: .added, binary: true, hunks: [])
        }
        // Built here rather than with `git diff --no-index`: a workspace can
        // have hundreds of new files, and a process each adds up.
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        if data.prefix(8000).contains(0) {
            return ReviewFileDiff(path: path, oldPath: nil, status: .added, binary: true, hunks: [])
        }
        guard !data.isEmpty else {
            return ReviewFileDiff(path: path, oldPath: nil, status: .added, binary: false, hunks: [])
        }
        var texts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let endsWithNewline = texts.last == ""
        if endsWithNewline { texts.removeLast() }
        var lines = texts.enumerated().map { i, text in
            ReviewDiffLine(kind: .added, text: text, old: nil, new: i + 1)
        }
        if !endsWithNewline {
            lines.append(ReviewDiffLine(kind: .noNewline, text: "No newline at end of file", old: nil, new: nil))
        }
        let header = "@@ -0,0 +1\(texts.count == 1 ? "" : ",\(texts.count)") @@"
        return ReviewFileDiff(path: path, oldPath: nil, status: .added, binary: false,
                              hunks: [ReviewHunk(id: 0, header: header, lines: lines)])
    }

    /// The file's text at `rev`, or in the working tree when nil.
    static func contents(of path: String, in root: String) -> FileContents {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        let limit = 4 << 20
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        if data.count > limit { return .tooLarge }
        if data.prefix(8192).contains(0) { return .binary }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// The file as it was at `rev`, written to a temporary file named like
    /// the original so Quick Look knows what it is. Nil if it wasn't there.
    static func export(_ path: String, at rev: String, in root: String, to dir: URL) async -> URL? {
        guard let output = try? await run(["show", "\(rev):\(path)"], in: root), output.status == 0 else { return nil }
        let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try output.stdout.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    enum FileContents {
        case text(String)
        case binary
        case tooLarge
        case unreadable
    }

    // MARK: Undoing changes

    /// Put one hunk back the way it was in the working tree.
    static func revert(_ hunk: ReviewHunk, of file: ReviewFileDiff, in root: String) async throws {
        let path = file.gitPath
        let old = file.gitOldPath ?? path
        let patch = "diff --git a/\(old) b/\(path)\n--- a/\(old)\n+++ b/\(path)\n" + hunk.patchText
        try await check(["apply", "-R", "--whitespace=nowarn", "--recount", "-"], in: root, input: patch)
    }

    /// Put a whole file back as it was in `base`. New files go to the Trash.
    static func revert(_ file: ReviewFileDiff, to base: String, in root: String) async throws {
        let rootURL = URL(fileURLWithPath: root)
        if file.status == .added || file.untracked {
            try FileManager.default.trashItem(at: rootURL.appendingPathComponent(file.gitPath), resultingItemURL: nil)
            return
        }
        if file.status == .renamed, let oldPath = file.gitOldPath {
            try await check(["restore", "--source=\(base)", "--worktree", "--", oldPath], in: root)
            try FileManager.default.trashItem(at: rootURL.appendingPathComponent(file.gitPath), resultingItemURL: nil)
            return
        }
        try await check(["restore", "--source=\(base)", "--worktree", "--", file.gitPath], in: root)
    }

    // MARK: Parsing

    private static func split0(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Parse `git diff` output into files.
    static func parse<D: DataProtocol>(_ data: D) -> [ReviewFileDiff] {
        let text = String(decoding: data, as: UTF8.self)
        var files: [ReviewFileDiff] = []

        var path: String?
        var oldPath: String?
        var renameFrom: String?
        var status = ReviewFileDiff.Status.modified
        var binary = false
        var hunks: [ReviewHunk] = []
        var header: String?
        var lines: [ReviewDiffLine] = []
        var oldLine = 0, newLine = 0

        func endHunk() {
            if let header { hunks.append(ReviewHunk(id: hunks.count, header: header, lines: lines)) }
            header = nil
            lines = []
        }
        func endFile() {
            endHunk()
            if let name = path ?? oldPath {
                files.append(ReviewFileDiff(
                    path: name,
                    oldPath: status == .renamed ? renameFrom : nil,
                    status: status,
                    binary: binary,
                    hunks: hunks))
            }
            path = nil; oldPath = nil; renameFrom = nil
            status = .modified; binary = false; hunks = []
        }

        text.enumerateLines { raw, _ in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("diff --git ") {
                endFile()
                // Best guess until ---/+++ say otherwise; those are missing
                // for renames without changes and for binary files.
                if let range = line.range(of: " b/", options: .backwards) {
                    path = String(line[range.upperBound...])
                }
                return
            }
            if header != nil {
                switch line.first {
                case " ":
                    oldLine += 1; newLine += 1
                    lines.append(.init(kind: .context, text: String(line.dropFirst()), old: oldLine, new: newLine))
                    return
                case "+":
                    newLine += 1
                    lines.append(.init(kind: .added, text: String(line.dropFirst()), old: nil, new: newLine))
                    return
                case "-":
                    oldLine += 1
                    lines.append(.init(kind: .removed, text: String(line.dropFirst()), old: oldLine, new: nil))
                    return
                case "\\":
                    lines.append(.init(kind: .noNewline, text: "No newline at end of file", old: nil, new: nil))
                    return
                case nil:
                    // Some tools trim the space off empty context lines.
                    oldLine += 1; newLine += 1
                    lines.append(.init(kind: .context, text: "", old: oldLine, new: newLine))
                    return
                default:
                    break
                }
            }
            if line.hasPrefix("@@") {
                endHunk()
                header = line
                let (old, new) = hunkStarts(line)
                oldLine = old - 1
                newLine = new - 1
            } else if line.hasPrefix("--- ") {
                let name = String(line.dropFirst(4))
                if name != "/dev/null" { oldPath = stripPrefix(name) }
            } else if line.hasPrefix("+++ ") {
                let name = String(line.dropFirst(4))
                if name == "/dev/null" {
                    status = .deleted
                    path = oldPath
                } else {
                    path = stripPrefix(name)
                }
            } else if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if line.hasPrefix("rename from ") {
                status = .renamed
                renameFrom = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") {
                binary = true
            }
        }
        endFile()
        return files
    }

    private static func stripPrefix(_ name: String) -> String {
        var name = name
        if let tab = name.firstIndex(of: "\t") { name = String(name[..<tab]) }
        if name.hasPrefix("a/") || name.hasPrefix("b/") { return String(name.dropFirst(2)) }
        return name
    }

    /// The starting line numbers in `@@ -12,4 +12,6 @@`.
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 1 }
            let number = part.dropFirst().split(separator: ",").first ?? "1"
            return Int(number) ?? 1
        }
        return (start("-"), start("+"))
    }
}

// swiftlint:enable optional_data_string_conversion
