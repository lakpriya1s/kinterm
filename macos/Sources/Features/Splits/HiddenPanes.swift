import AppKit

// A pane you'd rather not see, such as the dev server an agent started with
// `kinterm-ctl run`, can be hidden from its right-click menu: it leaves the
// splits but keeps running, and agents still read its output. Right-click
// any terminal in the tab to show it again where it was. Closing the tab
// ends it with the rest.

/// A pane taken out of a tab's splits that still runs.
struct HiddenPane {
    let view: Ghostty.SurfaceView
    /// The pane it was split from, to go back beside.
    weak var anchor: Ghostty.SurfaceView?
    /// Which side of `anchor` it was on, and the split's ratio.
    let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
    let ratio: Double

    /// What the menu calls it: the name an agent gave it, or its title.
    @MainActor
    var name: String {
        if let worker = AgentWorkers.shared.worker(for: view) { return worker.name }
        let title = view.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Terminal" : title
    }
}

extension BaseTerminalController {
    /// Take `view` out of the splits without ending it. Not the last pane:
    /// there'd be nothing left to show it from.
    @MainActor
    func hidePane(_ view: Ghostty.SurfaceView) {
        guard let root = surfaceTree.root,
              let parent = root.parentSplit(of: view),
              case .split(let split) = parent else { return }
        let first = split.left == .leaf(view: view)
        let sibling = first ? split.right : split.left
        let anchor = first ? sibling.leftmostLeaf() : sibling.rightmostLeaf()
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch (split.direction, first) {
        case (.horizontal, true): .left
        case (.horizontal, false): .right
        case (.vertical, true): .up
        case (.vertical, false): .down
        }
        hiddenPanes.append(HiddenPane(view: view, anchor: anchor, direction: direction, ratio: split.ratio))
        // Not through replaceSurfaceTree: undo would put it back while
        // it's still listed as hidden.
        surfaceTree = surfaceTree.removing(.leaf(view: view))
        if focusedSurface === view || focusedSurface == nil {
            focusSurface(anchor)
        }
    }

    /// Put a hidden pane back where it was, or beside the focused pane if
    /// that one's gone.
    @MainActor
    func showPane(_ view: Ghostty.SurfaceView) {
        guard let index = hiddenPanes.firstIndex(where: { $0.view === view }) else { return }
        let pane = hiddenPanes[index]
        let anchor = pane.anchor.flatMap { surfaceTree.contains($0) ? $0 : nil }
            ?? focusedSurface.flatMap { surfaceTree.contains($0) ? $0 : nil }
            ?? surfaceTree.first { _ in true }
        guard let anchor, let tree = try? surfaceTree.inserting(view: view, at: anchor, direction: pane.direction) else {
            return
        }
        hiddenPanes.remove(at: index)
        surfaceTree = tree
        resizeSplit(around: view, to: pane.ratio)
    }

    /// Forget a hidden pane, which ends it once nothing else holds it.
    /// Returns whether it was hidden here.
    @MainActor
    @discardableResult
    func dropHiddenPane(_ view: Ghostty.SurfaceView) -> Bool {
        guard let index = hiddenPanes.firstIndex(where: { $0.view === view }) else { return false }
        hiddenPanes.remove(at: index)
        return true
    }

    /// The tab's panes, shown or hidden.
    var allSurfaces: [Ghostty.SurfaceView] {
        Array(surfaceTree) + hiddenPanes.map(\.view)
    }

    /// The tab hiding `view`, if one is.
    @MainActor
    static func controller(hiding view: Ghostty.SurfaceView) -> BaseTerminalController? {
        NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .first { $0.hiddenPanes.contains { $0.view === view } }
    }

    // MARK: Menu

    /// "Hide Pane" for `view` when it's one of several, and "Show …" for
    /// each hidden one.
    @MainActor
    func addPaneVisibilityItems(to menu: NSMenu, for view: Ghostty.SurfaceView) {
        if surfaceTree.root?.parentSplit(of: view) != nil {
            let item = menu.addItem(withTitle: "Hide Pane", action: #selector(hidePaneFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = view
            item.setImageIfDesired(systemSymbolName: "eye.slash")
        }
        for pane in hiddenPanes {
            let item = menu.addItem(
                withTitle: "Show \u{201C}\(pane.name)\u{201D}",
                action: #selector(showPaneFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = pane.view
            item.setImageIfDesired(systemSymbolName: "eye")
        }
    }

    @objc private func hidePaneFromMenu(_ sender: NSMenuItem) {
        guard let view = sender.representedObject as? Ghostty.SurfaceView else { return }
        MainActor.assumeIsolated { hidePane(view) }
    }

    @objc private func showPaneFromMenu(_ sender: NSMenuItem) {
        guard let view = sender.representedObject as? Ghostty.SurfaceView else { return }
        MainActor.assumeIsolated { showPane(view) }
    }
}
