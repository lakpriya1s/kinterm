import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Comments on a Markdown page for the tab's agent, like the review's line
// comments: select text, click Comment, say what to change, and send them
// all to the agent's prompt together. And pictures on the page, shown large
// to zoom and pan around.

/// Text selected on the page, and where it came from in the Markdown.
struct MarkdownSelection: Equatable {
    let file: URL
    let text: String
    /// The source lines it covers (1-based), when the page knows them.
    let lines: ClosedRange<Int>?
    /// Where the selection ends, in the page view's points, top-left origin.
    let point: CGPoint
}

/// A comment on a passage, for the agent.
struct MarkdownComment: Identifiable, Equatable {
    let id = UUID()
    let file: URL
    let lines: ClosedRange<Int>?
    /// The passage, quoted so the agent finds it even if lines moved.
    let quote: String
    var text: String
}

/// A picture from the page.
struct MarkdownImage: Equatable {
    let url: URL
    let alt: String
}

extension MarkdownViewerModel {
    func startComment() {
        guard let selection else { return }
        composing = selection
        self.selection = nil
    }

    func saveComment(_ text: String) {
        guard let target = composing else { return }
        composing = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        comments.append(MarkdownComment(file: target.file, lines: target.lines, quote: target.text, text: trimmed))
    }

    func delete(_ comment: MarkdownComment) {
        comments.removeAll { $0.id == comment.id }
        if comments.isEmpty { showsComments = false }
    }

    /// The source lines commented on in the open file, to mark on the page.
    var commentedLines: [ClosedRange<Int>] {
        comments.filter { $0.file == current }.compactMap(\.lines)
    }

    /// Open the comment's file at its passage.
    func reveal(_ comment: MarkdownComment) {
        let anchor = comment.lines.map { "kt-line-\($0.lowerBound)" }
        if comment.file == current {
            if let anchor { open(comment.file, anchor: anchor) }
        } else {
            open(comment.file, anchor: anchor)
        }
    }

    /// The agent's session in the tab: its terminal, or the focused one.
    private var agentSurface: Ghostty.SurfaceView? {
        guard let controller else { return nil }
        return controller.surfaceTree.first { $0.programStatus != nil } ?? controller.focusedSurface
    }

    var canSendComments: Bool { !comments.isEmpty && agentSurface != nil }

    /// The message the agent gets: each comment with the passage it's about.
    func commentMessage(relativeTo pwd: String?) -> String {
        var lines = ["Comments on the Markdown:"]
        let sorted = comments.enumerated().sorted { a, b in
            if a.element.file != b.element.file {
                return a.element.file.path.localizedStandardCompare(b.element.file.path) == .orderedAscending
            }
            let la = a.element.lines?.lowerBound ?? .max, lb = b.element.lines?.lowerBound ?? .max
            return la == lb ? a.offset < b.offset : la < lb
        }.map(\.element)
        for (i, comment) in sorted.enumerated() {
            lines.append("")
            var path = comment.file.path
            if let pwd, path.hasPrefix(pwd.hasSuffix("/") ? pwd : pwd + "/") {
                path = String(path.dropFirst(pwd.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            var location = path
            if let range = comment.lines {
                location += range.count == 1 ? ":\(range.lowerBound)" : ":\(range.lowerBound)-\(range.upperBound)"
            }
            lines.append("\(i + 1). \(location)")
            let quoted = comment.quote.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for line in quoted.prefix(4) { lines.append("   > \(line.prefix(200))") }
            if quoted.count > 4 { lines.append("   > …") }
            for textLine in comment.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("   \(textLine)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Type the comments into the agent's prompt, without pressing Return,
    /// and switch to it so you can read them over and send them.
    func sendCommentsToAgent() {
        guard !comments.isEmpty, let controller, let surface = agentSurface,
              let terminal = surface.surfaceModel else { return }
        terminal.sendText(commentMessage(relativeTo: surface.pwd))
        comments = []
        composing = nil
        showsComments = false
        ReviewCenter.shared.didSend(from: controller, to: surface)
    }

    func copyComments() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commentMessage(relativeTo: root.path), forType: .string)
    }
}

// MARK: Page script

/// Runs beside the page in its own world: the page's scripts stay off, but
/// this one reports selections and picture clicks back to the app.
enum MarkdownPageScript {
    static let handler = "kt"

    static let source = """
    (function() {
      const post = (m) => { try { window.webkit.messageHandlers.kt.postMessage(m); } catch (e) {} };
      const range = (node) => {
        let el = node && (node.nodeType === 1 ? node : node.parentElement);
        while (el && !(el.dataset && el.dataset.ktLine)) el = el.parentElement;
        if (!el) return null;
        const parts = el.dataset.ktLine.split('-').map(Number);
        return { start: parts[0], end: parts[1] };
      };
      let shown = false;
      const report = () => {
        const sel = window.getSelection();
        const text = sel && !sel.isCollapsed && sel.rangeCount ? sel.toString().trim() : '';
        if (!text) {
          if (shown) { shown = false; post({ type: 'selection', text: '' }); }
          return;
        }
        const r = sel.getRangeAt(0);
        const rects = r.getClientRects();
        const end = rects.length ? rects[rects.length - 1] : r.getBoundingClientRect();
        const a = range(r.startContainer), b = range(r.endContainer);
        shown = true;
        post({
          type: 'selection', text: text,
          start: a ? a.start : (b ? b.start : 0), end: b ? b.end : (a ? a.end : 0),
          x: end.right, y: end.bottom
        });
      };
      document.addEventListener('mouseup', () => setTimeout(report, 0));
      document.addEventListener('keyup', () => report());
      document.addEventListener('selectionchange', () => {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed) report();
      });
      let ticking = false;
      window.addEventListener('scroll', () => {
        if (!shown || ticking) return;
        ticking = true;
        requestAnimationFrame(() => { ticking = false; report(); });
      }, { passive: true });
      const imageAt = (target) => {
        const img = target && target.closest ? target.closest('img') : null;
        return img ? { src: img.currentSrc || img.src, alt: img.alt || '', linked: !!img.closest('a') } : null;
      };
      document.addEventListener('click', (e) => {
        const img = imageAt(e.target);
        if (!img || img.linked || e.button !== 0) return;
        e.preventDefault();
        post({ type: 'image', src: img.src, alt: img.alt });
      }, true);
      document.addEventListener('contextmenu', (e) => {
        const img = imageAt(e.target);
        post({ type: 'context', src: img ? img.src : '', alt: img ? img.alt : '' });
      }, true);
      window.ktMarkComments = (ranges) => {
        document.querySelectorAll('.kt-commented').forEach((el) => el.classList.remove('kt-commented'));
        if (!ranges.length) return;
        document.querySelectorAll('[data-kt-line]').forEach((el) => {
          const r = el.dataset.ktLine.split('-').map(Number);
          if (ranges.some((c) => c[0] <= r[1] && c[1] >= r[0])) el.classList.add('kt-commented');
        });
      };
    })();
    """

    /// Mark the blocks that have comments.
    static func markComments(_ ranges: [ClosedRange<Int>]) -> String {
        let list = ranges.map { "[\($0.lowerBound),\($0.upperBound)]" }.joined(separator: ",")
        return "window.ktMarkComments && window.ktMarkComments([\(list)])"
    }

    /// Scroll to the block holding source line `n`.
    static func scroll(toLine n: Int) -> String {
        """
        (function() {
          const all = document.querySelectorAll('[data-kt-line]');
          for (const el of all) {
            const r = el.dataset.ktLine.split('-').map(Number);
            if (r[0] <= \(n) && r[1] >= \(n)) { el.scrollIntoView({ block: 'center' }); return; }
          }
        })()
        """
    }
}

/// Passes the page's messages on without the web view holding on to the
/// coordinator.
final class MarkdownScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The page view, adding the viewer's own items to its right-click menu.
final class MarkdownPageView: WKWebView {
    /// What to add to the menu about to open.
    var extraMenuItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let extra = extraMenuItems?() ?? []
        guard !extra.isEmpty else { return }
        // These go nowhere in the viewer.
        for id in ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
                   "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile"] {
            if let item = menu.items.first(where: { $0.identifier?.rawValue == id }) { menu.removeItem(item) }
        }
        var at = 0
        for item in extra {
            menu.insertItem(item, at: at)
            at += 1
        }
        if menu.items.count > at { menu.insertItem(.separator(), at: at) }
    }
}

/// A menu item that runs a closure.
final class MarkdownMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { run() }
}

// MARK: Comment views

/// The button by a selection that starts a comment on it.
struct MarkdownCommentButton: View {
    @ObservedObject var model: MarkdownViewerModel

    var body: some View {
        GeometryReader { geometry in
            if let selection = model.selection, model.composing == nil {
                let width: CGFloat = 96
                let x = min(max(selection.point.x - width / 2, 8), max(geometry.size.width - width - 8, 8))
                let below = selection.point.y + 6
                let y = below + 26 > geometry.size.height ? selection.point.y - 54 : below
                Button { model.startComment() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                        Text("Comment")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(ReviewColors.accent))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .help("Comment on the selected text for the agent")
                .fixedSize()
                .offset(x: x, y: max(y, 4))
            }
        }
    }
}

/// Writing a comment on the selected passage.
struct MarkdownCommentComposer: View {
    @ObservedObject var model: MarkdownViewerModel
    let target: MarkdownSelection

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .foregroundColor(ReviewColors.accent)
                Text(target.lines.map { $0.count == 1 ? "Line \($0.lowerBound)" : "Lines \($0.lowerBound)–\($0.upperBound)" }
                    ?? "Comment")
                    .foregroundColor(ReviewColors.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            Text(target.text)
                .font(.system(size: 11))
                .italic()
                .foregroundColor(ReviewColors.secondary)
                .lineLimit(3)
                .padding(.leading, 8)
                .overlay(Rectangle().fill(ReviewColors.border).frame(width: 2), alignment: .leading)
            TextField("Tell the agent what to change here…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(ReviewColors.text)
                .lineLimit(2...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReviewColors.accent.opacity(0.7)))
                .focused($focused)
                .onSubmit { model.saveComment(text) }
                .onExitCommand { model.composing = nil }
            HStack(spacing: 6) {
                Text("↵ add · ⌥↵ new line · esc cancel")
                    .font(.system(size: 10))
                    .foregroundColor(ReviewColors.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { model.composing = nil }
                    .controlSize(.small)
                Button("Add Comment") { model.saveComment(text) }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(ReviewColors.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReviewColors.border))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        .padding(10)
        .onAppear { focused = true }
    }
}

/// The comments waiting to go to the agent, and sending them.
struct MarkdownCommentsBar: View {
    @ObservedObject var model: MarkdownViewerModel

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(ReviewColors.border)
            if model.showsComments {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.comments) { comment in
                            MarkdownCommentCard(model: model, comment: comment)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(ReviewColors.border)
            }
            HStack(spacing: 6) {
                Button { model.showsComments.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.showsComments ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                        Image(systemName: "text.bubble.fill")
                            .foregroundColor(ReviewColors.accent)
                        Text("\(model.comments.count) comment\(model.comments.count == 1 ? "" : "s")")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ReviewColors.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.showsComments ? "Hide the Comments" : "Show the Comments")
                Spacer(minLength: 4)
                BrowserButton(symbol: "doc.on.clipboard", help: "Copy the Comments") { model.copyComments() }
                BrowserButton(symbol: "trash", help: "Discard All Comments") {
                    model.comments = []
                    model.showsComments = false
                }
                Button { model.sendCommentsToAgent() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                        Text("Send \(model.comments.count)")
                    }
                }
                .controlSize(.small)
                .disabled(!model.canSendComments)
                .help(model.controller == nil
                    ? "This viewer isn't with an agent's tab. Copy the comments instead."
                    : "Type the comments into the agent's prompt. Read them over, then press Return there.")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .background(ReviewColors.surface)
    }
}

private struct MarkdownCommentCard: View {
    @ObservedObject var model: MarkdownViewerModel
    let comment: MarkdownComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(location)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ReviewColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(comment.quote)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundColor(ReviewColors.secondary)
                    .lineLimit(2)
                    .padding(.leading, 6)
                    .overlay(Rectangle().fill(ReviewColors.border).frame(width: 2), alignment: .leading)
                Text(comment.text)
                    .font(.system(size: 12))
                    .foregroundColor(ReviewColors.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.delete(comment) } label: {
                Image(systemName: "trash").foregroundColor(ReviewColors.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete Comment")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReviewColors.border))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(comment) }
        .help("Show this passage")
    }

    private var location: String {
        let path = model.relativePath(comment.file) ?? comment.file.lastPathComponent
        guard let lines = comment.lines else { return path }
        return lines.count == 1 ? "\(path):\(lines.lowerBound)" : "\(path):\(lines.lowerBound)-\(lines.upperBound)"
    }
}

// MARK: Pictures

/// A picture from the page, large: pinch or the buttons to zoom, grab it
/// with the hand to move it around, double-click to switch between fitting
/// and full size.
struct MarkdownImageViewer: View {
    let image: MarkdownImage
    let close: () -> Void

    @StateObject private var zoom = MarkdownImageZoom()
    @State private var loaded: (image: NSImage, data: Data, type: String?)?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ReviewColors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let size = loaded?.image.size {
                    Text("\(Int(size.width))×\(Int(size.height))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(ReviewColors.secondary)
                        .fixedSize()
                        .padding(.trailing, 6)
                }
                BrowserButton(symbol: "minus.magnifyingglass", help: "Zoom Out (⌘-)") { zoom.zoom(by: 1 / 1.25) }
                    .keyboardShortcut("-", modifiers: .command)
                Text("\(Int((zoom.magnification * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(ReviewColors.secondary)
                    .frame(width: 44)
                BrowserButton(symbol: "plus.magnifyingglass", help: "Zoom In (⌘+)") { zoom.zoom(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                BrowserButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit (⌘9)") { zoom.fit() }
                    .keyboardShortcut("9", modifiers: .command)
                BrowserButton(symbol: "1.magnifyingglass", help: "Actual Size (⌘0)") { zoom.actualSize() }
                    .keyboardShortcut("0", modifiers: .command)
                BrowserButton(symbol: "doc.on.doc", help: "Copy Image", enabled: loaded != nil) { copy() }
                BrowserButton(symbol: "arrow.up.forward.app", help: "Open in Preview", enabled: loaded != nil) { openExternally() }
                BrowserButton(symbol: "xmark.circle", help: "Close (esc)", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            .background(ReviewColors.surface)
            Divider().overlay(ReviewColors.border)
            ZStack {
                if let loaded {
                    MarkdownZoomingImage(image: loaded.image, zoom: zoom)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 28))
                        Text("This picture couldn't be loaded.")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(ReviewColors.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
        }
        .task(id: image.url) {
            loaded = nil
            failed = false
            if let result = await Self.load(image.url) { loaded = result } else { failed = true }
        }
    }

    private var title: String {
        if !image.alt.isEmpty { return image.alt }
        if image.url.scheme == "data" { return "Image" }
        return image.url.lastPathComponent.removingPercentEncoding ?? image.url.lastPathComponent
    }

    private func copy() {
        guard let loaded else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([loaded.image])
    }

    /// In the default app for pictures: the file itself when it's on disk.
    private func openExternally() {
        if image.url.isFileURL {
            NSWorkspace.shared.open(image.url)
            return
        }
        guard let loaded else { return }
        let ext = loaded.type.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "png"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinTerm Image \(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try loaded.data.write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    /// The picture's bytes: from disk, from the page's embedded data, or
    /// from the web.
    private static func load(_ url: URL) async -> (image: NSImage, data: Data, type: String?)? {
        var data: Data?
        var type: String?
        if url.scheme == "data" {
            let raw = url.absoluteString
            guard let comma = raw.firstIndex(of: ",") else { return nil }
            let header = raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]
            let body = String(raw[raw.index(after: comma)...])
            type = header.split(separator: ";").first.map(String.init)
            data = header.hasSuffix(";base64")
                ? Data(base64Encoded: body.removingPercentEncoding ?? body, options: .ignoreUnknownCharacters)
                : (body.removingPercentEncoding ?? body).data(using: .utf8)
        } else if url.isFileURL {
            data = await Task.detached { try? Data(contentsOf: url) }.value
            type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        } else if let (bytes, response) = try? await URLSession.shared.data(from: url) {
            data = bytes
            type = response.mimeType
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        return (image, data, type)
    }
}

/// The zoom of the picture being shown, for the buttons to change.
@MainActor
final class MarkdownImageZoom: ObservableObject {
    @Published var magnification: CGFloat = 1
    weak var scrollView: NSScrollView?
    var imageSize: CGSize = .zero

    var fitMagnification: CGFloat {
        guard let scrollView, imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let bounds = scrollView.contentView.frame.size
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height, 1)
    }

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(scrollView.magnification * factor, centeredAt: center)
        changed()
    }

    func fit() {
        guard let scrollView else { return }
        scrollView.magnification = max(fitMagnification, scrollView.minMagnification)
        changed()
    }

    func actualSize() {
        guard let scrollView else { return }
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(1, centeredAt: center)
        changed()
    }

    /// Double-click: full size at the click, or back to fitting.
    func toggle(at point: NSPoint) {
        guard let scrollView else { return }
        if abs(scrollView.magnification - fitMagnification) < 0.01 {
            scrollView.setMagnification(max(1, fitMagnification * 2), centeredAt: point)
        } else {
            scrollView.magnification = fitMagnification
        }
        changed()
    }

    func changed() {
        if let scrollView { magnification = scrollView.magnification }
    }
}

private struct MarkdownZoomingImage: NSViewRepresentable {
    let image: NSImage
    let zoom: MarkdownImageZoom

    final class Coordinator: NSObject {
        let zoom: MarkdownImageZoom
        var fitted = false
        var shown: NSImage?

        init(zoom: MarkdownImageZoom) { self.zoom = zoom }

        @MainActor @objc func magnified(_ note: Notification) { zoom.changed() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = MarkdownCenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 32
        let imageView = MarkdownPanningImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.doubleClicked = { [weak zoom] point in zoom?.toggle(at: point) }
        scrollView.documentView = imageView
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.magnified(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        zoom.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        zoom.scrollView = scrollView
        guard context.coordinator.shown !== image, let imageView = scrollView.documentView as? NSImageView else { return }
        context.coordinator.shown = image
        let size = image.size
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: size)
        zoom.imageSize = size
        // Fit once the scroll view has its size.
        DispatchQueue.main.async { zoom.fit() }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

/// The picture: a hand to grab it and move it around, and a double-click
/// to zoom.
private final class MarkdownPanningImageView: NSImageView {
    var doubleClicked: ((NSPoint) -> Void)?
    private var dragStart: NSPoint?
    private var originAtStart: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            doubleClicked?(convert(event.locationInWindow, from: nil))
            return
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        dragStart = event.locationInWindow
        originAtStart = clip.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let scale = max(scrollView.magnification, 0.01)
        var bounds = clip.bounds
        // The picture follows the hand.
        bounds.origin = NSPoint(
            x: originAtStart.x - (event.locationInWindow.x - start.x) / scale,
            y: originAtStart.y - (event.locationInWindow.y - start.y) / scale)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }
}

/// Keeps a picture smaller than the view in its middle.
private final class MarkdownCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}
