import SwiftUI

// A small, fast syntax colorer for the review view: comments, strings,
// numbers and keywords. It scans each line once with no regular expressions,
// and carries block comments and multi-line strings from line to line. Good
// enough to read a diff by; not a parser.

struct ReviewSyntax {
    var lineComments: [String]
    var blockComment: (open: String, close: String)?
    var keywords: Set<String>
    /// Opening and closing delimiters of strings that can span lines.
    var multilineStrings: [String] = []
    var stringQuotes: Set<Character> = ["\"", "'"]

    static func forPath(_ path: String) -> ReviewSyntax? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: swift, multilineStrings: ["\"\"\""], stringQuotes: ["\""])
        case "zig":
            return .init(lineComments: ["//"], blockComment: nil, keywords: zig, stringQuotes: ["\"", "'"])
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "metal", "glsl", "frag", "vert":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: c)
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            var syntax = ReviewSyntax(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: js)
            syntax.stringQuotes.insert("`")
            return syntax
        case "go":
            var syntax = ReviewSyntax(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: go)
            syntax.stringQuotes.insert("`")
            return syntax
        case "rs":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: rust, stringQuotes: ["\""])
        case "java", "kt", "kts", "cs", "scala", "dart":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: java, multilineStrings: ["\"\"\""])
        case "py":
            return .init(lineComments: ["#"], blockComment: nil, keywords: python, multilineStrings: ["\"\"\"", "'''"])
        case "rb":
            return .init(lineComments: ["#"], blockComment: nil, keywords: ruby)
        case "sh", "bash", "zsh", "fish", "nu":
            return .init(lineComments: ["#"], blockComment: nil, keywords: shell)
        case "toml", "yaml", "yml", "conf", "ini", "cfg", "nix", "dockerfile", "cmake", "mk", "pbxproj":
            return .init(lineComments: ["#"], blockComment: nil, keywords: ["true", "false", "null"])
        case "json", "jsonc":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: ["true", "false", "null"], stringQuotes: ["\""])
        case "lua":
            return .init(lineComments: ["--"], blockComment: ("--[[", "]]"), keywords: lua)
        case "sql":
            return .init(lineComments: ["--"], blockComment: ("/*", "*/"), keywords: sql)
        case "css", "scss", "less":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: [])
        case "html", "xml", "xib", "storyboard", "plist", "svg", "vue", "svelte":
            return .init(lineComments: [], blockComment: ("<!--", "-->"), keywords: [])
        default:
            switch name {
            case "makefile", "dockerfile", "gemfile", "rakefile", ".gitignore", ".gitattributes", "config":
                return .init(lineComments: ["#"], blockComment: nil, keywords: shell)
            default:
                return nil
            }
        }
    }

    // MARK: Keywords

    private static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let",
        "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public",
        "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "@MainActor",
    ]
    private static let zig: Set<String> = [
        "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
        "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error",
        "export", "extern", "false", "fn", "for", "if", "inline", "noalias", "noinline", "null", "opaque", "or",
        "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal",
        "true", "try", "undefined", "union", "unreachable", "usingnamespace", "var", "volatile", "while",
    ]
    private static let c: Set<String> = [
        "auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "define",
        "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "goto", "if", "include",
        "inline", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "register",
        "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "true",
        "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "NULL",
        "@interface", "@implementation", "@end", "@property", "self", "nil", "YES", "NO",
    ]
    private static let js: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if",
        "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private",
        "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try",
        "type", "typeof", "undefined", "var", "void", "while", "yield",
    ]
    private static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
        "struct", "switch", "true", "type", "var",
    ]
    private static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    private static let java: Set<String> = [
        "abstract", "break", "case", "catch", "class", "const", "continue", "data", "default", "do", "else",
        "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "in",
        "interface", "is", "new", "null", "object", "override", "package", "private", "protected", "public",
        "return", "static", "super", "switch", "this", "throw", "throws", "true", "try", "val", "var", "void",
        "when", "while",
    ]
    private static let python: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
        "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield",
    ]
    private static let ruby: Set<String> = [
        "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if",
        "in", "module", "next", "nil", "not", "or", "and", "redo", "rescue", "return", "self", "super", "then",
        "true", "unless", "until", "when", "while", "yield",
    ]
    private static let shell: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local",
        "readonly", "return", "set", "then", "unset", "until", "while",
    ]
    private static let lua: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil",
        "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]
    private static let sql: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
        "INDEX", "DROP", "ALTER", "ADD", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT",
        "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "PRIMARY", "KEY", "REFERENCES", "DEFAULT",
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "join", "on", "and", "or", "not", "null", "as", "order", "by", "group", "limit",
    ]
}

/// Colors lines one after another, remembering open block comments and
/// strings between them.
struct ReviewHighlighter {
    enum Carry: Equatable {
        case none
        case comment(close: String)
        case string(close: String)
    }

    let syntax: ReviewSyntax?
    private(set) var carry: Carry = .none

    init(path: String) {
        syntax = ReviewSyntax.forPath(path)
    }

    /// Lines longer than this are shown plain: coloring them buys little
    /// and minified files can be megabytes on one line.
    private static let maxLength = 2000

    mutating func highlight(_ line: String) -> AttributedString {
        var out = AttributedString(line)
        out.foregroundColor = ReviewColors.text
        guard let syntax, !line.isEmpty, line.utf8.count <= Self.maxLength else {
            if line.utf8.count > Self.maxLength { carry = .none }
            return out
        }

        let chars = Array(line.unicodeScalars)
        var spans: [(Range<Int>, Color)] = []
        var i = 0

        func matches(_ token: String, at index: Int) -> Bool {
            let scalars = Array(token.unicodeScalars)
            guard index + scalars.count <= chars.count else { return false }
            for k in 0..<scalars.count where chars[index + k] != scalars[k] { return false }
            return true
        }
        func find(_ token: String, from index: Int) -> Int? {
            var j = index
            while j < chars.count {
                if matches(token, at: j) { return j }
                j += 1
            }
            return nil
        }

        // Finish what the last line left open.
        switch carry {
        case .comment(let close):
            if let end = find(close, from: 0) {
                i = end + close.unicodeScalars.count
                spans.append((0..<i, ReviewColors.comment))
                carry = .none
            } else {
                spans.append((0..<chars.count, ReviewColors.comment))
                return apply(spans, to: out, chars: chars)
            }
        case .string(let close):
            if let end = find(close, from: 0) {
                i = end + close.unicodeScalars.count
                spans.append((0..<i, ReviewColors.string))
                carry = .none
            } else {
                spans.append((0..<chars.count, ReviewColors.string))
                return apply(spans, to: out, chars: chars)
            }
        case .none:
            break
        }

        scan: while i < chars.count {
            let c = chars[i]

            for prefix in syntax.lineComments where matches(prefix, at: i) {
                spans.append((i..<chars.count, ReviewColors.comment))
                break scan
            }
            if let block = syntax.blockComment, matches(block.open, at: i) {
                let start = i
                if let end = find(block.close, from: i + block.open.unicodeScalars.count) {
                    i = end + block.close.unicodeScalars.count
                    spans.append((start..<i, ReviewColors.comment))
                    continue
                }
                spans.append((start..<chars.count, ReviewColors.comment))
                carry = .comment(close: block.close)
                break scan
            }
            if let delimiter = syntax.multilineStrings.first(where: { matches($0, at: i) }) {
                let start = i
                if let end = find(delimiter, from: i + delimiter.unicodeScalars.count) {
                    i = end + delimiter.unicodeScalars.count
                    spans.append((start..<i, ReviewColors.string))
                    continue
                }
                spans.append((start..<chars.count, ReviewColors.string))
                carry = .string(close: delimiter)
                break scan
            }
            if syntax.stringQuotes.contains(Character(c)) {
                let start = i
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i = min(i + 1, chars.count)
                spans.append((start..<i, ReviewColors.string))
                continue
            }
            if CharacterSet.decimalDigits.contains(c),
               i == 0 || !Self.isWord(chars[i - 1]) {
                let start = i
                while i < chars.count, Self.isWord(chars[i]) || chars[i] == "." { i += 1 }
                spans.append((start..<i, ReviewColors.number))
                continue
            }
            if Self.isWordStart(c) {
                let start = i
                while i < chars.count, Self.isWord(chars[i]) { i += 1 }
                var word = String(String.UnicodeScalarView(chars[start..<i]))
                // Swift and Objective-C attributes keep their "@".
                if start > 0, chars[start - 1] == "@" { word = "@" + word }
                if syntax.keywords.contains(word) {
                    spans.append((start..<i, ReviewColors.keyword))
                } else if i < chars.count, chars[i] == "(" {
                    spans.append((start..<i, ReviewColors.function))
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                    spans.append((start..<i, ReviewColors.type))
                }
                continue
            }
            i += 1
        }

        return apply(spans, to: out, chars: chars)
    }

    private func apply(_ spans: [(Range<Int>, Color)], to string: AttributedString, chars: [Unicode.Scalar]) -> AttributedString {
        guard !spans.isEmpty else { return string }
        var out = string
        let scalars = out.unicodeScalars
        for (range, color) in spans where !range.isEmpty {
            let lower = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
            let upper = scalars.index(scalars.startIndex, offsetBy: min(range.upperBound, chars.count))
            out[lower..<upper].foregroundColor = color
        }
        return out
    }

    private static func isWordStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || CharacterSet.letters.contains(c)
    }

    private static func isWord(_ c: Unicode.Scalar) -> Bool {
        c == "_" || CharacterSet.alphanumerics.contains(c)
    }
}
