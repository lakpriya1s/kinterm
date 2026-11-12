import AppKit
import Combine
import SwiftUI
import UserNotifications

/// A summary of the agents in every window, shown outside the windows: a
/// count on the dock icon and an item in the menu bar. See
/// scope/designs/04-notifications.md.
final class AgentSummary: NSObject, NSMenuDelegate {
    static let shared = AgentSummary()

    /// One tab with an agent in it.
    struct Entry {
        let controller: BaseTerminalController
        let status: Ghostty.Action.ProgramStatus
    }

    private(set) var entries: [Entry] = []

    /// Agents that need the user: waiting on them, or done and not yet seen.
    var attentionCount: Int {
        entries.filter { $0.status.state == .blocked || $0.status.state == .done }.count
    }

    private var statusItem: NSStatusItem?

    /// The status item's menu. Kept for the item's life and filled as it
    /// opens: swapping or removing the menu while it's open orphans it, and
    /// AppKit leaves it stranded at the screen edge.
    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    /// While the menu is open the status item is left alone, and caught up
    /// when it closes.
    private var statusMenuOpen = false

    private var cancellables: Set<AnyCancellable> = []

    /// Start following changes. Safe to call more than once.
    func start() {
        guard cancellables.isEmpty else { return }
        let closes = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).map { _ in () }
        Publishers.Merge(AgentTabBarModel.changesPublisher, closes)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        addViewMenuItem()
        update()
    }

    /// "Agent Tab Bar" and "Agents in Menu Bar" in the View menu, so both
    /// can always be changed back: with native tabs there's no face bar to
    /// right-click, and a hidden summary has no menu of its own.
    private var positionItems: [(item: NSMenuItem, position: AgentTabBarSettings.Position)] = []

    /// "Agent Face Style" in the View menu: the faces show in native tabs
    /// too, where there's no face bar to right-click.
    private var faceStyleItems: [(item: NSMenuItem, style: AgentTabBarSettings.FaceStyle)] = []

    /// The menu bar choices: hidden (nil) or a style. In the View menu and
    /// the summary's own menu.
    private var menuBarItems: [(item: NSMenuItem, style: AgentTabBarSettings.MenuBarStyle?)] = []

    private func addViewMenuItem() {
        guard positionItems.isEmpty,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        view.addItem(.separator())

        let positions = NSMenu(title: "Agent Tab Bar")
        for position in AgentTabBarSettings.Position.allCases {
            let item = NSMenuItem(title: position.label, action: #selector(choosePosition(_:)), keyEquivalent: "")
            item.target = self
            positions.addItem(item)
            positionItems.append((item, position))
        }
        let positionMenu = NSMenuItem(title: "Agent Tab Bar", action: nil, keyEquivalent: "")
        positionMenu.submenu = positions
        view.addItem(positionMenu)

        let faceStyles = NSMenu(title: "Agent Face Style")
        for style in AgentTabBarSettings.FaceStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(chooseFaceStyle(_:)), keyEquivalent: "")
            item.target = self
            faceStyles.addItem(item)
            faceStyleItems.append((item, style))
        }
        let faceStyleMenu = NSMenuItem(title: "Agent Face Style", action: nil, keyEquivalent: "")
        faceStyleMenu.submenu = faceStyles
        view.addItem(faceStyleMenu)

        let menuBar = NSMenuItem(title: "Agents in Menu Bar", action: nil, keyEquivalent: "")
        menuBar.submenu = menuBarMenu(tracked: true)
        view.addItem(menuBar)

        view.addItem(AgentSounds.shared.menuItem())
    }

    /// Hidden, Full, Compact, Icon Only. `tracked` items get their check mark
    /// kept up to date; the summary's own menu is rebuilt on every update.
    private func menuBarMenu(tracked: Bool) -> NSMenu {
        let settings = AgentTabBarSettings.shared
        let menu = NSMenu(title: "Agents in Menu Bar")
        let choices: [(String, AgentTabBarSettings.MenuBarStyle?)] =
            [("Hidden", nil)] + AgentTabBarSettings.MenuBarStyle.allCases.map { ($0.label, $0) }
        for (title, style) in choices {
            let item = NSMenuItem(title: title, action: #selector(chooseMenuBarStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style?.rawValue
            let current = settings.showsMenuBarSummary ? settings.menuBarStyle : nil
            item.state = current == style ? .on : .off
            menu.addItem(item)
            if tracked { menuBarItems.append((item, style)) }
        }
        return menu
    }

    @objc private func chooseMenuBarStyle(_ sender: NSMenuItem) {
        let settings = AgentTabBarSettings.shared
        guard let raw = sender.representedObject as? String,
              let style = AgentTabBarSettings.MenuBarStyle(rawValue: raw) else {
            settings.showsMenuBarSummary = false
            return
        }
        settings.menuBarStyle = style
        settings.showsMenuBarSummary = true
    }

    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let position = positionItems.first(where: { $0.item === sender })?.position else { return }
        AgentTabBarSettings.shared.position = position
    }

    @objc private func chooseFaceStyle(_ sender: NSMenuItem) {
        guard let style = faceStyleItems.first(where: { $0.item === sender })?.style else { return }
        AgentTabBarSettings.shared.faceStyle = style
    }

    func update() {
        entries = NSApp.windows
            .filter(\.isVisible)
            .compactMap { $0.windowController as? BaseTerminalController }
            .compactMap { controller in
                guard let status = controller.programStatus, status.state != .clear else { return nil }
                return Entry(controller: controller, status: status)
            }
            .sorted { $0.status.state.urgency > $1.status.state.urgency }

        (NSApp.delegate as? AppDelegate)?.syncDockBadge()
        updateDockIcon()
        let settings = AgentTabBarSettings.shared
        let current = settings.showsMenuBarSummary ? settings.menuBarStyle : nil
        for (item, style) in menuBarItems {
            item.state = current == style ? .on : .off
        }
        for (item, position) in positionItems {
            item.state = AgentTabBarSettings.shared.position == position ? .on : .off
        }
        for (item, style) in faceStyleItems {
            item.state = settings.faceStyle == style ? .on : .off
        }
        updateStatusItem()
    }

    // MARK: Dock icon

    /// The state the dock icon shows, so it's only redrawn when that changes.
    private var dockIconState: Ghostty.Action.ProgramStatus.State?

    /// The app icon is a status light: its face takes the color and
    /// expression of the agent that needs the user most. Idle agents leave the normal icon, as
    /// does a custom `macos-icon`.
    private func updateDockIcon() {
        let official = (NSApp.delegate as? AppDelegate)?.ghostty.config.macosIcon == .official
        let state = official ? entries.first?.status.state : nil
        let shown: Ghostty.Action.ProgramStatus.State? = switch state {
        case .working, .blocked, .done, .error: state
        default: nil
        }
        guard shown != dockIconState else { return }
        dockIconState = shown
        // Updates arrive on the main run loop.
        MainActor.assumeIsolated {
            NSApp.applicationIconImage = shown.flatMap {
                KinTermAppIcon.image(front: AgentFaceView.color(for: $0), expression: Self.dockExpression(for: $0))
            }
        }
    }

    private static func dockExpression(for state: Ghostty.Action.ProgramStatus.State) -> KinTermMark.Expression {
        switch state {
        case .working: return .working
        case .blocked: return .waiting
        case .done: return .done
        case .error: return .error
        case .idle, .clear: return .prompt
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard !statusMenuOpen else { return }
        let settings = AgentTabBarSettings.shared
        guard settings.showsMenuBarSummary, !entries.isEmpty else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.attributedTitle = title(style: settings.menuBarStyle)
        item.button?.toolTip = title(style: .full).string
        if item.menu !== statusMenu { item.menu = statusMenu }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        fill(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu { statusMenuOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusMenuOpen = false
        // After the close, so the item isn't removed under the closing menu.
        DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
    }

    /// With each dot in its state's color, only states that have agents:
    /// full "● 1 waiting  ● 1 working" (the design), compact "●1 ●1", or one
    /// dot for the most urgent state.
    private func title(style: AgentTabBarSettings.MenuBarStyle) -> NSAttributedString {
        let counts: [(Ghostty.Action.ProgramStatus.State, String)] = [
            (.blocked, "waiting"), (.error, "error"), (.done, "done"), (.working, "working"), (.idle, "idle"),
        ]
        let font = NSFont.menuBarFont(ofSize: 0)
        let dotFont = NSFont.systemFont(ofSize: font.pointSize * 0.8)
        let result = NSMutableAttributedString()
        func dot(_ state: Ghostty.Action.ProgramStatus.State) -> NSAttributedString {
            NSAttributedString(string: style == .compact ? "●" : "● ", attributes: [
                .font: dotFont,
                .foregroundColor: NSColor(AgentFaceView.color(for: state)),
                .baselineOffset: 1,
            ])
        }

        if style == .icon {
            // Entries are sorted most urgent first.
            if let state = entries.first?.status.state { result.append(dot(state)) }
            return result
        }

        for (state, word) in counts {
            let count = entries.filter { $0.status.state == state }.count
            guard count > 0 else { continue }
            if result.length > 0 {
                result.append(NSAttributedString(string: style == .compact ? " " : "  ", attributes: [.font: font]))
            }
            result.append(dot(state))
            let text = style == .compact ? "\(count)" : "\(count) \(word)"
            result.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        return result
    }

    /// One card per agent, most urgent first. Choosing one jumps to its tab
    /// and split.
    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in entries {
            let row = NSMenuItem()
            let controller = entry.controller
            let card = AgentSummaryCard(entry: entry) { [weak row] in
                row?.menu?.cancelTracking()
                // Let the menu close before moving focus.
                DispatchQueue.main.async { Self.focus(controller) }
            }
            let view = NSHostingView(rootView: card)
            view.setFrameSize(view.fittingSize)
            row.view = view
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let style = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        style.submenu = menuBarMenu(tracked: false)
        style.toolTip = "Also in View › Agents in Menu Bar"
        menu.addItem(style)
    }

    /// Bring a tab forward and focus the split whose agent it shows.
    static func focus(_ controller: BaseTerminalController) {
        let target = controller.programStatus
        let surface = controller.surfaceTree.first { $0.programStatus == target } ?? controller.focusedSurface
        controller.window?.tabGroup?.selectedWindow = controller.window
        if let surface {
            controller.focusSurface(surface)
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

}

/// One agent in the menu bar summary's menu: its face, the tab title, the
/// state and for how long, what it's doing, and its account, folder and
/// branch. Uses the menu's own text colors, so it reads in light and dark.
private struct AgentSummaryCard: View {
    let entry: AgentSummary.Entry
    let action: () -> Void

    @State private var hovering = false

    private var status: Ghostty.Action.ProgramStatus { entry.status }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Moving, as in the tabs: the menu is only open while someone
            // is looking at it.
            AgentFaceView(
                state: status.state, size: 26, background: .clear, motion: .all,
                agents: entry.controller.agentCount, shells: entry.controller.shellCount)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    (Text(status.stateLabel)
                        .foregroundColor(AgentFaceView.color(for: status.state))
                        .fontWeight(.medium)
                     + Text(" · \(elapsed(now: context.date))").foregroundColor(.secondary))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                }

                if let msg = status.msg {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(account?.swiftUIColor ?? Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(footer)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.1) : .clear))
        .padding(.horizontal, 5)
        .frame(width: 320, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }

    private var title: String {
        let title = entry.controller.window?.title ?? ""
        return title.isEmpty ? status.appDisplayName : title
    }

    private var account: AgentAccount? {
        status.account.map { AgentAccountStore.shared.account(for: $0, app: status.app) }
    }

    /// "2m 14s" working, "1m" otherwise, as in the Agents panel.
    private func elapsed(now: Date) -> String {
        AgentTime.duration(from: status.since, to: now, seconds: status.state == .working)
    }

    /// "work · ~/code/api · feat/nav".
    private var footer: String {
        let pwd = entry.controller.focusedSurface?.pwd
        let folder = pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let branch = AgentGitBranch.shared.branch(at: pwd)
        let who = account?.label ?? status.appDisplayName
        return [who, folder, branch].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The image on an agent notification: the agent's face in that state, in
/// the chosen face set, on a dark rounded square. macOS always shows the app
/// icon on a notification, so the face goes in as an attachment.
@MainActor
enum AgentNotificationIcon {
    static func attachment(for state: Ghostty.Action.ProgramStatus.State) -> UNNotificationAttachment? {
        guard let png = image(for: state) else { return nil }

        // The system moves the file into its own store, so each notification
        // needs its own copy.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinterm-agent-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "agent-icon", url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// A 40pt square at 3x with the face still, so the thumbnail shows the
    /// same face as the tab.
    private static func image(for state: Ghostty.Action.ProgramStatus.State) -> Data? {
        let tile = AgentTabBarColors.notificationIcon
        let content = ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tile)
            AgentFaceView(state: state, size: 26, background: tile, motion: .none)
        }
        .frame(width: 40, height: 40)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
