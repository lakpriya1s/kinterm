import Foundation

// Which git repositories one review covers. Usually just the terminal's own,
// but a folder can hold several: a VS Code `.code-workspace` file lists them,
// and repositories cloned inside another one are found the way VS Code's
// `git.autoRepositoryDetection` finds them. See
// scope/designs/08-code-review.md.

/// One git repository in a review.
struct ReviewRepo: Identifiable, Hashable {
    /// Where the repository sits relative to the workspace, ending in "/":
    /// "" for the workspace's own repository, "wheresnow-ui/" for one
    /// inside it. Every path in the review starts with its repository's.
    let prefix: String
    /// The repository's top folder.
    let root: String
    /// What to call it: the workspace's name for it, or its folder's.
    let name: String
    /// What `files.exclude` hides, relative to the repository.
    let excludes: [ReviewGlob]

    /// The patterns sorted by kind, so a path is split once however many
    /// there are.
    private let rootedNames: Set<Substring>
    private let rootedPaths: [String]
    private let anywhere: Set<Substring>
    private let others: [ReviewGlob]

    init(prefix: String, root: String, name: String, excludes: [ReviewGlob]) {
        self.prefix = prefix
        self.root = root
        self.name = name
        self.excludes = excludes
        var rootedNames = Set<Substring>(), rootedPaths: [String] = []
        var anywhere = Set<Substring>(), others: [ReviewGlob] = []
        for glob in excludes {
            if let path = glob.rootedPath {
                if path.contains("/") { rootedPaths.append(path) } else { rootedNames.insert(Substring(path)) }
            } else if let name = glob.anywhereName {
                anywhere.insert(Substring(name))
            } else {
                others.append(glob)
            }
        }
        self.rootedNames = rootedNames
        self.rootedPaths = rootedPaths
        self.anywhere = anywhere
        self.others = others
    }

    var id: String { prefix }

    func isExcluded(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if let first = parts.first, rootedNames.contains(first) { return true }
        if !anywhere.isEmpty, parts.contains(where: anywhere.contains) { return true }
        for rooted in rootedPaths
        where path == rooted || (path.hasPrefix(rooted) && path.dropFirst(rooted.count).first == "/") {
            return true
        }
        return others.contains { $0.matches(path) }
    }

    static func == (a: ReviewRepo, b: ReviewRepo) -> Bool {
        a.prefix == b.prefix && a.root == b.root && a.name == b.name && a.excludes == b.excludes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(prefix)
        hasher.combine(root)
    }
}

struct ReviewWorkspace: Hashable {
    /// The folder every path in the review is relative to.
    let root: String
    /// The `.code-workspace` file the repositories came from, if any.
    let file: String?
    let repos: [ReviewRepo]

    var name: String {
        if let file { return ((file as NSString).lastPathComponent as NSString).deletingPathExtension }
        return (root as NSString).lastPathComponent
    }

    /// The repositories for a terminal in `pwd`.
    static func discover(from pwd: String) async -> ReviewWorkspace? {
        guard let gitRoot = await ReviewGit.root(of: pwd) else { return nil }

        if let found = findWorkspaceFile(near: gitRoot) {
            let workspace = await fromWorkspaceFile(found.path, settings: found.json)
            // A workspace that doesn't include this terminal's repository
            // isn't the one it's working in.
            if let workspace, workspace.repos.contains(where: { $0.root == gitRoot }) { return workspace }
        }

        let settings = folderSettings(gitRoot)
        var repos = [ReviewRepo(prefix: "", root: gitRoot, name: (gitRoot as NSString).lastPathComponent,
                                excludes: excludes(workspace: [:], folder: settings))]
        if autoDetects(settings) {
            for nested in nestedRepos(in: gitRoot, settings: settings) {
                repos.append(ReviewRepo(
                    prefix: relative(nested, to: gitRoot) + "/", root: nested,
                    name: (nested as NSString).lastPathComponent,
                    excludes: excludes(workspace: [:], folder: folderSettings(nested))))
            }
        }
        return ReviewWorkspace(root: gitRoot, file: nil, repos: repos)
    }

    // MARK: .code-workspace files

    /// A `.code-workspace` file in the repository's folder, or in a folder
    /// above it, for a terminal in one of the workspace's own repositories.
    private static func findWorkspaceFile(near gitRoot: String) -> (path: String, json: [String: Any])? {
        var dir = gitRoot
        for _ in 0..<3 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            let files = names.filter { $0.hasSuffix(".code-workspace") }.sorted()
            for name in files {
                let path = (dir as NSString).appendingPathComponent(name)
                if let json = readJSONC(path) { return (path, json) }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    private static func fromWorkspaceFile(_ file: String, settings json: [String: Any]) async -> ReviewWorkspace? {
        let dir = (file as NSString).deletingLastPathComponent
        let settings = json["settings"] as? [String: Any] ?? [:]
        let folders = (json["folders"] as? [[String: Any]] ?? []).compactMap { folder -> (path: String, name: String?)? in
            guard let path = folder["path"] as? String ?? (folder["uri"] as? String).flatMap(fileURLPath) else {
                return nil
            }
            let absolute = path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
            return ((absolute as NSString).standardizingPath, folder["name"] as? String)
        }
        guard !folders.isEmpty else { return nil }

        // Each folder's repository, looked up all at once.
        let roots = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, folder) in folders.enumerated() {
                group.addTask { (i, await ReviewGit.root(of: folder.path)) }
            }
            var roots = [String?](repeating: nil, count: folders.count)
            for await (i, root) in group { roots[i] = root }
            return roots
        }

        let ignored = Set((settings["git.ignoredRepositories"] as? [String] ?? []).map {
            (($0.hasPrefix("/") ? $0 : (dir as NSString).appendingPathComponent($0)) as NSString).standardizingPath
        })
        var seen = Set<String>()
        var repos: [ReviewRepo] = []
        func add(_ root: String, name: String) {
            guard !ignored.contains(root), seen.insert(root).inserted else { return }
            let folder = folderSettings(root)
            repos.append(ReviewRepo(
                prefix: root == dir ? "" : relative(root, to: dir) + "/",
                root: root, name: name,
                excludes: excludes(workspace: settings, folder: folder)))
        }
        for (i, folder) in folders.enumerated() {
            guard let root = roots[i] else { continue }
            add(root, name: folder.name ?? (folder.path as NSString).lastPathComponent)
        }
        // Like VS Code, also pick up repositories inside the folders that the
        // workspace doesn't list.
        if autoDetects(settings) {
            for (i, folder) in folders.enumerated() where roots[i] != nil {
                for nested in nestedRepos(in: folder.path, settings: settings) {
                    add(nested, name: (nested as NSString).lastPathComponent)
                }
            }
        }
        guard !repos.isEmpty else { return nil }
        return ReviewWorkspace(root: dir, file: file, repos: repos)
    }

    private static func fileURLPath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: Settings

    /// A folder's own `.vscode/settings.json`.
    private static func folderSettings(_ folder: String) -> [String: Any] {
        readJSONC((folder as NSString).appendingPathComponent(".vscode/settings.json")) ?? [:]
    }

    /// `git.autoRepositoryDetection`: on unless set to false or "openEditors".
    private static func autoDetects(_ settings: [String: Any]) -> Bool {
        switch settings["git.autoRepositoryDetection"] {
        case let on as Bool: return on
        case let mode as String: return mode != "openEditors"
        default: return true
        }
    }

    /// VS Code's own `files.exclude` defaults.
    private static let defaultExcludes: [String: Any] = [
        "**/.git": true, "**/.svn": true, "**/.hg": true, "**/CVS": true,
        "**/.DS_Store": true, "**/Thumbs.db": true,
    ]

    /// `files.exclude` from VS Code's defaults, the workspace, then the
    /// folder, each overriding the last. Patterns set to `{ "when": … }` are
    /// left out: they hide a file only next to another one.
    private static func excludes(workspace: [String: Any], folder: [String: Any]) -> [ReviewGlob] {
        var merged = defaultExcludes
        for settings in [workspace, folder] {
            for (pattern, value) in settings["files.exclude"] as? [String: Any] ?? [:] {
                merged[pattern] = value
            }
        }
        return merged
            .filter { ($0.value as? Bool) == true }
            .keys.sorted()
            .compactMap(ReviewGlob.init)
    }

    /// Repositories inside `folder`, down to `git.repositoryScanMaxDepth`
    /// folders deep (VS Code's default is 1), skipping
    /// `git.repositoryScanIgnoredFolders`.
    private static func nestedRepos(in folder: String, settings: [String: Any]) -> [String] {
        let depth = min(max(settings["git.repositoryScanMaxDepth"] as? Int ?? 1, 0), 3)
        let skip = Set(settings["git.repositoryScanIgnoredFolders"] as? [String] ?? ["node_modules"])
        let fm = FileManager.default
        var found: [String] = []
        func scan(_ dir: String, level: Int) {
            guard level <= depth else { return }
            let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            for name in names where !name.hasPrefix(".") && !skip.contains(name) {
                let path = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                    found.append(path)
                } else {
                    scan(path, level: level + 1)
                }
            }
        }
        scan(folder, level: 1)
        return found
    }

    // MARK: Helpers

    /// `path` relative to `base`, with "../" when it's outside it.
    static func relative(_ path: String, to base: String) -> String {
        let from = (base as NSString).standardizingPath.split(separator: "/")
        let to = (path as NSString).standardizingPath.split(separator: "/")
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let up = Array(repeating: "..", count: from.count - common)
        return (up + to[common...].map(String.init)).joined(separator: "/")
    }

    /// Reads JSON with comments and trailing commas, as VS Code writes it.
    static func readJSONC(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let clean = stripJSONC(text)
        return (try? JSONSerialization.jsonObject(with: Data(clean.utf8))) as? [String: Any]
    }

    static func stripJSONC(_ text: String) -> String {
        var out = ""
        var chars = Array(text)[...]
        var inString = false
        while let c = chars.popFirst() {
            if inString {
                out.append(c)
                if c == "\\", let next = chars.popFirst() {
                    out.append(next)
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "/" where chars.first == "/":
                while let next = chars.first, next != "\n" { chars.removeFirst() }
            case "/" where chars.first == "*":
                chars.removeFirst()
                while let next = chars.popFirst() {
                    if next == "*", chars.first == "/" {
                        chars.removeFirst()
                        break
                    }
                }
            case "}", "]":
                // Drop a trailing comma before the bracket.
                if let comma = out.lastIndex(where: { !$0.isWhitespace }), out[comma] == "," {
                    out.remove(at: comma)
                }
                out.append(c)
            default:
                out.append(c)
            }
        }
        return out
    }
}

/// A VS Code glob such as `**/node_modules`, `*.log` or `{dist,build}`,
/// relative to a folder. A pattern that matches a folder matches everything
/// in it.
struct ReviewGlob: Hashable {
    let pattern: String
    /// Most patterns are plain names; those skip the regex, which matters
    /// with a few hundred thousand files.
    private enum Kind {
        /// `name` or `a/b`: that path from the top, and what's in it.
        case rooted(String)
        /// `**/name`: a file or folder with that name anywhere.
        case anywhere(String)
        case regex(NSRegularExpression)
    }
    private let kind: Kind

    /// For a plain pattern, the path it hides from the top.
    var rootedPath: String? { if case .rooted(let path) = kind { return path } else { return nil } }
    /// For `**/name`, the name it hides anywhere.
    var anywhereName: String? { if case .anywhere(let name) = kind { return name } else { return nil } }

    init?(_ pattern: String) {
        var glob = pattern
        while glob.hasPrefix("./") { glob.removeFirst(2) }
        while glob.hasPrefix("/") { glob.removeFirst() }
        while glob.hasSuffix("/") { glob.removeLast() }
        guard !glob.isEmpty else { return nil }

        let special = CharacterSet(charactersIn: "*?[]{}")
        if glob.rangeOfCharacter(from: special) == nil {
            self.pattern = pattern
            self.kind = .rooted(glob)
            return
        }
        if glob.hasPrefix("**/") {
            let name = String(glob.dropFirst(3))
            if !name.isEmpty, name.rangeOfCharacter(from: special) == nil, !name.contains("/") {
                self.pattern = pattern
                self.kind = .anywhere(name)
                return
            }
        }

        var out = "^"
        let chars = Array(glob)
        var i = 0
        var braces = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    let slashAfter = i + 2 < chars.count && chars[i + 2] == "/"
                    out += slashAfter ? "(?:.*/)?" : ".*"
                    i += slashAfter ? 3 : 2
                    continue
                }
                out += "[^/]*"
            case "?": out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0: out += "|"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var set = String(chars[(i + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close + 1
                    continue
                }
                out += "\\["
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        out += "$"
        guard let regex = try? NSRegularExpression(pattern: out) else { return nil }
        self.pattern = pattern
        self.kind = .regex(regex)
    }

    func matches(_ path: String) -> Bool {
        switch kind {
        case .rooted(let prefix):
            return path == prefix || (path.hasPrefix(prefix) && path.dropFirst(prefix.count).first == "/")
        case .anywhere(let name):
            return path.split(separator: "/").contains { $0 == name }
        case .regex(let regex):
            return matches(path, regex)
        }
    }

    private func matches(_ path: String, _ regex: NSRegularExpression) -> Bool {
        // The path itself, or any folder it's in.
        var candidate = Substring(path)
        while !candidate.isEmpty {
            let text = String(candidate)
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
            guard let slash = candidate.lastIndex(of: "/") else { break }
            candidate = candidate[..<slash]
        }
        return false
    }

    static func == (a: ReviewGlob, b: ReviewGlob) -> Bool { a.pattern == b.pattern }
    func hash(into hasher: inout Hasher) { hasher.combine(pattern) }
}
