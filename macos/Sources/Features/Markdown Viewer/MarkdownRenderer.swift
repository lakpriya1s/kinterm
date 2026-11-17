import AppKit
import SwiftUI

// Markdown to HTML for the Markdown Viewer. GitHub-flavored
// where it counts for the files agents write: headings, lists and task
// lists, tables, fenced code, quotes, links, images, emphasis and raw HTML.
// Not a CommonMark implementation; it reads the Markdown people write, not
// every edge case the spec covers.

enum MarkdownRenderer {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// A whole page: `text` rendered, styled like the review panel. Local
    /// images are resolved against `file` and embedded.
    static func page(_ text: String, file: URL) -> String {
        page(text, file: file, changes: nil).html
    }

    /// A whole page with the blocks `changes` touches marked
    /// (`kt-change-0`, `kt-change-1`... in order), and how many there are.
    static func page(_ text: String, file: URL, changes: MarkdownLineChanges?) -> (html: String, changes: Int) {
        var renderer = Renderer(directory: file.deletingLastPathComponent())
        renderer.changes = changes
        let body = renderer.document(text)
        return (wrap(body), renderer.marks)
    }

    private static func wrap(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style></head>
        <body><article>\(body)</article></body></html>
        """
    }

    /// The Markdown itself, with line numbers.
    static func sourcePage(_ text: String) -> String {
        sourcePage(text, changes: nil).html
    }

    /// The Markdown with changed lines marked, each run of them (and each
    /// place text was removed) one change, numbered as in `page`.
    static func sourcePage(_ text: String, changes: MarkdownLineChanges?) -> (html: String, changes: Int) {
        var rows = ""
        var n = 0
        var marks = 0
        var inRun = false
        text.enumerateLines { line, _ in
            var attrs = ""
            if let changes {
                if changes.changed.contains(n) {
                    attrs = " class=\"kt-line\""
                    if !inRun { attrs += " id=\"kt-change-\(marks)\""; marks += 1 }
                    inRun = true
                } else {
                    inRun = false
                    if changes.removed.contains(n) {
                        attrs = " class=\"kt-line-after-removed\" id=\"kt-change-\(marks)\""
                        marks += 1
                    }
                }
            }
            n += 1
            rows += "<tr\(attrs)><td class=\"ln\">\(n)</td><td>\(escape(line))</td></tr>\n"
        }
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>\(css)
        table.source { display: table; border: 0; margin: 0; width: 100%; font: 12px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
        table.source td { border: 0; padding: 0 12px 0 0; white-space: pre-wrap; vertical-align: top; background: none !important; }
        table.source td.ln { width: 1%; text-align: right; color: \(hex(ReviewColors.secondary)); user-select: none; -webkit-user-select: none; }
        </style></head>
        <body><article style="max-width: none"><table class="source">\(rows)</table></article></body></html>
        """
        return (html, marks)
    }

    /// GitHub's heading anchors: lowercased, punctuation dropped, spaces
    /// to dashes.
    static func slug(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch == " " {
                out.append("-")
            }
        }
        return out
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let hex: (Color) -> String = { color in
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }

    static var css: String {
        """
        :root { color-scheme: dark; }
        html, body { margin: 0; background: \(hex(ReviewColors.background)); }
        body {
          color: \(hex(ReviewColors.text));
          font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        article { max-width: 860px; margin: 0 auto; padding: 20px 28px 48px; overflow-wrap: break-word; }
        a { color: \(hex(ReviewColors.accent)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 0.6em; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        h4 { font-size: 1em; } h5 { font-size: 0.875em; } h6 { font-size: 0.85em; color: \(hex(ReviewColors.secondary)); }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid \(hex(ReviewColors.border)); }
        article > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, table, pre, details { margin: 0 0 1em; }
        ul, ol { padding-left: 2em; }
        li + li, li > ul, li > ol { margin-top: 0.25em; }
        li > ul, li > ol { margin-bottom: 0; }
        li > p { margin: 0.5em 0; }
        li.task { list-style: none; }
        li.task input { margin: 0 0.4em 0 -1.4em; vertical-align: middle; }
        blockquote { padding: 0 1em; color: \(hex(ReviewColors.secondary)); border-left: 0.25em solid \(hex(ReviewColors.border)); }
        blockquote > :last-child { margin-bottom: 0; }
        hr { height: 0.25em; margin: 1.5em 0; border: 0; background: \(hex(ReviewColors.border)); }
        code, pre { font: 12px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
        code { padding: 0.2em 0.4em; border-radius: 6px; background: \(hex(ReviewColors.card)); }
        pre { padding: 12px 16px; overflow: auto; border-radius: 6px; background: \(hex(ReviewColors.surface));
              border: 1px solid \(hex(ReviewColors.border)); }
        pre code { padding: 0; background: none; border-radius: 0; }
        pre.front-matter { color: \(hex(ReviewColors.secondary)); }
        table { border-collapse: collapse; display: block; max-width: 100%; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid \(hex(ReviewColors.border)); }
        th { font-weight: 600; background: \(hex(ReviewColors.surface)); }
        tr:nth-child(2n) td { background: \(hex(ReviewColors.card)); }
        img { max-width: 100%; }
        del { color: \(hex(ReviewColors.secondary)); }
        kbd { padding: 0.15em 0.4em; font: 11px ui-monospace, Menlo, monospace; border-radius: 4px;
              border: 1px solid \(hex(ReviewColors.border)); background: \(hex(ReviewColors.card)); }
        mark { background: rgba(210, 153, 34, 0.4); color: inherit; }
        .kt-change { position: relative; background: rgba(46, 160, 67, 0.12); border-radius: 4px;
                     box-shadow: 0 0 0 6px rgba(46, 160, 67, 0.12); }
        .kt-change::before { content: ""; position: absolute; left: -14px; top: -6px; bottom: -6px; width: 3px;
                             border-radius: 2px; background: \(hex(ReviewColors.addedText)); }
        li.kt-change::before { left: -2.4em; }
        div.kt-change { margin: 0 0 calc(1em + 6px); }
        div.kt-change > :last-child { margin-bottom: 0; }
        .kt-removed { position: relative; height: 0; margin: 0 0 1em;
                      border-top: 2px dashed \(hex(ReviewColors.removedText)); opacity: 0.8; }
        .kt-removed::after { content: "removed"; position: absolute; right: 0; top: -9px; padding: 0 6px;
                             font-size: 10px; color: \(hex(ReviewColors.removedText));
                             background: \(hex(ReviewColors.background)); }
        tr.kt-line td { background: rgba(46, 160, 67, 0.16) !important; }
        tr.kt-line td.ln { color: \(hex(ReviewColors.addedText)); }
        tr.kt-line-after-removed td { box-shadow: inset 0 2px 0 \(hex(ReviewColors.removedText)); }
        """
    }
}

// MARK: Blocks

private struct Renderer {
    let directory: URL
    /// `[label]: url "title"` definitions, by lowercased label.
    private var references: [String: (url: String, title: String?)] = [:]
    /// Heading anchors used so far, to number repeats like GitHub.
    private var slugs: [String: Int] = [:]
    /// Lines changed since a version to compare with, to mark.
    var changes: MarkdownLineChanges?
    /// How many changes were marked so far.
    private(set) var marks = 0
    /// The block just rendered was a list that marked its own items.
    private var listMarked = false

    init(directory: URL) {
        self.directory = directory
    }

    mutating func document(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        var html = ""
        // YAML front matter, shown quietly rather than as a rule and a
        // heading.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               let t = $0.trimmingCharacters(in: .whitespaces)
               return t == "---" || t == "..."
           }) {
            let front = lines[1..<end].joined(separator: "\n")
            html += "<pre class=\"front-matter\"><code>\(MarkdownRenderer.escape(front))</code></pre>\n"
            // Blanked rather than removed, so lines keep their numbers.
            for k in 0...end { lines[k] = "" }
        }
        lines = collectReferences(lines)
        return html + blocks(lines[...], tight: false, top: true)
    }

    /// Takes reference definitions out of the text, outside code fences.
    private mutating func collectReferences(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var fence: String?
        for line in lines {
            if let open = fence {
                kept.append(line)
                if Self.closesFence(line, open) { fence = nil }
                continue
            }
            if let open = Self.fenceOpen(line) {
                fence = open.marker
                kept.append(line)
                continue
            }
            if let def = Self.reference(line) {
                let key = def.label.lowercased()
                if references[key] == nil { references[key] = (def.url, def.title) }
                kept.append("")
                continue
            }
            kept.append(line)
        }
        return kept
    }

    private static func reference(_ line: String) -> (label: String, url: String, title: String?)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard indent(line) < 4, t.hasPrefix("["), !t.hasPrefix("[^"),
              let close = t.range(of: "]:") else { return nil }
        let label = String(t[t.index(after: t.startIndex)..<close.lowerBound])
        guard !label.isEmpty, !label.contains("]") else { return nil }
        let rest = t[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var url = rest
        var title: String?
        if let space = rest.firstIndex(of: " ") {
            url = String(rest[..<space])
            let tail = rest[space...].trimmingCharacters(in: .whitespaces)
            if tail.count >= 2, let first = tail.first, let last = tail.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "(" && last == ")") {
                title = String(tail.dropFirst().dropLast())
            } else {
                return nil
            }
        }
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return (label, url, title)
    }

    // MARK: Block structure

    private mutating func blocks(_ lines: ArraySlice<String>, tight: Bool, top: Bool = false) -> String {
        var html = ""
        var i = lines.startIndex
        let end = lines.endIndex
        // Where the last block ended, for text removed between blocks.
        var previousEnd = i
        while i < end {
            let start = i
            let out = block(lines, at: &i, tight: tight, top: top)
            guard top, changes != nil, !out.isEmpty else {
                html += out
                continue
            }
            html += marked(out, lines: start..<i, after: previousEnd)
            previousEnd = i
        }
        if top, let changes, changes.removed.contains(where: { $0 >= previousEnd }) {
            html += removedMarker()
        }
        return html
    }

    /// One block starting at `i`, moving `i` past it. Blank lines give "".
    private mutating func block(_ lines: ArraySlice<String>, at i: inout Int, tight: Bool, top: Bool) -> String {
        let end = lines.endIndex
        let line = lines[i]
        var html = ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            i += 1
            return html
        }

        // Fenced code.
        if let open = Self.fenceOpen(line) {
            var body: [String] = []
            i += 1
            while i < end, !Self.closesFence(lines[i], open.marker) {
                body.append(Self.dropIndent(lines[i], open.indent))
                i += 1
            }
            if i < end { i += 1 }
            html += code(body, language: open.info)
            return html
        }

        // Indented code.
        if Self.indent(line) >= 4 {
            var body: [String] = []
            while i < end, Self.indent(lines[i]) >= 4 || Self.isBlank(lines[i]) {
                body.append(Self.dropIndent(lines[i], 4))
                i += 1
            }
            while body.last.map(Self.isBlank) == true { body.removeLast() }
            html += code(body, language: "")
            return html
        }

        if let heading = Self.atxHeading(line) {
            html += self.heading(heading.level, heading.text)
            i += 1
            return html
        }

        if Self.isRule(line) {
            html += "<hr>\n"
            i += 1
            return html
        }

        if Self.isQuote(line) {
            var inner: [String] = []
            while i < end {
                let l = lines[i]
                if Self.isQuote(l) {
                    inner.append(Self.stripQuote(l))
                } else if !Self.isBlank(l), let last = inner.last, !Self.isBlank(last),
                          !Self.startsBlock(l) {
                    // A lazy continuation of the quoted paragraph.
                    inner.append(l)
                } else {
                    break
                }
                i += 1
            }
            html += "<blockquote>\n\(blocks(inner[...], tight: false))</blockquote>\n"
            return html
        }

        if let marker = Self.listMarker(line) {
            i = list(lines, from: i, first: marker, into: &html, top: top)
            return html
        }

        if i + 1 < end, line.contains("|"), let aligns = Self.tableDelimiter(lines[i + 1]) {
            let header = Self.cells(line)
            if header.count == aligns.count {
                i = table(lines, from: i, header: header, aligns: aligns, into: &html)
                return html
            }
        }

        if Self.isHTMLBlock(line) {
            var raw: [String] = []
            while i < end, !Self.isBlank(lines[i]) {
                raw.append(lines[i])
                i += 1
            }
            html += embedSources(raw.joined(separator: "\n")) + "\n"
            return html
        }

        // A paragraph, or a setext heading.
        var para: [String] = [trimmed]
        i += 1
        var setext = 0
        while i < end {
            let l = lines[i]
            if Self.isBlank(l) { break }
            let t = l.trimmingCharacters(in: .whitespaces)
            if Self.indent(l) < 4, !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
            if Self.indent(l) < 4, !t.isEmpty, t.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
            if Self.startsBlock(l) { break }
            para.append(Self.indent(l) >= 4 ? t : String(l.drop(while: { $0 == " " })))
            i += 1
        }
        let text = para.joined(separator: "\n")
        if setext > 0 {
            html += heading(setext, text)
        } else if tight {
            html += inline(text) + "\n"
        } else {
            html += "<p>\(inline(text))</p>\n"
        }
        return html
    }

    // MARK: Changes

    /// A top-level block covering source `lines`, marked if they changed,
    /// after a marker if text was removed just before it.
    private mutating func marked(_ out: String, lines range: Range<Int>, after previousEnd: Int) -> String {
        guard let changes else { return out }
        var prefix = ""
        if changes.removed.contains(where: { $0 >= previousEnd && $0 <= range.lowerBound }) {
            prefix = removedMarker()
        }
        // A list marks its own items.
        if listMarked {
            listMarked = false
            return prefix + out
        }
        guard changes.touches(range) else { return prefix + out }
        let id = nextMarkID()
        return prefix + "<div class=\"kt-change\" id=\"\(id)\">\n\(out)</div>\n"
    }

    private mutating func removedMarker() -> String {
        "<div class=\"kt-removed\" id=\"\(nextMarkID())\" title=\"Text was removed here\"></div>\n"
    }

    private mutating func nextMarkID() -> String {
        defer { marks += 1 }
        return "kt-change-\(marks)"
    }

    private mutating func heading(_ level: Int, _ text: String) -> String {
        var slug = MarkdownRenderer.slug(Self.plain(text))
        if let n = slugs[slug] {
            slugs[slug] = n + 1
            slug += "-\(n)"
        } else {
            slugs[slug] = 1
        }
        return "<h\(level) id=\"\(MarkdownRenderer.escape(slug))\">\(inline(text))</h\(level)>\n"
    }

    /// A heading's text without Markdown punctuation, for its anchor.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "~~", with: "")
    }

    private func code(_ lines: [String], language: String) -> String {
        let lang = language.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let path = "code." + (Self.languageExtensions[lang] ?? lang)
        let cls = lang.isEmpty ? "" : " class=\"language-\(MarkdownRenderer.escape(lang))\""
        var body = ""
        if ReviewSyntax.forPath(path) != nil {
            var highlighter = ReviewHighlighter(path: path)
            body = lines.map { Self.html(highlighter.highlight($0)) }.joined(separator: "\n")
        } else {
            body = MarkdownRenderer.escape(lines.joined(separator: "\n"))
        }
        return "<pre><code\(cls)>\(body)</code></pre>\n"
    }

    private static let languageExtensions: [String: String] = [
        "javascript": "js", "typescript": "ts", "python": "py", "ruby": "rb", "rust": "rs",
        "shell": "sh", "console": "sh", "shellsession": "sh", "objc": "m", "objective-c": "m",
        "c++": "cpp", "csharp": "cs", "kotlin": "kt", "golang": "go", "yml": "yaml",
    ]

    /// Highlighted code as spans with inline colors.
    private static func html(_ line: AttributedString) -> String {
        var out = ""
        for run in line.runs {
            let text = MarkdownRenderer.escape(String(line[run.range].characters))
            if let color = run.foregroundColor {
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                let hex = String(format: "#%02X%02X%02X",
                                 Int((ns.redComponent * 255).rounded()),
                                 Int((ns.greenComponent * 255).rounded()),
                                 Int((ns.blueComponent * 255).rounded()))
                out += "<span style=\"color:\(hex)\">\(text)</span>"
            } else {
                out += text
            }
        }
        return out
    }

    // MARK: Lists

    private struct Marker {
        let ordered: Bool
        /// The bullet character, or the delimiter after an ordered number.
        let symbol: Character
        let start: Int
        /// Columns before the marker.
        let indent: Int
        /// Columns before the item's content.
        let contentIndent: Int
        /// The rest of the line after the marker.
        let rest: String
    }

    private static func listMarker(_ line: String) -> Marker? {
        let lead = indent(line)
        guard lead < 4 || lead >= 0 else { return nil }
        let body = line.dropFirst(lead)
        guard let first = body.first else { return nil }
        if "-*+".contains(first) {
            let after = body.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            let spaces = min(after.prefix(while: { $0 == " " }).count, 4)
            let rest = String(after.drop(while: { $0 == " " }))
            return Marker(ordered: false, symbol: first, start: 0, indent: lead,
                          contentIndent: lead + 1 + (rest.isEmpty ? 1 : max(spaces, 1)), rest: rest)
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let tail = after.dropFirst()
        guard tail.isEmpty || tail.first == " " else { return nil }
        let spaces = min(tail.prefix(while: { $0 == " " }).count, 4)
        let rest = String(tail.drop(while: { $0 == " " }))
        return Marker(ordered: true, symbol: delim, start: Int(digits) ?? 1, indent: lead,
                      contentIndent: lead + digits.count + 1 + (rest.isEmpty ? 1 : max(spaces, 1)), rest: rest)
    }

    private mutating func list(
        _ lines: ArraySlice<String>, from start: Int, first: Marker, into html: inout String, top: Bool = false
    ) -> Int {
        var items: [[String]] = []
        /// Each item's source lines.
        var ranges: [Range<Int>] = []
        var i = start
        let end = lines.endIndex
        var marker = first
        var loose = false

        while true {
            let itemStart = i
            var item = [marker.rest]
            i += 1
            var sawBlank = false
            while i < end {
                let l = lines[i]
                if Self.isBlank(l) {
                    sawBlank = true
                    item.append("")
                    i += 1
                    continue
                }
                if Self.indent(l) >= marker.contentIndent {
                    if sawBlank { loose = loose || item.dropLast().contains(where: { !$0.isEmpty }) }
                    sawBlank = false
                    item.append(Self.dropIndent(l, marker.contentIndent))
                    i += 1
                    continue
                }
                if sawBlank { break }
                // A lazy continuation of the item's paragraph.
                if Self.listMarker(l) == nil, !Self.startsBlock(l) {
                    item.append(l.trimmingCharacters(in: .whitespaces))
                    i += 1
                    continue
                }
                break
            }
            while item.last == "" { item.removeLast() }
            items.append(item)
            ranges.append(itemStart..<i)

            // The next item of the same list, if there is one.
            var next = i
            var blanks = false
            while next < end, Self.isBlank(lines[next]) { next += 1; blanks = true }
            guard next < end, let m = Self.listMarker(lines[next]),
                  m.ordered == first.ordered, m.symbol == first.symbol,
                  m.indent < first.contentIndent, !Self.isRule(lines[next]) else { break }
            if blanks { loose = true }
            i = next
            marker = m
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        html += "<\(tag)\(startAttr)>\n"
        let marking = top && changes != nil
        for (n, var item) in items.enumerated() {
            var mark = ""
            if marking, let changes {
                let range = ranges[n]
                if n > 0, changes.removed.contains(where: { $0 > ranges[n - 1].upperBound - 1 && $0 <= range.lowerBound }) {
                    html += removedMarker()
                }
                if changes.touches(range) { mark = " id=\"\(nextMarkID())\"" }
            }
            var check = ""
            if let head = item.first, head.count >= 3 {
                let box = head.prefix(3)
                if box == "[ ]" || box == "[x]" || box == "[X]",
                   head.count == 3 || head.dropFirst(3).first == " " {
                    check = box == "[ ]" ? "<input type=\"checkbox\" disabled> " : "<input type=\"checkbox\" checked disabled> "
                    item[0] = String(head.dropFirst(3).drop(while: { $0 == " " }))
                }
            }
            var classes = check.isEmpty ? [] : ["task"]
            if !mark.isEmpty { classes.append("kt-change") }
            let cls = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
            html += "<li\(cls)\(mark)>\(check)\(blocks(item[...], tight: !loose))</li>\n"
        }
        html += "</\(tag)>\n"
        if marking { listMarked = true }
        return i
    }

    // MARK: Tables

    private static func tableDelimiter(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [String] = []
        for cell in cells {
            guard cell.contains("-"), cell.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): aligns.append("center")
            case (false, true): aligns.append("right")
            case (true, false): aligns.append("left")
            default: aligns.append("")
            }
        }
        return aligns
    }

    /// A table row's cells, splitting on pipes outside code and escapes.
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "`": inCode.toggle(); current.append(ch)
            case "|" where !inCode:
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private mutating func table(_ lines: ArraySlice<String>, from start: Int, header: [String],
                                aligns: [String], into html: inout String) -> Int {
        func row(_ cells: [String], _ tag: String) -> String {
            var out = "<tr>"
            for (n, align) in aligns.enumerated() {
                let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
                let text = n < cells.count ? inline(cells[n]) : ""
                out += "<\(tag)\(style)>\(text)</\(tag)>"
            }
            return out + "</tr>\n"
        }
        html += "<table>\n<thead>\n\(row(header, "th"))</thead>\n<tbody>\n"
        var i = start + 2
        while i < lines.endIndex, !Self.isBlank(lines[i]), lines[i].contains("|") || !Self.startsBlock(lines[i]) {
            if Self.startsBlock(lines[i]) { break }
            html += row(Self.cells(lines[i]), "td")
            i += 1
        }
        html += "</tbody>\n</table>\n"
        return i
    }

    // MARK: Line tests

    private static func indent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func dropIndent(_ line: String, _ n: Int) -> String {
        String(line.dropFirst(min(n, indent(line))))
    }

    private static func fenceOpen(_ line: String) -> (marker: String, info: String, indent: Int)? {
        let lead = indent(line)
        guard lead < 4 else { return nil }
        let body = line.dropFirst(lead)
        guard let ch = body.first, ch == "`" || ch == "~" else { return nil }
        let run = body.prefix(while: { $0 == ch })
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if ch == "`", info.contains("`") { return nil }
        return (String(run), info, lead)
    }

    private static func closesFence(_ line: String, _ marker: String) -> Bool {
        guard indent(line) < 4, let ch = marker.first else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= marker.count && t.allSatisfy { $0 == ch }
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard indent(line) < 4 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes, when set off by a space.
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let without = text.dropLast(closing)
            if without.isEmpty || without.last == " " { text = without.trimmingCharacters(in: .whitespaces) }
        }
        return (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let t = line.filter { $0 != " " }
        guard t.count >= 3, let ch = t.first, "-*_".contains(ch) else { return false }
        return t.allSatisfy { $0 == ch }
    }

    private static func isQuote(_ line: String) -> Bool {
        indent(line) < 4 && line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripQuote(_ line: String) -> String {
        var t = line.drop(while: { $0 == " " }).dropFirst()
        if t.first == " " { t = t.dropFirst() }
        return String(t)
    }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "iframe",
        "li", "main", "nav", "ol", "p", "picture", "pre", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "ul", "video", "img", "br", "a", "sub", "sup", "kbd", "span",
    ]

    private static func isHTMLBlock(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<!--") { return true }
        guard t.hasPrefix("<") else { return false }
        let name = t.dropFirst().drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber })
        guard !name.isEmpty, blockTags.contains(name.lowercased()) else { return false }
        // Inline tags like <a> or <img> start a block only when the line is
        // all markup; otherwise they're part of a paragraph.
        if ["a", "img", "br", "sub", "sup", "kbd", "span"].contains(name.lowercased()) {
            return t.hasSuffix(">")
        }
        return true
    }

    /// Whether a line interrupts a paragraph.
    private static func startsBlock(_ line: String) -> Bool {
        if fenceOpen(line) != nil || atxHeading(line) != nil || isRule(line) || isQuote(line) { return true }
        if isHTMLBlock(line) { return true }
        if let m = listMarker(line), m.indent < 4, !m.rest.isEmpty {
            return !m.ordered || m.start == 1
        }
        return false
    }

    // MARK: Inlines

    private func inline(_ text: String) -> String {
        Inline(chars: Array(text), renderer: self).render()
    }

    fileprivate func resolveReference(_ label: String) -> (url: String, title: String?)? {
        let key = label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        return references[key]
    }

    private static let sourceAttribute = try? NSRegularExpression(
        pattern: #"(\bsrc\s*=\s*)(["'])(.*?)\2"#, options: [.caseInsensitive])

    /// Raw HTML with its local `src`s embedded, like Markdown images.
    fileprivate func embedSources(_ html: String) -> String {
        guard html.range(of: "src", options: .caseInsensitive) != nil,
              let regex = Self.sourceAttribute else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: match.range(at: 3))
            let source = imageSource(value.replacingOccurrences(of: "&amp;", with: "&"))
            guard source != value else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range(at: 3).location - last))
            out += MarkdownRenderer.escape(source)
            last = match.range(at: 3).location + match.range(at: 3).length
        }
        return out + ns.substring(from: last)
    }

    /// An image's source: local files are embedded, so the page doesn't need
    /// to read the disk.
    fileprivate func imageSource(_ src: String) -> String {
        if src.contains("://") || src.hasPrefix("data:") || src.hasPrefix("//") { return src }
        let path = src.removingPercentEncoding ?? src
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        let ext = url.pathExtension.lowercased()
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp", "ico": "image/x-icon",
                     "avif": "image/avif", "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff"]
        guard let type = types[ext],
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 10_000_000,
              let data = try? Data(contentsOf: url) else { return src }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }
}

/// One paragraph's inline Markdown.
private struct Inline {
    let chars: [Character]
    let renderer: Renderer

    func render() -> String { render(0, chars.count) }

    private func render(_ from: Int, _ to: Int) -> String {
        var out = ""
        var i = from
        var text = ""
        func flush() {
            out += MarkdownRenderer.escape(text)
            text = ""
        }
        while i < to {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < to, chars[i + 1] == "\n" {
                    flush(); out += "<br>\n"; i += 2; continue
                }
                if i + 1 < to, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                    text.append(chars[i + 1]); i += 2; continue
                }
                text.append(c); i += 1

            case "`":
                let run = count("`", from: i, to: to)
                if let close = findRun("`", run, from: i + run, to: to) {
                    var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "),
                       !code.allSatisfy({ $0 == " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    flush()
                    out += "<code>\(MarkdownRenderer.escape(code))</code>"
                    i = close + run
                } else {
                    text += String(repeating: "`", count: run); i += run
                }

            case "!" where i + 1 < to && chars[i + 1] == "[":
                if let link = link(at: i + 1, to: to) {
                    flush()
                    let alt = String(chars[(i + 2)..<link.labelEnd])
                    let title = link.title.map { " title=\"\(MarkdownRenderer.escape($0))\"" } ?? ""
                    let src = renderer.imageSource(link.url)
                    out += "<img src=\"\(MarkdownRenderer.escape(src))\" alt=\"\(MarkdownRenderer.escape(alt))\"\(title)>"
                    i = link.end
                } else {
                    text.append(c); i += 1
                }

            case "[":
                if let link = link(at: i, to: to) {
                    flush()
                    let title = link.title.map { " title=\"\(MarkdownRenderer.escape($0))\"" } ?? ""
                    out += "<a href=\"\(MarkdownRenderer.escape(link.url))\"\(title)>\(render(i + 1, link.labelEnd))</a>"
                    i = link.end
                } else {
                    text.append(c); i += 1
                }

            case "<":
                if let end = autolink(at: i, to: to) {
                    flush()
                    var target = String(chars[(i + 1)..<end])
                    let label = target
                    if !target.contains(":"), target.contains("@") { target = "mailto:" + target }
                    out += "<a href=\"\(MarkdownRenderer.escape(target))\">\(MarkdownRenderer.escape(label))</a>"
                    i = end + 1
                } else if let end = tag(at: i, to: to) {
                    flush()
                    out += renderer.embedSources(String(chars[i...end]))
                    i = end + 1
                } else {
                    text.append(c); i += 1
                }

            case "&":
                if let end = entity(at: i, to: to) {
                    flush()
                    out += String(chars[i...end])
                    i = end + 1
                } else {
                    text.append(c); i += 1
                }

            case "*", "_", "~":
                if let span = emphasis(at: i, to: to) {
                    flush()
                    out += "<\(span.tag)>\(render(span.inner.lowerBound, span.inner.upperBound))</\(span.tag)>"
                    i = span.end
                } else {
                    let run = count(c, from: i, to: to)
                    text += String(repeating: String(c), count: run); i += run
                }

            case "\n":
                // Two trailing spaces make a hard break.
                if text.hasSuffix("  ") {
                    text = String(text.dropLast(2).reversed().drop(while: { $0 == " " }).reversed())
                    flush(); out += "<br>\n"
                } else {
                    text = String(text.reversed().drop(while: { $0 == " " }).reversed())
                    text.append("\n")
                }
                i += 1

            case "h", "w":
                if let end = bareURL(at: i, to: to) {
                    flush()
                    var url = String(chars[i..<end])
                    let label = url
                    if url.hasPrefix("www.") { url = "https://" + url }
                    out += "<a href=\"\(MarkdownRenderer.escape(url))\">\(MarkdownRenderer.escape(label))</a>"
                    i = end
                } else {
                    text.append(c); i += 1
                }

            default:
                text.append(c); i += 1
            }
        }
        flush()
        return out
    }

    private func count(_ ch: Character, from: Int, to: Int) -> Int {
        var n = 0
        while from + n < to, chars[from + n] == ch { n += 1 }
        return n
    }

    /// A closing run of exactly `length` `ch`s.
    private func findRun(_ ch: Character, _ length: Int, from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            if chars[i] == ch {
                let run = count(ch, from: i, to: to)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    // MARK: Links

    private struct Link {
        let labelEnd: Int
        let url: String
        let title: String?
        let end: Int
    }

    /// `[label](url "title")`, `[label][ref]`, `[label][]` or `[label]`,
    /// with `open` at the `[`.
    private func link(at open: Int, to: Int) -> Link? {
        // The matching `]`, skipping code spans and nested brackets.
        var depth = 0
        var i = open
        var close: Int?
        while i < to {
            switch chars[i] {
            case "\\": i += 1
            case "`":
                let run = count("`", from: i, to: to)
                if let end = findRun("`", run, from: i + run, to: to) { i = end + run - 1 } else { i += run - 1 }
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { close = i }
            default: break
            }
            if close != nil { break }
            i += 1
        }
        guard let close else { return nil }
        let label = String(chars[(open + 1)..<close])

        if close + 1 < to, chars[close + 1] == "(" {
            if let (url, title, end) = destination(from: close + 2, to: to) {
                return Link(labelEnd: close, url: url, title: title, end: end)
            }
        }
        if close + 1 < to, chars[close + 1] == "[" {
            if let refEnd = chars[(close + 2)..<to].firstIndex(of: "]") {
                let ref = String(chars[(close + 2)..<refEnd])
                if let def = renderer.resolveReference(ref.isEmpty ? label : ref) {
                    return Link(labelEnd: close, url: def.url, title: def.title, end: refEnd + 1)
                }
            }
            return nil
        }
        if let def = renderer.resolveReference(label) {
            return Link(labelEnd: close, url: def.url, title: def.title, end: close + 1)
        }
        return nil
    }

    /// `url "title")` after a link's `(`.
    private func destination(from start: Int, to: Int) -> (String, String?, Int)? {
        var i = start
        while i < to, chars[i] == " " || chars[i] == "\n" { i += 1 }
        var url = ""
        if i < to, chars[i] == "<" {
            i += 1
            while i < to, chars[i] != ">" { url.append(chars[i]); i += 1 }
            guard i < to else { return nil }
            i += 1
        } else {
            var depth = 0
            while i < to {
                let c = chars[i]
                if c == " " || c == "\n" { break }
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if c == "\\", i + 1 < to { url.append(chars[i + 1]); i += 2; continue }
                url.append(c)
                i += 1
            }
        }
        while i < to, chars[i] == " " || chars[i] == "\n" { i += 1 }
        var title: String?
        if i < to, let quote = Optional(chars[i]), quote == "\"" || quote == "'" || quote == "(" {
            let closing: Character = quote == "(" ? ")" : quote
            i += 1
            var t = ""
            while i < to, chars[i] != closing { t.append(chars[i]); i += 1 }
            guard i < to else { return nil }
            title = t
            i += 1
            while i < to, chars[i] == " " || chars[i] == "\n" { i += 1 }
        }
        guard i < to, chars[i] == ")" else { return nil }
        return (url, title, i + 1)
    }

    /// `<https://…>` or `<name@host>`: the index of the `>`.
    private func autolink(at i: Int, to: Int) -> Int? {
        guard let end = chars[(i + 1)..<to].firstIndex(of: ">") else { return nil }
        let body = String(chars[(i + 1)..<end])
        guard !body.isEmpty, !body.contains(" "), !body.contains("<") else { return nil }
        if let colon = body.firstIndex(of: ":") {
            let scheme = body[..<colon]
            guard scheme.count >= 2, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
            return end
        }
        if body.contains("@"), body.contains(".") { return end }
        return nil
    }

    /// Raw inline HTML: the index of the tag's `>`.
    private func tag(at i: Int, to: Int) -> Int? {
        guard i + 1 < to else { return nil }
        if chars[i + 1] == "!" {
            // A comment.
            guard i + 3 < to, chars[i + 2] == "-", chars[i + 3] == "-" else { return nil }
            var j = i + 4
            while j + 2 < to {
                if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" { return j + 2 }
                j += 1
            }
            return nil
        }
        var j = i + 1
        if chars[j] == "/" { j += 1 }
        guard j < to, chars[j].isLetter else { return nil }
        while j < to, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" { j += 1 }
        var quote: Character?
        while j < to {
            let c = chars[j]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return j
            } else if c == "<" {
                return nil
            }
            j += 1
        }
        return nil
    }

    /// `&name;` or `&#123;`: the index of the `;`.
    private func entity(at i: Int, to: Int) -> Int? {
        var j = i + 1
        while j < to, j - i <= 32 {
            let c = chars[j]
            if c == ";" { return j > i + 1 ? j : nil }
            guard c.isLetter || c.isNumber || c == "#" else { return nil }
            j += 1
        }
        return nil
    }

    /// `https://…`, `http://…` or `www.…` in running text: where it ends.
    private func bareURL(at i: Int, to: Int) -> Int? {
        if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "/" { return nil }
        let rest = String(chars[i..<min(to, i + 8)])
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") || rest.hasPrefix("www.") else { return nil }
        var j = i
        var parens = 0
        while j < to {
            let c = chars[j]
            if c.isWhitespace || c == "<" { break }
            if c == "(" { parens += 1 }
            if c == ")" {
                if parens == 0 { break }
                parens -= 1
            }
            j += 1
        }
        // Trailing punctuation belongs to the sentence.
        while j > i, ".,:;!?\"'*_~".contains(chars[j - 1]) { j -= 1 }
        return j - i > 8 ? j : nil
    }

    // MARK: Emphasis

    private struct Span {
        let tag: String
        let inner: Range<Int>
        let end: Int
    }

    /// `*em*`, `**strong**`, `***both***`, `_em_`, `__strong__`, `~~del~~`.
    private func emphasis(at i: Int, to: Int) -> Span? {
        let c = chars[i]
        let run = count(c, from: i, to: to)
        if c == "~" {
            guard run == 2 || run == 1 else { return nil }
        }
        // An opener can't be followed by a space, and `_` can't open inside
        // a word.
        guard i + run < to, !chars[i + run].isWhitespace else { return nil }
        if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }

        let lengths: [Int] = c == "~" ? [run] : (run >= 3 ? [3, 2, 1] : run == 2 ? [2, 1] : [1])
        for length in lengths {
            if let close = closer(c, length, from: i + length, to: to) {
                let inner = (i + length)..<close
                let tag: String
                switch (c, length) {
                case ("~", _): tag = "del"
                case (_, 1): tag = "em"
                case (_, 2): tag = "strong"
                default:
                    // `***both***`: strong around em.
                    return Span(tag: "strong", inner: (i + 2)..<(close + 1), end: close + 3)
                }
                return Span(tag: tag, inner: inner, end: close + length)
            }
        }
        return nil
    }

    private func closer(_ ch: Character, _ length: Int, from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {
                let run = count("`", from: i, to: to)
                if let end = findRun("`", run, from: i + run, to: to) { i = end + run } else { i += run }
                continue
            }
            if c == ch {
                let run = count(ch, from: i, to: to)
                let afterSpace = chars[i - 1].isWhitespace
                let wordAfter = i + run < to && (chars[i + run].isLetter || chars[i + run].isNumber)
                if run >= length, i > from, !afterSpace, !(ch == "_" && wordAfter) {
                    // For `***`, close at the end of the run so the inner
                    // emphasis keeps its own markers.
                    return length == 3 ? i : i + run - length
                }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }
}

// MARK: Changes

/// Which lines of a Markdown file changed since an earlier version: lines
/// added or rewritten, and places where lines were removed, as 0-based
/// line numbers in the new text.
struct MarkdownLineChanges: Equatable, Sendable {
    var changed: Set<Int> = []
    /// Lines were removed just before this line (the line count: at the end).
    var removed: Set<Int> = []

    var isEmpty: Bool { changed.isEmpty && removed.isEmpty }

    /// Whether any of `lines` changed, or lines were removed inside them.
    func touches(_ lines: Range<Int>) -> Bool {
        changed.contains { lines.contains($0) }
            || removed.contains { $0 > lines.lowerBound && $0 < lines.upperBound }
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// What changed from `old` to `new`.
    static func between(_ old: String, _ new: String) -> Self {
        let a = lines(old), b = lines(new)
        let diff = b.difference(from: a)
        var removedOld: Set<Int> = []
        var insertedNew: Set<Int> = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }
        var result = Self(changed: insertedNew)
        // Walk both to place each removal in the new text. A removal next
        // to an insertion is a rewrite, already marked as changed.
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedOld.contains(i) {
                if !insertedNew.contains(j), !insertedNew.contains(j - 1) { result.removed.insert(j) }
                i += 1
            } else if j < b.count, insertedNew.contains(j) {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return result
    }
}
