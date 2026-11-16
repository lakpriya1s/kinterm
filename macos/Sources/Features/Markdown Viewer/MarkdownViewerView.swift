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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ReviewColors.border)
            if model.showsSidebar {
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
            BrowserButton(symbol: "sidebar.left", help: "Show or Hide the File List", active: model.showsSidebar) {
                model.showsSidebar.toggle()
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

            Picker("", selection: $model.mode) {
                Text("Rendered").tag(MarkdownViewerModel.Mode.rendered)
                Text("Source").tag(MarkdownViewerModel.Mode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.trailing, 4)
            .help("Show the page rendered, or the Markdown as written")

            BrowserButton(symbol: "doc.on.doc", help: "Copy Path", enabled: model.current != nil) { model.copyPath() }
            BrowserButton(symbol: "folder", help: "Show in Finder", enabled: model.current != nil) { model.revealInFinder() }
            BrowserButton(symbol: "arrow.up.forward.app", help: "Open in Default App", enabled: model.current != nil) {
                model.openInEditor()
            }
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
        .frame(height: 34)
        .background(ReviewColors.surface)
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
            MarkdownWebView(model: model)
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
/// and none of it gets to run.
struct MarkdownWebView: NSViewRepresentable {
    @ObservedObject var model: MarkdownViewerModel

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: MarkdownViewerModel?
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
        }

        func scroll(_ webView: WKWebView, to fragment: String) {
            let id = (fragment.removingPercentEncoding ?? fragment)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("""
                (function() {
                  var el = document.getElementById('\(id)') || document.getElementsByName('\(id)')[0];
                  if (el) el.scrollIntoView();
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
        let view = WKWebView(frame: .zero, configuration: config)
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
        } else if let anchor = model.anchor {
            model.anchorShown()
            coordinator.scroll(view, to: anchor)
        }
    }
}
