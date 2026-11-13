import Quartz
import SwiftUI

// The review view, shown beside a terminal or in its own window: what the
// agent changed, the repository's files, and comments to send back. See
// scope/designs/08-code-review.md.

struct ReviewView: View {
    enum Presentation {
        /// Beside the terminal.
        case panel
        /// In its own window.
        case window
        /// As a tile in a grid, under the tile's own header.
        case tile
    }

    @ObservedObject var model: ReviewModel
    let presentation: Presentation
    /// Moves the review between the side panel and its own window. Nil when
    /// the other place isn't available, as in Grid View.
    var switchPresentation: (() -> Void)?
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model, presentation: presentation,
                         switchPresentation: switchPresentation, close: close)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider().overlay(ReviewColors.border)
                .overlay(alignment: .top) {
                    // Something's being looked up: a thin moving bar, so a
                    // big workspace doesn't look stuck.
                    if model.loading || (model.tab == .files && model.treeLoading) {
                        ReviewLoadingBar()
                    }
                }
            // When there's less room than the list and viewer want, they're
            // cut off at the bottom rather than drawn over the header.
            content
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
            Divider().overlay(ReviewColors.border)
            ReviewFooter(model: model)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .background(ReviewColors.background)
        .foregroundColor(ReviewColors.text)
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if model.root == nil, !model.loading {
            ReviewEmpty(
                symbol: "folder.badge.questionmark",
                title: "No repository",
                detail: model.error ?? "Open a terminal in a git repository to review its changes.")
        } else {
            let list = Group {
                switch model.tab {
                case .changes: ReviewChangesList(model: model)
                case .files: ReviewFilesList(model: model)
                }
            }
            switch presentation {
            case .panel:
                stacked(list)
            case .window:
                sideBySide(list)
            case .tile:
                // Tiles come in all sizes: side by side when there's room.
                GeometryReader { geometry in
                    if geometry.size.width >= 760 {
                        sideBySide(list)
                    } else {
                        stacked(list)
                    }
                }
            }
        }
    }
}

extension ReviewView {
    private func stacked<List: View>(_ list: List) -> some View {
        VSplitView {
            list.frame(minHeight: 60, idealHeight: 200, maxHeight: .infinity)
            ReviewViewer(model: model).frame(minHeight: 80, maxHeight: .infinity)
        }
    }

    private func sideBySide<List: View>(_ list: List) -> some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 280, maxWidth: 720)
            ReviewViewer(model: model).frame(minWidth: 320, maxWidth: .infinity)
        }
    }
}

// MARK: Header

private struct ReviewHeader: View {
    @ObservedObject var model: ReviewModel
    let presentation: ReviewView.Presentation
    let switchPresentation: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: model.headerRepo == nil ? "square.stack.3d.up" : "arrow.triangle.branch")
                    .foregroundColor(ReviewColors.secondary)
                if model.isMultiRepo {
                    ReviewRepoPicker(model: model)
                } else {
                    Text(model.repoName).font(.system(size: 12, weight: .semibold))
                }
                if model.headerRepo == nil, model.isMultiRepo {
                    Text("\(model.repos.count) repositories")
                        .font(.system(size: 11))
                        .foregroundColor(ReviewColors.secondary)
                        .lineLimit(1)
                } else if let branch = model.branch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ReviewColors.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if model.loading || model.treeLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .help(model.loading ? "Looking for changes…" : "Listing files…")
                }
                ReviewIconButton(symbol: "arrow.clockwise", help: "Refresh") { model.refresh() }
                if let switchPresentation {
                    ReviewIconButton(
                        symbol: presentation == .panel ? "macwindow.on.rectangle" : "sidebar.right",
                        help: presentation == .panel ? "Open in Its Own Window" : "Show Beside the Terminal",
                        action: switchPresentation)
                }
                switch presentation {
                case .panel:
                    ReviewIconButton(symbol: "xmark", help: "Close Review (⌘⇧R)", action: close)
                case .window, .tile:
                    EmptyView()
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $model.tab) {
                    Text(model.files.isEmpty ? "Changes" : "Changes \(model.files.count)").tag(ReviewModel.Tab.changes)
                    Text("Files").tag(ReviewModel.Tab.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 4)

                if model.tab == .changes {
                    Picker("", selection: $model.scope) {
                        ForEach(ReviewModel.Scope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(model.scope.help)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ReviewColors.surface)
    }
}

/// Shows every repository in a workspace, or just one.
private struct ReviewRepoPicker: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        Menu {
            Picker("Repository", selection: $model.focusedRepo) {
                Text("All Repositories").tag(String?.none)
                Divider()
                ForEach(model.repos) { repo in
                    let count = model.changeCount(repo)
                    Text(count > 0 ? "\(repo.name)  ·  \(count)" : repo.name).tag(Optional(repo.prefix))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(model.repoName).font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.workspace?.file.map { "Repositories from \(($0 as NSString).lastPathComponent)" }
              ?? "Repositories in this folder")
    }
}

/// An indeterminate bar along the header's bottom edge.
private struct ReviewLoadingBar: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(ReviewColors.accent)
                .frame(width: geometry.size.width * 0.3, height: 2)
                .offset(x: geometry.size.width * phase)
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .allowsHitTesting(false)
    }
}

private struct ReviewIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundColor(hovering ? ReviewColors.text : ReviewColors.secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? ReviewColors.hovered : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ReviewEmpty: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundColor(ReviewColors.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(ReviewColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Changes tab

private struct ReviewChangesList: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(ReviewColors.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ReviewColors.card)
            }

            if model.files.isEmpty, model.excludedCount > 0 {
                VStack(spacing: 10) {
                    ReviewEmpty(
                        symbol: "eye.slash",
                        title: "Only excluded changes",
                        detail: "\(model.excludedCount) changed file\(model.excludedCount == 1 ? " is" : "s are") hidden by files.exclude.")
                    Button("Show Them") { model.showExcluded = true }
                    Spacer()
                }
            } else if model.files.isEmpty {
                ReviewEmpty(
                    symbol: "checkmark.circle",
                    title: model.loading ? "Looking for changes…" : "No changes",
                    detail: model.loading ? "" : "Nothing has changed in this scope.")
            } else {
                summary
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            switch model.changesLayout {
                            case .list:
                                ForEach(model.files) { file in
                                    ReviewFileRow(model: model, file: file).id(file.path)
                                }
                            case .tree:
                                ForEach(model.visibleChangeRows) { row in
                                    if let file = row.node.file {
                                        ReviewFileRow(model: model, file: file, depth: row.depth).id(file.path)
                                    } else {
                                        ReviewFolderRow(model: model, node: row.node, depth: row.depth).id(row.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.viewer) { viewer in
                        if case .diff(let path) = viewer { proxy.scrollTo(path) }
                    }
                }
            }
        }
    }

    private var summary: some View {
        let totals = model.totals
        return HStack(spacing: 8) {
            Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s")")
            Text("+\(totals.added)").foregroundColor(ReviewColors.addedText)
            Text("−\(totals.removed)").foregroundColor(ReviewColors.removedText)
            if model.excludedCount > 0 || model.showExcluded {
                Button(model.showExcluded ? "hide excluded" : "\(model.excludedCount) excluded") {
                    model.showExcluded.toggle()
                }
                .buttonStyle(.plain)
                .foregroundColor(ReviewColors.accent)
                .help(model.showExcluded
                      ? "Hide files that files.exclude hides"
                      : "Hidden by files.exclude in your VS Code settings. Click to show them.")
            }
            Spacer()
            Text("\(model.viewedCount)/\(model.files.count) viewed")
                .foregroundColor(ReviewColors.secondary)
            ProgressView(value: Double(model.viewedCount), total: Double(max(model.files.count, 1)))
                .frame(width: 50)
                .tint(ReviewColors.addedText)
            ReviewIconButton(
                symbol: model.changesLayout == .tree ? "list.bullet" : "list.bullet.indent",
                help: model.changesLayout == .tree ? "View as List" : "View as Tree"
            ) {
                model.changesLayout = model.changesLayout == .tree ? .list : .tree
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(ReviewColors.surface.opacity(0.6))
        .contentShape(Rectangle())
        .contextMenu { ReviewLayoutMenu(model: model) }
    }
}

/// The Changes tab's view options, for its right-click menus.
private struct ReviewLayoutMenu: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        Picker("View", selection: $model.changesLayout) {
            Text("View as List").tag(ReviewModel.ChangesLayout.list)
            Text("View as Tree").tag(ReviewModel.ChangesLayout.tree)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        if model.changesLayout == .tree {
            Divider()
            Button("Collapse All") { model.collapseAll() }
            Button("Expand All") { model.expandAll() }
        }
        Divider()
        Toggle("Show Files Hidden by files.exclude", isOn: $model.showExcluded)
    }
}

private struct ReviewFolderRow: View {
    @ObservedObject var model: ReviewModel
    let node: ReviewChangeNode
    let depth: Int

    @State private var hovering = false

    private var open: Bool { !model.collapsed.contains(node.id) }

    var body: some View {
        let viewedCount = model.viewedCount(node)
        let allViewed = viewedCount == node.files.count
        HStack(spacing: 6) {
            Button { model.toggleViewed(folder: node) } label: {
                Image(systemName: allViewed ? "checkmark.square.fill" : viewedCount > 0 ? "minus.square.fill" : "square")
                    .foregroundColor(viewedCount > 0 ? ReviewColors.addedText : ReviewColors.secondary)
            }
            .buttonStyle(.plain)
            .help(allViewed ? "Mark Folder as Not Viewed" : "Mark Folder as Viewed")

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ReviewColors.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 10)
            if let repo = node.repo {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundColor(ReviewColors.accent)
                Text(node.name)
                    .fontWeight(.semibold)
                    .foregroundColor(allViewed ? ReviewColors.secondary : ReviewColors.text)
                    .lineLimit(1)
                if let branch = model.repoStates[repo]?.branch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ReviewColors.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Image(systemName: open ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ReviewColors.accent.opacity(0.8))
                Text(node.name)
                    .foregroundColor(allViewed ? ReviewColors.secondary : ReviewColors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text("\(viewedCount)/\(node.files.count)").foregroundColor(ReviewColors.secondary)
            Text("+\(node.added)").foregroundColor(ReviewColors.addedText)
            Text("−\(node.removed)").foregroundColor(ReviewColors.removedText)
        }
        .font(.system(size: 12))
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? ReviewColors.hovered : .clear)
                .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapsed(node) }
        .onHover { hovering = $0 }
        .help(node.repo.flatMap { model.repo($0)?.root } ?? node.id)
        .contextMenu {
            Button(open ? "Collapse" : "Expand") { model.toggleCollapsed(node) }
            Button(allViewed ? "Mark All as Not Viewed" : "Mark All as Viewed") {
                model.toggleViewed(folder: node)
            }
            if let repo = node.repo {
                Button("Show Only This Repository") { model.focusedRepo = repo }
            }
            Divider()
            ReviewLayoutMenu(model: model)
        }
    }
}

private struct ReviewFileRow: View {
    @ObservedObject var model: ReviewModel
    let file: ReviewFileDiff
    /// How deep the file sits in the tree, or nil in the flat list.
    var depth: Int?

    @State private var hovering = false

    private var selected: Bool { model.viewer == .diff(file.path) }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.toggleViewed(file) } label: {
                Image(systemName: model.isViewed(file) ? "checkmark.square.fill" : "square")
                    .foregroundColor(model.isViewed(file) ? ReviewColors.addedText : ReviewColors.secondary)
            }
            .buttonStyle(.plain)
            .help(model.isViewed(file) ? "Mark as Not Viewed" : "Mark as Viewed")

            ReviewStatusBadge(status: file.status)

            HStack(spacing: 0) {
                Text(file.fileName).foregroundColor(model.isViewed(file) ? ReviewColors.secondary : ReviewColors.text)
                if depth == nil {
                    Text(file.directory.isEmpty ? "" : "  " + file.directory)
                        .foregroundColor(ReviewColors.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.head)

            Spacer(minLength: 4)

            if file.binary {
                Text("bin").foregroundColor(ReviewColors.secondary)
            } else {
                Text("+\(file.added)").foregroundColor(ReviewColors.addedText)
                Text("−\(file.removed)").foregroundColor(ReviewColors.removedText)
            }
        }
        .font(.system(size: 12))
        // In the tree, files line up under their folder's name, past the
        // folder's chevron.
        .padding(.leading, depth.map { 10 + CGFloat($0) * 14 + ($0 > 0 ? 16 : 0) } ?? 10)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? ReviewColors.selected : hovering ? ReviewColors.hovered : .clear)
                .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { model.viewer = .diff(file.path) }
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button(model.isViewed(file) ? "Mark as Not Viewed" : "Mark as Viewed") { model.toggleViewed(file) }
            Divider()
            ReviewLayoutMenu(model: model)
        }
    }
}

private struct ReviewStatusBadge: View {
    let status: ReviewFileDiff.Status

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(ReviewColors.status(status))
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(ReviewColors.status(status).opacity(0.15)))
    }
}

// MARK: Files tab

private struct ReviewFilesList: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(ReviewColors.secondary)
                TextField("Find a file", text: $model.fileQuery)
                    .textFieldStyle(.plain)
                if !model.fileQuery.isEmpty {
                    Button { model.fileQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(ReviewColors.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ReviewColors.card)

            if model.fileQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                if model.tree.isEmpty {
                    VStack(spacing: 10) {
                        if model.treeLoading || model.loading { ProgressView().controlSize(.small) }
                        Text(model.treeLoading || model.loading ? "Listing files…" : "No files")
                            .font(.system(size: 12))
                            .foregroundColor(ReviewColors.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // List is backed by an outline view, so only the rows on
                    // screen are built, even for very large repositories.
                    List(model.tree, children: \.children) { node in
                        ReviewTreeRow(model: model, node: node)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            } else {
                List(model.filteredFiles, id: \.self) { path in
                    ReviewTreeRow(model: model, node: ReviewTreeNode(id: path, name: path, children: nil))
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct ReviewTreeRow: View {
    @ObservedObject var model: ReviewModel
    let node: ReviewTreeNode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.repo != nil ? "arrow.triangle.branch" : node.isFolder ? "folder.fill" : "doc.text")
                .font(.system(size: 11))
                .foregroundColor(node.isFolder ? ReviewColors.accent.opacity(0.8) : ReviewColors.secondary)
            Text(node.name)
                .fontWeight(node.repo != nil ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isOpen ? ReviewColors.accent : ReviewColors.text)
            Spacer(minLength: 2)
            if let status = status {
                ReviewStatusBadge(status: status)
            } else if node.isFolder, containsChanges {
                Circle().fill(ReviewColors.status(.modified)).frame(width: 5, height: 5)
            }
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !node.isFolder else { return }
            model.viewer = .file(node.id)
        }
    }

    private var isOpen: Bool { model.viewer == .file(node.id) }

    private var status: ReviewFileDiff.Status? {
        node.isFolder ? nil : model.statusByPath[node.id]
    }

    private var containsChanges: Bool {
        if let prefix = node.repo, let repo = model.repo(prefix) { return model.changeCount(repo) > 0 }
        return model.statusByPath.keys.contains { $0.hasPrefix(node.id) }
    }
}

// MARK: Viewer

private struct ReviewViewer: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.viewer {
            case .none:
                ReviewEmpty(
                    symbol: "doc.text.magnifyingglass",
                    title: model.tab == .changes ? "Pick a file" : "Pick a file to read",
                    detail: "Hover a line and click + to leave a comment for the agent.")

            case .diff(let path):
                if let file = model.file(at: path) {
                    ReviewDiffHeader(model: model, file: file)
                    content(path: path)
                } else {
                    ReviewEmpty(symbol: "checkmark.circle", title: "No longer changed", detail: path)
                }

            case .file(let path):
                ReviewFileHeader(model: model, path: path)
                content(path: path)
            }
        }
        .background(ReviewColors.background)
    }

    @ViewBuilder
    private func content(path: String) -> some View {
        if let preview = model.preview {
            ReviewPreviewPane(preview: preview)
        } else if let note = model.viewerNote, model.rows.isEmpty {
            ReviewEmpty(symbol: "doc", title: note, detail: "")
        } else {
            VStack(spacing: 0) {
                if let note = model.viewerNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(ReviewColors.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(ReviewColors.card)
                }
                ReviewCodeView(model: model, path: path)
            }
        }
    }
}

/// Files that aren't text, through Quick Look: one side, or before and
/// after when both exist.
private struct ReviewPreviewPane: View {
    let preview: ReviewPreview

    var body: some View {
        switch (preview.before, preview.after) {
        case let (before?, after?):
            HSplitView {
                side("Before", before, id: preview.id)
                side("After", after, id: preview.id)
            }
        case let (before?, nil):
            side("Deleted", before, id: preview.id)
        case let (nil, after?):
            ReviewQuickLook(url: after, id: preview.id)
        case (nil, nil):
            ReviewEmpty(symbol: "doc", title: "Nothing to preview", detail: "")
        }
    }

    private func side(_ label: String, _ url: URL, id: UUID) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ReviewColors.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ReviewColors.surface)
            ReviewQuickLook(url: url, id: id)
        }
        .frame(minWidth: 120)
    }
}

private struct ReviewQuickLook: NSViewRepresentable {
    let url: URL
    let id: UUID

    final class Coordinator {
        var id: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        if (view.previewItem as? URL) == url {
            view.refreshPreviewItem()
        } else {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

private struct ReviewDiffHeader: View {
    @ObservedObject var model: ReviewModel
    let file: ReviewFileDiff

    var body: some View {
        HStack(spacing: 8) {
            ReviewStatusBadge(status: file.status)
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            ReviewIconButton(symbol: "doc.text", help: "Open the Whole File") {
                model.tab = .files
                model.viewer = .file(file.path)
            }
            .disabled(file.status == .deleted)
            ReviewIconButton(symbol: "arrow.uturn.backward", help: "Revert This File…") { confirmRevert() }
            Toggle("Viewed", isOn: Binding(
                get: { model.isViewed(file) },
                set: { _ in model.toggleViewed(file) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ReviewColors.surface)
    }

    private func confirmRevert() {
        let alert = NSAlert()
        alert.messageText = "Revert \(file.fileName)?"
        alert.informativeText = file.status == .added || file.untracked
            ? "This new file will be moved to the Trash."
            : "Your working copy of this file goes back to how it was before these changes. This can't be undone."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.revert(file) }
    }
}

private struct ReviewFileHeader: View {
    @ObservedObject var model: ReviewModel
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundColor(ReviewColors.secondary)
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if model.statusByPath[path] != nil {
                Button("Show Changes") {
                    model.scope = .uncommitted
                    model.tab = .changes
                    model.viewer = .diff(path)
                }
                .controlSize(.small)
            }
            if let url = model.url(for: path) {
                ReviewIconButton(symbol: "arrow.up.forward.app", help: "Open in Default App") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ReviewColors.surface)
    }
}

/// The lines of a diff or file. A lazy stack, so only lines on screen are
/// laid out; long lines wrap rather than scroll sideways.
private struct ReviewCodeView: View {
    @ObservedObject var model: ReviewModel
    let path: String

    var body: some View {
        let digits = max(3, String(maxLineNumber).count)
        let gutter = CGFloat(digits) * 7.5 + 10
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    ReviewLineView(model: model, path: path, row: row, gutter: gutter)
                }
            }
            .padding(.bottom, 24)
        }
        .id(path)
    }

    private var maxLineNumber: Int {
        guard let last = model.rows.last else { return 0 }
        switch last.kind {
        case .plain(let n): return n
        case .line(let line): return max(line.old ?? 0, line.new ?? 0)
        case .hunk: return 0
        }
    }
}

private struct ReviewLineView: View {
    @ObservedObject var model: ReviewModel
    let path: String
    let row: ReviewRow
    let gutter: CGFloat

    @State private var hovering = false

    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        switch row.kind {
        case .hunk(let hunk):
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(Self.font)
                    .foregroundColor(ReviewColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if hovering, case .diff = model.viewer, let file = model.file(at: path) {
                    Button("Revert Change") { model.revert(hunk, of: file) }
                        .controlSize(.mini)
                        .help("Undo just this part of the file")
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(ReviewColors.hunkLine)
            .onHover { hovering = $0 }

        case .line(let line):
            let number = line.new ?? line.old ?? 0
            let removed = line.new == nil
            lineBody(
                old: line.old, new: line.new,
                marker: line.kind == .added ? "+" : line.kind == .removed ? "-" : " ",
                background: line.kind == .added ? ReviewColors.addedLine
                    : line.kind == .removed ? ReviewColors.removedLine : .clear,
                gutterBackground: line.kind == .added ? ReviewColors.addedGutter
                    : line.kind == .removed ? ReviewColors.removedGutter : .clear,
                onComment: line.kind == .noNewline ? nil : { model.startComment(on: line, path: path) })
            extras(line: number, removed: removed)

        case .plain(let n):
            lineBody(
                old: nil, new: n, marker: nil, background: .clear, gutterBackground: .clear,
                onComment: { model.startComment(onFileLine: n, text: String(row.text.characters), path: path) })
            extras(line: n, removed: false)
        }
    }

    private func lineBody(old: Int?, new: Int?, marker: String?, background: Color, gutterBackground: Color,
                          onComment: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if marker != nil {
                        number(old)
                    }
                    number(new)
                }
                if hovering, let onComment {
                    Button(action: onComment) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(ReviewColors.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Comment on this line")
                    .padding(.leading, 2)
                }
            }
            .background(gutterBackground)

            if let marker {
                Text(marker)
                    .font(Self.font)
                    .foregroundColor(ReviewColors.secondary)
                    .frame(width: 14)
            } else {
                Spacer().frame(width: 8)
            }

            Text(row.text)
                .font(Self.font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(Self.font)
            .foregroundColor(ReviewColors.secondary.opacity(0.8))
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, 4)
    }

    /// Comments on this line, and the box for writing one.
    @ViewBuilder
    private func extras(line: Int, removed: Bool) -> some View {
        let comments = model.comments(at: path, line: line, removed: removed)
        if !comments.isEmpty || model.composing.map({ $0.path == path && $0.line == line && $0.removed == removed }) == true {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    ReviewCommentCard(comment: comment) { model.delete(comment) }
                }
                if let target = model.composing, target.path == path, target.line == line, target.removed == removed {
                    ReviewCommentComposer(model: model)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, gutter + 12)
            .padding(.trailing, 10)
            .background(ReviewColors.surface)
        }
    }
}

private struct ReviewCommentCard: View {
    let comment: ReviewComment
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .foregroundColor(ReviewColors.accent)
            Text(comment.text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: delete) {
                Image(systemName: "trash").foregroundColor(ReviewColors.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete Comment")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReviewColors.border))
    }
}

private struct ReviewCommentComposer: View {
    @ObservedObject var model: ReviewModel

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Tell the agent what to change here…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(2...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReviewColors.accent.opacity(0.7)))
                .focused($focused)
                .onSubmit { model.saveComment(text) }
                .onExitCommand { model.composing = nil }
            HStack(spacing: 6) {
                Text("↵ add · ⌥↵ new line · esc cancel")
                    .font(.system(size: 10))
                    .foregroundColor(ReviewColors.secondary)
                Spacer()
                Button("Cancel") { model.composing = nil }
                    .controlSize(.small)
                Button("Add Comment") { model.saveComment(text) }
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: Footer

private struct ReviewFooter: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        HStack(spacing: 8) {
            TextField("Note for the agent (optional)", text: $model.note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(ReviewColors.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReviewColors.border))

            Button {
                model.sendToAgent()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text(model.comments.isEmpty ? "Send" : "Send \(model.comments.count)")
                }
            }
            .controlSize(.regular)
            .disabled(!model.canSend)
            .help("Type the comments into the agent's prompt. Read them over, then press Return there.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ReviewColors.surface)
    }
}
