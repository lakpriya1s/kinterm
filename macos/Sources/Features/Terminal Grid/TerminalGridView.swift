import SwiftUI

/// Every tab of a window as a tile in one grid. Each tile is the tab's own
/// split tree, live and interactive, under a small header with the tab's
/// face, title and buttons. See `TerminalGridModel`.
struct TerminalGridView: View {
    /// The tabs, in tab order.
    let controllers: [BaseTerminalController]

    /// The host window's tab bar model, for each tab's title, face, color
    /// and shortcut. Nil when the window has no agent tab bar.
    let tabBar: AgentTabBarModel?

    /// The terminal with the keyboard, anywhere in the grid.
    let focusedSurface: Ghostty.SurfaceView?

    /// The grid's review tiles (⌘⇧R), one per tab. See `ReviewCenter`.
    @ObservedObject private var review = ReviewCenter.shared

    /// The grid's browser tiles (⌘⇧B), one per tab. See `BrowserCenter`.
    @ObservedObject private var browsers = BrowserCenter.shared

    private static let gap: CGFloat = 6

    /// A tile: a tab, a tab's review, a browser, or a browser's DevTools.
    private enum Item: Hashable {
        case tab(BaseTerminalController)
        case review(BaseTerminalController)
        case browser(BrowserPage)
        case devTools(BrowserPage)

        private var key: (Int, ObjectIdentifier) {
            switch self {
            case .tab(let controller): return (0, ObjectIdentifier(controller))
            case .review(let controller): return (1, ObjectIdentifier(controller))
            case .browser(let page): return (2, ObjectIdentifier(page))
            case .devTools(let page): return (3, ObjectIdentifier(page))
            }
        }

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) {
            hasher.combine(key.0)
            hasher.combine(key.1)
        }
    }

    var body: some View {
        let window = controllers.first?.window
        let reviewed = review.gridReviewControllers(for: window)
        let pages = browsers.gridPages(for: window)
        let items = controllers.map(Item.tab)
            + reviewed.map(Item.review)
            + pages.flatMap { page in [Item.browser(page)] + (page.devTools == .docked ? [Item.devTools(page)] : []) }
        let count = items.count
        // As square as possible, wider than tall: 2 → 2×1, 3–4 → 2×2,
        // 5–6 → 3×2, 7–9 → 3×3.
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        let rows = max(1, (count + columns - 1) / columns)

        VStack(spacing: Self.gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(items[(row * columns)..<min(count, (row + 1) * columns)], id: \.self) { item in
                        switch item {
                        case .tab(let controller):
                            TerminalGridTile(
                                controller: controller,
                                tab: tab(for: controller),
                                isFocused: focusedSurface.map { controller.surfaceTree.contains($0) } ?? false)
                        case .review(let controller):
                            if let window {
                                ReviewGridTile(
                                    model: review.model(for: controller),
                                    controller: controller,
                                    tab: tab(for: controller),
                                    window: window)
                            }
                        case .browser(let page):
                            BrowserGridTile(page: page, tab: browsers.owner(of: page).flatMap(tab(for:)))
                        case .devTools(let page):
                            DevToolsGridTile(page: page)
                        }
                    }
                }
            }
        }
        .padding(Self.gap)
        .background(AgentTabBarColors.bar)
    }

    private func tab(for controller: BaseTerminalController) -> AgentTab? {
        guard let window = controller.window else { return nil }
        return tabBar?.tabs.first { $0.id == ObjectIdentifier(window) }
    }
}

/// One tab in the grid.
private struct TerminalGridTile: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var controller: BaseTerminalController
    let tab: AgentTab?
    let isFocused: Bool

    @ObservedObject private var attention = TerminalGridAttention.shared

    private var accent: Color { tab?.color ?? Color.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            TerminalGridTileHeader(
                title: tab?.title ?? controller.window?.title ?? "",
                status: tab?.status,
                shortcut: tab?.shortcut,
                color: tab?.color,
                isFocused: isFocused,
                onFocus: { TerminalGridModel.shared.focus(controller) },
                onExpand: expand,
                onClose: { (controller as? TerminalController)?.closeTab(nil) })

            TerminalSplitTreeView(
                tree: controller.surfaceTree,
                action: { controller.performSplitAction($0) })
                .overlay {
                    // Dim the tiles without the keyboard, like unfocused splits.
                    if !isFocused, ghostty.config.unfocusedSplitOpacity > 0 {
                        Rectangle()
                            .fill(ghostty.config.unfocusedSplitFill)
                            .opacity(ghostty.config.unfocusedSplitOpacity)
                            .allowsHitTesting(false)
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isFocused ? accent : AgentTabBarColors.border, lineWidth: isFocused ? 2 : 1)
                .allowsHitTesting(false))
        .overlay {
            if let pulse = attention.pulsing, pulse.id == ObjectIdentifier(controller) {
                TerminalGridPulse(color: accent, reason: pulse.reason)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab?.title ?? "Tab")
    }

    /// Back to tabs, with this one selected.
    private func expand() {
        guard let window = controller.window else { return }
        TerminalGridModel.shared.exit(for: window, selecting: controller)
    }
}

/// A review tile (⌘⇧R): the changes of the tab it was opened for. See
/// `ReviewCenter`.
private struct ReviewGridTile: View {
    @ObservedObject var model: ReviewModel
    let controller: BaseTerminalController
    let tab: AgentTab?
    let window: NSWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                Text("Review")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                if let color = tab?.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                AgentTabFaceView(status: tab?.status)
                Text(tab?.title ?? model.tabTitle)
                    .font(.system(size: 11))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("⌘⇧R")
                    .font(.system(size: 10))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                TerminalGridHeaderButton(symbol: "macwindow.on.rectangle", help: "Open Review in Its Own Window") {
                    ReviewCenter.shared.popOutGridReview(of: controller, in: window)
                }
                TerminalGridHeaderButton(symbol: "xmark", help: "Close Review (⌘⇧R)") {
                    ReviewCenter.shared.closeGridReview(of: controller, in: window)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AgentTabBarColors.card)
            .help("Reviews \(tab?.title ?? model.tabTitle)")

            ReviewView(model: model, presentation: .tile, close: {
                ReviewCenter.shared.closeGridReview(of: controller, in: window)
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AgentTabBarColors.border, lineWidth: 1)
                .allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
    }
}

/// A browser tile (⌘⇧B), opened for a tab. See `BrowserCenter`.
private struct BrowserGridTile: View {
    @ObservedObject var page: BrowserPage
    let tab: AgentTab?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                Text("Browser")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                if let color = tab?.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(page.displayTitle)
                    .font(.system(size: 11))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("⌘⇧B")
                    .font(.system(size: 10))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                TerminalGridHeaderButton(symbol: "macwindow.on.rectangle", help: "Open Browser in Its Own Window") {
                    BrowserCenter.shared.popOut(page)
                }
                TerminalGridHeaderButton(symbol: "xmark", help: "Close Browser (⌘⇧B)") {
                    BrowserCenter.shared.closeGridTile(page)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AgentTabBarColors.card)

            BrowserView(page: page, placement: .tile, close: {
                BrowserCenter.shared.closeGridTile(page)
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AgentTabBarColors.border, lineWidth: 1)
                .allowsHitTesting(false))
        .onDisappear { BrowserCenter.shared.gridTileDisappeared(page) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
    }
}

/// The browser tile's DevTools, a tile of their own. See `BrowserCenter`.
private struct DevToolsGridTile: View {
    @ObservedObject var page: BrowserPage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                Text("DevTools")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                Text(page.displayTitle)
                    .font(.system(size: 11))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("⌥⌘I")
                    .font(.system(size: 10))
                    .foregroundColor(AgentTabBarColors.cardMuted)
                TerminalGridHeaderButton(symbol: "macwindow.on.rectangle", help: "Open DevTools in Their Own Window") {
                    page.showDevTools(docked: false)
                }
                TerminalGridHeaderButton(symbol: "xmark", help: "Close DevTools (⌥⌘I)") {
                    page.closeDevTools()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AgentTabBarColors.card)

            BrowserDevTools(page: page, showsHeader: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AgentTabBarColors.border, lineWidth: 1)
                .allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DevTools")
    }
}

private struct TerminalGridTileHeader: View {
    let title: String
    let status: Ghostty.Action.ProgramStatus?
    let shortcut: String?
    let color: Color?
    let isFocused: Bool
    let onFocus: () -> Void
    let onExpand: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 7, height: 7)
            }

            AgentTabFaceView(status: status)

            Text(title.isEmpty ? "Terminal" : title)
                .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                .foregroundColor(isFocused ? AgentTabBarColors.cardTitle : AgentTabBarColors.cardMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundColor(AgentTabBarColors.cardMuted)
            }

            TerminalGridHeaderButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Show This Tab Only", action: onExpand)
            TerminalGridHeaderButton(symbol: "xmark", help: "Close Tab", action: onClose)
                .opacity(hovering ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isFocused ? AgentTabBarColors.selected : AgentTabBarColors.card)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onExpand)
        .onTapGesture(count: 1, perform: onFocus)
        .help("Double-click to show only this tab")
    }
}

private struct TerminalGridHeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(hovering ? AgentTabBarColors.cardTitle : AgentTabBarColors.cardMuted)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
