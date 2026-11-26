import AppKit
import SwiftUI
import WebKit

/// A Markdown Viewer, beside a tab's terminal or in a window of its own: the
/// folder's Markdown files beside the open one.
struct MarkdownViewerView: View {
    enum Placement { case panel, window }

    @ObservedObject var model: MarkdownViewerModel
    var placement: Placement = .window
    let chooseFolder: () -> Void
    /// Panel: into a window of its own. Window: back beside its terminal,
    /// when it has one to go back to.
    var switchPlacement: (() -> Void)?
    var close: (() -> Void)?

    /// The file list's switch for where this viewer is: beside a terminal
    /// (or a grid tile) and in a window each remember their own.
    private var showsSidebar: Binding<Bool> {
        placement == .panel ? $model.showsDockedSidebar : $model.showsSidebar
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ReviewColors.border)
            if showsSidebar.wrappedValue {
                HSplitView {
                    MarkdownFileList(model: model, chooseFolder: chooseFolder)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
                    content.frame(minWidth: 320)
                }
            } else {
                content
            }
        }
        .background(ReviewColors.background)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            BrowserButton(symbol: "sidebar.left", help: "Show or Hide the File List", active: showsSidebar.wrappedValue) {
                showsSidebar.wrappedValue.toggle()
            }
            BrowserButton(symbol: "chevron.left", help: "Back", enabled: !model.back.isEmpty) { model.goBack() }
            BrowserButton(symbol: "chevron.right", help: "Forward", enabled: !model.forward.isEmpty) { model.goForward() }
            BrowserButton(symbol: "arrow.clockwise", help: "Reload", enabled: model.current != nil) { model.reload() }

            Text(model.currentPath ?? "No file open")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(model.current == nil ? ReviewColors.secondary : ReviewColors.text)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.changeCount > 0 || model.isNewFile {
                changesControl
            }

            // A narrow pane can't fit every control: the file actions fold
            // into a menu first, then the mode switch drops its words, so
            // the toolbar never spills past the pane's edges.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    modePicker(compact: false)
                    fileActionButtons
                }
                HStack(spacing: 2) {
                    modePicker(compact: false)
                    fileActionsMenu
                }
                HStack(spacing: 2) {
                    modePicker(compact: true)
                    fileActionsMenu
                }
            }
            .layoutPriority(1)

            if let switchPlacement {
                switch placement {
                case .panel:
                    BrowserButton(symbol: "macwindow.on.rectangle", help: "Open in Its Own Window", action: switchPlacement)
                case .window:
                    BrowserButton(symbol: "sidebar.trailing", help: "Put Back Beside the Terminal", action: switchPlacement)
                }
            }
            if let close {
                BrowserButton(symbol: "xmark.circle", help: "Close Markdown Viewer (⌘⇧M)", action: close)
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .clipped()
        .background(ReviewColors.surface)
    }

    private func modePicker(compact: Bool) -> some View {
        Picker("", selection: $model.mode) {
            if compact {
                Image(systemName: "doc.richtext").tag(MarkdownViewerModel.Mode.rendered)
                    .help("Rendered")
                Image(systemName: "chevron.left.forwardslash.chevron.right").tag(MarkdownViewerModel.Mode.source)
                    .help("Source")
            } else {
                Text("Rendered").tag(MarkdownViewerModel.Mode.rendered)
                Text("Source").tag(MarkdownViewerModel.Mode.source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .padding(.trailing, 4)
        .help("Show the page rendered, or the Markdown as written")
    }

    private var fileActionButtons: some View {
        HStack(spacing: 2) {
            BrowserButton(symbol: "doc.on.doc", help: "Copy Path", enabled: model.current != nil) { model.copyPath() }
            BrowserButton(symbol: "folder", help: "Show in Finder", enabled: model.current != nil) { model.revealInFinder() }
            BrowserButton(symbol: "arrow.up.forward.app", help: "Open in Default App", enabled: model.current != nil) {
                model.openInEditor()
            }
        }
    }

    /// The file actions, folded into one button for a narrow pane.
    private var fileActionsMenu: some View {
        Menu {
            Button("Copy Path") { model.copyPath() }
            Button("Show in Finder") { model.revealInFinder() }
            Button("Open in Default App") { model.openInEditor() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ReviewColors.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.current == nil)
        .help("File Actions")
        .accessibilityLabel("File Actions")
    }

    /// What the agent changed: how many, stepping through them, and done.
    private var changesControl: some View {
        HStack(spacing: 0) {
            if model.isNewFile {
                Text("New file")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ReviewColors.addedText)
                    .padding(.horizontal, 8)
                    .help("The agent wrote this file in its last turn")
            } else {
                BrowserButton(symbol: "chevron.up", help: "Previous Change") { model.previousChange() }
                Text("\(model.changeIndex + 1) of \(model.changeCount) change\(model.changeCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(ReviewColors.addedText)
                    .fixedSize()
                    .padding(.horizontal, 2)
                    .help("What the agent changed in its last turn")
                BrowserButton(symbol: "chevron.down", help: "Next Change") { model.nextChange() }
            }
            BrowserButton(symbol: "checkmark", help: "Done: Stop Marking the Changes") { model.dismissChanges() }
        }
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.addedText.opacity(0.12)))
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var content: some View {
        if let problem = model.problem {
            placeholder(symbol: "exclamationmark.triangle", title: problem, detail: model.currentPath ?? "")
        } else if model.current == nil {
            placeholder(
                symbol: "doc.richtext",
                title: model.listing ? "Looking for Markdown files…" : "Pick a file to read",
                detail: model.listing || !model.files.isEmpty ? "" : "No Markdown files in \(model.root.lastPathComponent).")
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    MarkdownWebView(model: model)
                    MarkdownCommentButton(model: model)
                    if let target = model.composing {
                        MarkdownCommentComposer(model: model, target: target)
                            .id(target.text)
                            .frame(maxWidth: 640)
                    }
                    if let image = model.zoomedImage {
                        MarkdownImageViewer(image: image) { model.zoomedImage = nil }
                    }
                }
                if !model.comments.isEmpty, model.zoomedImage == nil {
                    MarkdownCommentsBar(model: model)
                }
            }
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundColor(ReviewColors.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ReviewColors.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(ReviewColors.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReviewColors.background)
    }
}

// MARK: File list

private struct MarkdownFileList: View {
    @ObservedObject var model: MarkdownViewerModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(ReviewColors.secondary)
                Text(model.root.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ReviewColors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.root.path)
                Spacer(minLength: 4)
                BrowserButton(symbol: "folder.badge.gearshape", help: "Choose Another Folder…", action: chooseFolder)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 30)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(ReviewColors.secondary)
                TextField("Filter", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(ReviewColors.text)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(ReviewColors.background))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ReviewColors.border, lineWidth: 1))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider().overlay(ReviewColors.border)

            if model.listing, model.files.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.filteredFiles, id: \.self) { path in
                                MarkdownFileRow(model: model, path: path).id(path)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.current) { _ in
                        if let path = model.current.flatMap(model.relativePath) { proxy.scrollTo(path) }
                    }
                }
                Text("\(model.files.count) Markdown file\(model.files.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(ReviewColors.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .background(ReviewColors.surface)
    }
}

private struct MarkdownFileRow: View {
    @ObservedObject var model: MarkdownViewerModel
    let path: String
    @State private var hovering = false

    private var selected: Bool { model.current.flatMap(model.relativePath) == path }

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(selected ? ReviewColors.accent : ReviewColors.secondary)
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(ReviewColors.text)
                .lineLimit(1)
            if !folder.isEmpty {
                Text(folder)
                    .font(.system(size: 10))
                    .foregroundColor(ReviewColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(selected ? ReviewColors.selected : hovering ? ReviewColors.hovered : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.open(relative: path) }
        .help(path)
        .contextMenu {
            Button("Open in Default App") { NSWorkspace.shared.open(model.root.appendingPathComponent(path)) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.root.appendingPathComponent(path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.root.appendingPathComponent(path).path, forType: .string)
            }
        }
    }
}

// MARK: Page

/// The page, in WebKit with page scripts off: Markdown can carry raw HTML,
/// and none of it gets to run. The viewer's own script runs apart from it.
struct MarkdownWebView: NSViewRepresentable {
    @ObservedObject var model: MarkdownViewerModel

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var model: MarkdownViewerModel?
        weak var webView: WKWebView?
        /// The commented lines marked on the page.
        var markedComments: [ClosedRange<Int>] = []
        /// The picture right-clicked, for the menu about to open.
        var contextImage: MarkdownImage?
        var shownHTML = ""
        var shownFile: URL?
        var shownMode: MarkdownViewerModel.Mode?
        /// Where to scroll once the reloaded page is in.
        var restoreY: Double?

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            // A heading on this page.
            if url.isFileURL, let file = shownFile, url.path == file.path, let fragment = url.fragment {
                decisionHandler(.cancel)
                scroll(webView, to: fragment)
                return
            }
            decisionHandler(.cancel)
            model?.follow(url)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let y = restoreY {
                restoreY = nil
                webView.evaluateJavaScript("window.scrollTo(0, \(y))")
            }
            if let anchor = model?.anchor {
                model?.anchorShown()
                scroll(webView, to: anchor)
            }
            markedComments = model?.commentedLines ?? []
            markComments(webView)
        }

        func markComments(_ webView: WKWebView) {
            webView.evaluateJavaScript(
                MarkdownPageScript.markComments(markedComments), in: nil, in: .defaultClient) { _ in }
        }

        // MARK: Messages from the page script

        @MainActor
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String,
                  let model, let file = model.current else { return }
            switch type {
            case "selection":
                let text = (body["text"] as? String) ?? ""
                guard !text.isEmpty else {
                    if model.selection != nil { model.selection = nil }
                    return
                }
                let scale = webView?.magnification ?? 1
                let start = (body["start"] as? NSNumber)?.intValue ?? 0
                let end = (body["end"] as? NSNumber)?.intValue ?? 0
                model.selection = MarkdownSelection(
                    file: file,
                    text: text,
                    lines: start > 0 ? start...max(start, end) : nil,
                    point: CGPoint(
                        x: ((body["x"] as? NSNumber)?.doubleValue ?? 0) * scale,
                        y: ((body["y"] as? NSNumber)?.doubleValue ?? 0) * scale))
            case "image":
                if let image = Self.image(body) { model.zoomedImage = image }
            case "context":
                contextImage = Self.image(body)
            default:
                break
            }
        }

        private static func image(_ body: [String: Any]) -> MarkdownImage? {
            guard let src = body["src"] as? String, !src.isEmpty, let url = URL(string: src) else { return nil }
            return MarkdownImage(url: url, alt: (body["alt"] as? String) ?? "")
        }

        /// The viewer's own right-click items: on a picture, and on a
        /// selection.
        @MainActor
        func menuItems() -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            if let image = contextImage {
                contextImage = nil
                items.append(MarkdownMenuItem("Zoom Image", symbol: "plus.magnifyingglass") { [weak self] in
                    self?.model?.zoomedImage = image
                })
                if image.url.isFileURL {
                    items.append(MarkdownMenuItem("Open Image in Default App", symbol: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(image.url)
                    })
                    items.append(MarkdownMenuItem("Show Image in Finder", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([image.url])
                    })
                }
            }
            if model?.selection != nil {
                items.append(MarkdownMenuItem("Comment on Selection…", symbol: "text.bubble") { [weak self] in
                    self?.model?.startComment()
                })
            }
            return items
        }

        func scroll(_ webView: WKWebView, to fragment: String) {
            if fragment.hasPrefix("kt-line-"), let line = Int(fragment.dropFirst("kt-line-".count)) {
                webView.evaluateJavaScript(MarkdownPageScript.scroll(toLine: line))
                return
            }
            let id = (fragment.removingPercentEncoding ?? fragment)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("""
                (function() {
                  var el = document.getElementById('\(id)') || document.getElementsByName('\(id)')[0];
                  if (el) el.scrollIntoView(el.id.indexOf('kt-change-') === 0 ? { block: 'center' } : undefined);
                })()
                """)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.model = model
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        // The viewer's own script, apart from the page's (which stay off):
        // selections to comment on, and pictures to zoom.
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: MarkdownPageScript.source, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        content.add(MarkdownScriptProxy(context.coordinator), contentWorld: .defaultClient, name: MarkdownPageScript.handler)
        config.userContentController = content
        let view = MarkdownPageView(frame: .zero, configuration: config)
        view.extraMenuItems = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.menuItems() ?? [] }
        }
        context.coordinator.webView = view
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        guard let file = model.current else { return }
        let sameFile = coordinator.shownFile == file && coordinator.shownMode == model.mode
        if model.html != coordinator.shownHTML || !sameFile {
            coordinator.shownHTML = model.html
            coordinator.shownFile = file
            coordinator.shownMode = model.mode
            let html = model.html
            if sameFile {
                // Same file, new contents: keep the reader where they were.
                view.evaluateJavaScript("window.scrollY") { result, _ in
                    coordinator.restoreY = result as? Double
                    view.loadHTMLString(html, baseURL: file)
                }
            } else {
                view.loadHTMLString(html, baseURL: file)
            }
        } else {
            if let anchor = model.anchor {
                model.anchorShown()
                coordinator.scroll(view, to: anchor)
            }
            let commented = model.commentedLines
            if commented != coordinator.markedComments {
                coordinator.markedComments = commented
                coordinator.markComments(view)
            }
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
