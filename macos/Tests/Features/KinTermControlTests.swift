//
//  KinTermControlTests.swift
//  GhosttyTests
//
//  Tests for the `kinterm-ctl` control commands: proving which terminal a
//  request comes from, and trimming terminal text.
//

import Darwin
import Foundation
import Testing
@testable import Ghostty

struct ControlPeerTests {
    /// A pty pair, the device of its terminal side, and a cleanup.
    private func pty() -> (dev_t, () -> Void)? {
        var primary: Int32 = 0
        var secondary: Int32 = 0
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { return nil }
        var info = stat()
        guard fstat(secondary, &info) == 0 else { return nil }
        return (info.st_rdev, { close(primary); close(secondary) })
    }

    @Test func refusesATerminalTheProcessDoesntRunOn() throws {
        // A fresh pty no process has as its controlling terminal: this
        // process and its ancestors don't run on it.
        let (device, cleanup) = try #require(pty())
        defer { cleanup() }
        #expect(ControlPeer.runs(getpid(), on: device) == false)
    }

    @Test func acceptsTheTerminalTheProcessRunsOn() throws {
        // The test runner's own controlling terminal, when it has one.
        let fd = open("/dev/tty", O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        #expect(ControlPeer.runs(getpid(), on: info.st_rdev) == true)
    }

    @Test func cantTellForAProcessThatIsGone() {
        #expect(ControlPeer.runs(pid_t(Int32.max - 1), on: 0) == nil)
    }

    @Test func findsThePeerOfAUnixSocket() {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return }
        defer { close(fds[0]); close(fds[1]) }
        #expect(ControlPeer.pid(of: fds[0]) == getpid())
    }
}

struct KinTermControlTailTests {
    @Test @MainActor func keepsTheLastLinesWithoutTrailingBlankRows() {
        let text = "one\ntwo\nthree\n\n   \n"
        #expect(KinTermControl.tail(text, lines: 2) == "two\nthree")
        #expect(KinTermControl.tail(text, lines: nil) == "one\ntwo\nthree")
    }

    @Test @MainActor func clampsTheLineCount() {
        #expect(KinTermControl.tail("a\nb", lines: 0) == "b")
        #expect(KinTermControl.tail("", lines: 5) == "")
    }
}

struct MarkdownViewerTargetTests {
    @Test func tellsFilesFoldersAndTheRestApart() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinterm-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = dir.appendingPathComponent("plan.md")
        let code = dir.appendingPathComponent("main.swift")
        try Data("# Plan".utf8).write(to: plan)
        try Data("".utf8).write(to: code)

        #expect(MarkdownViewerCenter.target(plan.path) == .file(plan.standardizedFileURL))
        #expect(MarkdownViewerCenter.target(dir.path) == .folder(dir.standardizedFileURL))
        #expect(MarkdownViewerCenter.target(code.path) == .notMarkdown)
        #expect(MarkdownViewerCenter.target(dir.appendingPathComponent("gone.md").path) == .missing)
    }
}

struct MarkdownRendererTests {
    private func render(_ text: String) -> String {
        MarkdownRenderer.page(text, file: URL(fileURLWithPath: "/tmp/x.md"))
    }

    @Test func rendersTheCommonBlocks() {
        let html = render("# Title\n\n- [x] done\n- todo\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n\n```sh\necho hi\n```\n")
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<input type=\"checkbox\" checked disabled> done"))
        #expect(html.contains("<th style=\"text-align:right\">b</th>"))
        #expect(html.contains("<code class=\"language-sh\">"))
    }

    @Test func escapesTextAndKeepsLinks() {
        let html = render("1 < 2 and **bold** [docs](docs/a.md#top)")
        #expect(html.contains("1 &lt; 2 and <strong>bold</strong> <a href=\"docs/a.md#top\">docs</a>"))
    }
}

/// What the Markdown Viewer marks after an agent changed a file.
struct MarkdownChangesTests {
    @Test func findsChangedAddedAndRemovedLines() {
        let old = "# Plan\n\nIntro.\n\n- one\n- two\n- three\n\nEnd.\n"
        let new = "# Plan\n\nIntro, rewritten.\n\n- one\n- three\n- four\n\nEnd.\n"
        let changes = MarkdownLineChanges.between(old, new)
        // Line 2 rewritten; "- four" added at line 6.
        #expect(changes.changed == [2, 6])
        // "- two" removed before line 5 ("- three").
        #expect(changes.removed == [5])
        #expect(MarkdownLineChanges.between(old, old).isEmpty)
    }

    @Test func marksOnlyTheBlocksAndItemsThatChanged() {
        let old = "# Plan\n\nIntro.\n\n- one\n- two\n\nEnd.\n"
        let new = "# Plan\n\nIntro, rewritten.\n\n- one\n- two, longer\n\nEnd.\n"
        let file = URL(fileURLWithPath: "/tmp/plan.md")
        let page = MarkdownRenderer.page(new, file: file, changes: .between(old, new))
        #expect(page.changes == 2)
        #expect(page.html.contains("<div class=\"kt-change\" id=\"kt-change-0\">\n<p>Intro, rewritten.</p>"))
        #expect(page.html.contains("<li class=\"kt-change\" id=\"kt-change-1\">two, longer"))
        #expect(page.html.contains("<li>one"))
        #expect(!page.html.contains("kt-change-2"))
        // Unchanged blocks stay as they were.
        #expect(page.html.contains("<p>End.</p>"))
    }

    @Test func marksWhereTextWasRemoved() {
        let old = "First.\n\nGone.\n\nLast.\n"
        let new = "First.\n\nLast.\n"
        let page = MarkdownRenderer.page(new, file: URL(fileURLWithPath: "/tmp/a.md"), changes: .between(old, new))
        #expect(page.changes == 1)
        #expect(page.html.contains("class=\"kt-removed\" id=\"kt-change-0\""))
    }

    @Test func linesKeepTheirNumbersPastFrontMatterAndReferences() {
        let old = "---\ntitle: x\n---\n[a]: https://a.example\n\nSame.\n\nOld.\n"
        let new = "---\ntitle: x\n---\n[a]: https://a.example\n\nSame.\n\nNew.\n"
        let page = MarkdownRenderer.page(new, file: URL(fileURLWithPath: "/tmp/a.md"), changes: .between(old, new))
        #expect(page.changes == 1)
        #expect(page.html.contains("<div class=\"kt-change\" id=\"kt-change-0\">\n<p>New.</p>"))
    }
}
