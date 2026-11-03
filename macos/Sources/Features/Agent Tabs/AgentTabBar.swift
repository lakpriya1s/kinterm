import AppKit
import Combine
import SwiftUI

// The face tab bar. See scope/designs/01-window-face-tabs.md for the design
// this matches.

/// The design's colors for the tab bar and hover card.
enum AgentTabBarColors {
    static let bar = Color(agentHex: 0x22242a)
    static let border = Color(agentHex: 0x2e3038)
    static let selected = Color(agentHex: 0x363944)
    static let hovered = Color(agentHex: 0x2c2e35)
    static let plusBorder = Color(agentHex: 0x4a4e59)
    static let plusBorderHovered = Color(agentHex: 0x8a8f99)
    static let plusText = Color(agentHex: 0xa8adb7)
    static let plusTextHovered = Color(agentHex: 0xf1f2f4)

    static let card = Color(agentHex: 0x24262d)
    static let cardBorder = Color(agentHex: 0x3a3d47)
    static let cardTitle = Color(agentHex: 0xf1f2f4)
    static let cardText = Color(agentHex: 0xc2c6cf)
    static let cardMuted = Color(agentHex: 0x8a8f99)
    static let shellAccount = Color(agentHex: 0x4a4e59)
    static let cardInset = Color(agentHex: 0x1c1d21)
    static let cardQuote = Color(agentHex: 0xa8adb7)
    static let contextTrack = Color(agentHex: 0x3a3d47)
    static let contextBar = Color(agentHex: 0x7db4ff)
    static let contextBarHigh = Color(agentHex: 0xf5a524)
    static let notificationIcon = Color(agentHex: 0x101114)

    /// `color` laid over `base` at `fraction`, as one opaque color. Used to
    /// tint a tab with its account color and still cut the unread dot out of
    /// the right color.
    static func blend(_ base: Color, _ color: Color, _ fraction: CGFloat) -> Color {
        let base = NSColor(base).usingColorSpace(.sRGB) ?? .black
        let color = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return Color(nsColor: base.blended(withFraction: fraction, of: color) ?? base)
    }

    /// The state label's color in the hover card.
    static func label(for state: Ghostty.Action.ProgramStatus.State?) -> Color {
        switch state {
        case .working: return Color(agentHex: 0x7db4ff)
        case .blocked: return Color(agentHex: 0xf5a524)
        case .done: return Color(agentHex: 0x3fb950)
        case .error: return Color(agentHex: 0xff7b72)
        case .idle, .clear, nil: return Color(agentHex: 0xa8adb7)
        }
    }
}

/// Where the agent tab bar is shown and how big its faces are. Shared by all
/// windows and kept across launches.
final class AgentTabBarSettings: ObservableObject {
    static let shared = AgentTabBarSettings()

    enum Position: String, CaseIterable {
        /// A row of faces above the terminal.
        case top

        /// A row of faces in the title bar, next to the window buttons, with
        /// the selected tab's title after them. Windows whose style can't do
        /// that show `top` instead.
        case titleBar

        /// A row of faces below the terminal.
        case bottom

        /// A column of faces to the left of the terminal.
        case left

        /// A column of faces to the right of the terminal.
        case right

        /// The standard macOS tab bar, with a small face on each tab.
        case native

        var label: String {
            switch self {
            case .top: return "Top"
            case .titleBar: return "Title Bar"
            case .bottom: return "Bottom"
            case .left: return "Left"
            case .right: return "Right"
            case .native: return "Native macOS Tabs"
            }
        }
    }

    /// How a tab shows its agent's account color.
    enum AccountStyle: String, CaseIterable {
        /// The tab's background is tinted with it.
        case background

        /// A ring around the face, as in the original design.
        case ring

        var label: String {
            switch self {
            case .background: return "Tab Background"
            case .ring: return "Ring"
            }
        }
    }

    enum FaceSize: String, CaseIterable {
        case small
        case medium
        case large

        /// The design's scale for each size, applied to a 40pt face.
        var scale: CGFloat {
            switch self {
            case .small: return 0.8
            case .medium: return 1
            case .large: return 1.25
            }
        }

        var label: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            }
        }
    }

    /// Which set of faces to draw. See scope/designs/06-face-sets.md.
    enum FaceStyle: String, CaseIterable {
        /// Faces with eyes and a mouth, the original design.
        case faces

        /// The faces on rounded-square heads, like the KinTerm logo.
        case squares

        /// A glowing dot; motion does the talking.
        case orbs

        /// A silhouette per state, like road signs.
        case shapes

        /// Robot heads with an antenna lamp.
        case bots

        /// One asterisk that changes form.
        case spark

        var label: String {
            switch self {
            case .faces: return "Faces"
            case .squares: return "Square Faces"
            case .orbs: return "Orbs"
            case .shapes: return "Shapes"
            case .bots: return "Bots"
            case .spark: return "Spark"
            }
        }
    }

    private static let positionKey = "AgentTabBarPosition"
    private static let faceSizeKey = "AgentTabBarFaceSize"
    private static let faceStyleKey = "AgentFaceStyle"
    private static let dockBadgeKey = "AgentDockBadge"
    private static let accountStyleKey = "AgentAccountStyle"
    private static let menuBarKey = "AgentMenuBarSummary"
    private static let menuBarStyleKey = "AgentMenuBarStyle"

    /// How much room the menu bar summary takes.
    enum MenuBarStyle: String, CaseIterable {
        /// "●1 ●1": colored dots and counts. The default.
        case compact

        /// "● 1 waiting  ● 1 working", as in the design.
        case full

        /// One dot in the color of the most urgent state.
        case icon

        var label: String {
            switch self {
            case .full: return "Full"
            case .compact: return "Compact"
            case .icon: return "Icon Only"
            }
        }
    }

    @Published var position: Position {
        didSet {
            UserDefaults.ghostty.set(position.rawValue, forKey: Self.positionKey)
            AgentTabBarModel.setNeedsRefresh()
        }
    }

    @Published var faceSize: FaceSize {
        didSet { UserDefaults.ghostty.set(faceSize.rawValue, forKey: Self.faceSizeKey) }
    }

    @Published var faceStyle: FaceStyle {
        didSet {
            UserDefaults.ghostty.set(faceStyle.rawValue, forKey: Self.faceStyleKey)
            AgentSummary.shared.update()
        }
    }

    @Published var accountStyle: AccountStyle {
        didSet { UserDefaults.ghostty.set(accountStyle.rawValue, forKey: Self.accountStyleKey) }
    }

    /// Count agents waiting on you or done and unseen on the dock icon.
    @Published var showsDockBadge: Bool {
        didSet {
            UserDefaults.ghostty.set(showsDockBadge, forKey: Self.dockBadgeKey)
            AgentSummary.shared.update()
        }
    }

    /// Show "● 1 waiting ● 1 working" in the menu bar while agents run.
    @Published var showsMenuBarSummary: Bool {
        didSet {
            UserDefaults.ghostty.set(showsMenuBarSummary, forKey: Self.menuBarKey)
            AgentSummary.shared.update()
        }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet {
            UserDefaults.ghostty.set(menuBarStyle.rawValue, forKey: Self.menuBarStyleKey)
            AgentSummary.shared.update()
        }
    }

    /// Whether our own tab bar replaces the native one.
    var replacesNativeTabBar: Bool { position != .native }

    private init() {
        position = UserDefaults.ghostty.string(forKey: Self.positionKey)
            .flatMap(Position.init(rawValue:)) ?? .top
        faceSize = UserDefaults.ghostty.string(forKey: Self.faceSizeKey)
            .flatMap(FaceSize.init(rawValue:)) ?? .medium
        faceStyle = UserDefaults.ghostty.string(forKey: Self.faceStyleKey)
            .flatMap(FaceStyle.init(rawValue:)) ?? .faces
        accountStyle = UserDefaults.ghostty.string(forKey: Self.accountStyleKey)
            .flatMap(AccountStyle.init(rawValue:)) ?? .background
        showsDockBadge = UserDefaults.ghostty.object(forKey: Self.dockBadgeKey) as? Bool ?? true
        showsMenuBarSummary = UserDefaults.ghostty.object(forKey: Self.menuBarKey) as? Bool ?? true
        menuBarStyle = UserDefaults.ghostty.string(forKey: Self.menuBarStyleKey)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .compact
    }
}

/// One tab as shown in the agent tab bar.
struct AgentTab: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
    let status: Ghostty.Action.ProgramStatus?
    let isSelected: Bool

    /// The keyboard shortcut that selects this tab, e.g. "⌘1".
    let shortcut: String?

    /// The focused terminal's working directory.
    let pwd: String?

    /// The git branch of `pwd`, if it's in a repository.
    let branch: String?

    /// When the tab was opened.
    let openedAt: Date

    /// The account the agent in this tab reported, if any.
    let account: AgentAccount?

    /// Subagents working for the agent in this tab.
    let subagents: Int

    /// Agents in this tab's splits.
    let agents: Int

    /// Shells the agents in this tab have left running in the background.
    let shells: Int

    /// The color the user gave this tab, if any.
    let color: Color?
}

/// The tabs of one window's tab group, kept up to date for the agent tab bar.
///
/// Tabs are still native macOS window tabs, so everything that works with tabs
/// (shortcuts, menus, dragging windows together, restoring) keeps working. This
/// only replaces how they're drawn.
final class AgentTabBarModel: ObservableObject {
    @Published private(set) var tabs: [AgentTab] = []

    /// Whether the window put the bar in its title bar. See
    /// `TerminalWindow.agentTabBarInTitlebar`.
    @Published private(set) var inTitlebar = false

    /// Which faces animate: all of them while KinTerm is active, only the
    /// ones that need attention while it's in the background, none while
    /// the window can't be seen.
    @Published private(set) var faceMotion: AgentFaceView.Motion = .all

    /// Whether the window shows its tabs in a grid. See `TerminalGridModel`.
    @Published private(set) var gridActive = false

    private weak var controller: BaseTerminalController?
    private var windows: [ObjectIdentifier: Weak<NSWindow>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Anything that changes what any tab bar shows calls `setNeedsRefresh`,
    /// and every tab bar refreshes. There are only ever a handful of tabs.
    private static let changes = PassthroughSubject<Void, Never>()

    static func setNeedsRefresh() {
        changes.send()
    }

    /// Fires on every `setNeedsRefresh`, for anything else that summarizes tabs.
    static var changesPublisher: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    init(controller: BaseTerminalController) {
        self.controller = controller

        let center = NotificationCenter.default
        let windowChanges = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ].map { center.publisher(for: $0).map { _ in () }.eraseToAnyPublisher() }

        Publishers.MergeMany(windowChanges + [Self.changes.eraseToAnyPublisher()])
            .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    var window: NSWindow? { controller?.window }

    var terminalController: BaseTerminalController? { controller }

    func refresh() {
        guard let window = controller?.window else { return }

        // A window that closes is still in its tab group while it closes.
        let all = (window.tabbedWindows ?? [window]).filter { $0.isVisible || $0 === window }
        // In a grid every tab is on screen, so the one marked is the one
        // with the keyboard.
        let grid = TerminalGridModel.shared
        let gridActive = grid.isActive(for: window)
        let selected = (gridActive ? grid.focusedController(in: window)?.window : nil)
            ?? window.tabGroup?.selectedWindow ?? window
        if gridActive != self.gridActive { self.gridActive = gridActive }
        windows = Dictionary(uniqueKeysWithValues: all.map { (ObjectIdentifier($0), Weak($0)) })
        let newTabs = all.map { tabWindow in
            let tabController = tabWindow.windowController as? BaseTerminalController
            let status = tabController?.programStatus
            let account = status.flatMap { $0.state == .clear ? nil : $0.account }
                .map { AgentAccountStore.shared.account(for: $0) }
            return AgentTab(
                id: ObjectIdentifier(tabWindow),
                title: tabWindow.title,
                status: status,
                isSelected: tabWindow === selected,
                shortcut: (tabWindow as? TerminalWindow)?.keyEquivalent,
                pwd: tabController?.focusedSurface?.pwd,
                branch: AgentGitBranch.shared.branch(at: tabController?.focusedSurface?.pwd),
                openedAt: tabController?.createdAt ?? Date(),
                account: account,
                subagents: tabController?.subagentCount ?? 0,
                agents: tabController?.agentCount ?? 0,
                shells: tabController?.shellCount ?? 0,
                color: (tabWindow as? TerminalWindow)?.effectiveTabColor.map { Color(nsColor: $0) }
            )
        }

        if newTabs != tabs { tabs = newTabs }

        (window as? TerminalWindow)?.syncNativeTabBarVisibility()
        let inTitlebar = (window as? TerminalWindow)?.agentTabBarInTitlebar ?? false
        if inTitlebar != self.inTitlebar { self.inTitlebar = inTitlebar }

        let motion: AgentFaceView.Motion = !window.occlusionState.contains(.visible) ? .none
            : NSApp.isActive ? .all : .attention
        if motion != faceMotion { faceMotion = motion }
    }

    func select(_ tab: AgentTab) {
        guard let window = windows[tab.id]?.value else { return }

        // In a grid the tab is already on screen: just give it the keyboard.
        if TerminalGridModel.shared.isActive(for: window),
           let controller = window.windowController as? BaseTerminalController {
            TerminalGridModel.shared.focus(controller)
            return
        }

        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Show the tabs in a grid, or go back to tabs.
    func toggleGrid() {
        TerminalGridModel.shared.toggle(for: window)
    }

    func close(_ tab: AgentTab) {
        guard let window = windows[tab.id]?.value else { return }
        (window.windowController as? TerminalController)?.closeTab(nil)
    }

    /// Ask for a new title. The prompt is a sheet on the tab's window, so
    /// the tab is selected first.
    func rename(_ tab: AgentTab) {
        guard let window = windows[tab.id]?.value else { return }
        select(tab)
        (window.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    func terminalWindow(for tab: AgentTab) -> TerminalWindow? {
        windows[tab.id]?.value as? TerminalWindow
    }
}

/// Puts the agent tab bar above or beside the terminal content.
struct AgentTabBarContainer<Content: View>: View {
    let model: AgentTabBarModel?
    @ViewBuilder let content: Content

    var body: some View {
        if let model {
            AgentTabBarPlacement(model: model, content: content)
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

private struct AgentTabBarPlacement<Content: View>: View {
    @ObservedObject var model: AgentTabBarModel
    @ObservedObject private var settings = AgentTabBarSettings.shared
    let content: Content

    var body: some View {
        switch settings.position {
        case .titleBar where model.inTitlebar:
            // The window extends the content under its title bar, so the
            // bar goes up there with it.
            VStack(spacing: 0) {
                AgentTabBar(model: model, edge: .top, inTitlebar: true)
                VStack(spacing: 0) { content }
            }
            .ignoresSafeArea(.container, edges: .top)
        case .top, .titleBar:
            VStack(spacing: 0) {
                AgentTabBar(model: model, edge: .top)
                VStack(spacing: 0) { content }
            }
        case .bottom:
            VStack(spacing: 0) {
                VStack(spacing: 0) { content }
                AgentTabBar(model: model, edge: .bottom)
            }
        case .left:
            HStack(spacing: 0) {
                AgentTabBar(model: model, edge: .leading)
                VStack(spacing: 0) { content }
            }
        case .right:
            HStack(spacing: 0) {
                VStack(spacing: 0) { content }
                AgentTabBar(model: model, edge: .trailing)
            }
        case .native:
            VStack(spacing: 0) { content }
        }
    }
}

/// A row or column of faces, one per tab, followed by a new tab button.
struct AgentTabBar: View {
    @ObservedObject var model: AgentTabBarModel
    @ObservedObject private var settings = AgentTabBarSettings.shared

    /// The side of the terminal the bar is on. Its border faces the
    /// terminal, and cards and menus open away from it.
    let edge: Edge

    private var vertical: Bool { edge == .leading || edge == .trailing }

    /// In the title bar: room for the window buttons on the left, the
    /// selected tab's title after the faces, and the empty parts drag the
    /// window.
    var inTitlebar = false

    private var scale: CGFloat { settings.faceSize.scale }

    /// The face, scaled from the design's 40pt.
    private var faceSize: CGFloat { (40 * scale).rounded() }

    /// The round slot a face sits in: the face plus room for its rings.
    private var slot: CGFloat { (40 * scale + 18).rounded() }

    /// The tab button: the slot plus 5pt padding on each side.
    private var button: CGFloat { slot + 10 }

    /// Where the bar starts in the title bar: after the window buttons.
    private var windowButtonsInset: CGFloat {
        guard let zoom = model.window?.standardWindowButton(.zoomButton) else { return 78 }
        return zoom.convert(zoom.bounds, to: nil).maxX + 8
    }

    /// The width the faces and `+` need, so in the title bar the title
    /// gets the rest.
    private var facesWidth: CGFloat {
        let count = CGFloat(model.tabs.count)
        let grid = model.tabs.count > 1 || model.gridActive ? 6 + (slot * 0.7).rounded() : 0
        return 20 + count * (button + 6) + 4 + (slot * 0.7).rounded() + grid
    }

    var body: some View {
        Group {
            if inTitlebar {
                HStack(spacing: 0) {
                    AgentWindowDragArea().frame(width: windowButtonsInset)
                    faces.frame(maxWidth: facesWidth)
                    Text(model.tabs.first(where: \.isSelected)?.title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AgentTabBarColors.cardMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(AgentWindowDragArea())
                }
            } else {
                faces
            }
        }
        .frame(
            width: vertical ? button + 16 : nil,
            height: vertical ? nil : button + 16)
        .background(AgentTabBarColors.bar)
        .overlay(alignment: edge.opposite.alignment) {
            Rectangle()
                .fill(AgentTabBarColors.border)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .contextMenu { AgentTabBarMenu() }
        .onAppear { model.refresh() }
    }

    /// The faces and the `+` button, scrolling when they don't fit.
    private var faces: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))

        return ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            layout {
                ForEach(model.tabs) { tab in
                    AgentTabButton(
                        model: model,
                        tab: tab,
                        faceSize: faceSize,
                        slot: slot,
                        button: button,
                        barEdge: edge)
                }

                AgentNewTabButton(size: (slot * 0.7).rounded()) { anchor in
                    guard let controller = model.terminalController else { return }
                    AgentMenuPanel.shared.toggle(for: controller, barEdge: edge, anchor: anchor)
                }
                .padding(vertical ? .top : .leading, 4)

                if model.tabs.count > 1 || model.gridActive {
                    AgentGridButton(size: (slot * 0.7).rounded(), active: model.gridActive) {
                        model.toggleGrid()
                    }
                }
            }
            .padding(vertical
                ? EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
                : EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .frame(
                maxWidth: vertical ? .infinity : nil,
                maxHeight: vertical ? nil : .infinity,
                alignment: vertical ? .top : .leading)
        }
    }
}

/// Empty title bar space: drag to move the window, double-click to zoom
/// (or minimize, per the system setting).
private struct AgentWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// The options for the tab bar itself.
struct AgentTabBarMenu: View {
    @ObservedObject private var settings = AgentTabBarSettings.shared

    var body: some View {
        Picker("Tab Bar", selection: $settings.position) {
            ForEach(AgentTabBarSettings.Position.allCases, id: \.self) { position in
                Text(position.label).tag(position)
            }
        }
        Picker("Face Style", selection: $settings.faceStyle) {
            ForEach(AgentTabBarSettings.FaceStyle.allCases, id: \.self) { style in
                Text(style.label).tag(style)
            }
        }
        Picker("Face Size", selection: $settings.faceSize) {
            ForEach(AgentTabBarSettings.FaceSize.allCases, id: \.self) { size in
                Text(size.label).tag(size)
            }
        }
        Picker("Account Color", selection: $settings.accountStyle) {
            ForEach(AgentTabBarSettings.AccountStyle.allCases, id: \.self) { style in
                Text(style.label).tag(style)
            }
        }
        Divider()
        Toggle("Dock Badge", isOn: $settings.showsDockBadge)
        Toggle("Menu Bar Summary", isOn: $settings.showsMenuBarSummary)
        Picker("Menu Bar Style", selection: $settings.menuBarStyle) {
            ForEach(AgentTabBarSettings.MenuBarStyle.allCases, id: \.self) { style in
                Text(style.label).tag(style)
            }
        }
        AgentSoundsMenu()
    }
}

/// "Sounds": on or off, and a sound per state. Choosing one plays it.
private struct AgentSoundsMenu: View {
    @ObservedObject private var sounds = AgentSounds.shared

    var body: some View {
        Menu("Sounds") {
            Toggle("Play Sounds", isOn: $sounds.isEnabled)
            Divider()
            ForEach(AgentSounds.states, id: \.self) { state in
                Picker(AgentSounds.label(for: state), selection: binding(for: state)) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(AgentSounds.choices, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .disabled(!sounds.isEnabled)
            }
        }
    }

    private func binding(for state: AgentSounds.State) -> Binding<String?> {
        Binding(
            get: { sounds.sound(for: state) },
            set: {
                sounds.setSound($0, for: state)
                sounds.preview(state)
            })
    }
}

/// The number of running subagents, a pill at the bottom left of the face's
/// slot. Only shown while the agent works.
private struct AgentSubagentBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Color(agentHex: 0xd7e7ff))
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color(agentHex: 0x1c1d21)))
            .overlay(Capsule().strokeBorder(AgentFaceView.color(for: .working), lineWidth: 1.5))
            .fixedSize()
            .accessibilityLabel("\(count) \(count == 1 ? "subagent" : "subagents") running")
    }
}

/// Choose the color of an account: one of the named colors, or any color
/// from the system color panel.
struct AgentAccountColorMenu: View {
    let account: AgentAccount
    var title: String?

    var body: some View {
        Menu(title ?? "Account Color (\(account.name))") {
            ForEach(AgentAccountStore.colorNames, id: \.color) { option in
                Button {
                    AgentAccountStore.shared.setColor(option.color, for: account.id)
                } label: {
                    Label {
                        Text(option.name)
                    } icon: {
                        Image(nsImage: Self.swatch(option.color, selected: option.color == account.color))
                    }
                }
            }
            Divider()
            Button {
                CustomColorPicker.shared.pick(initial: NSColor(account.swiftUIColor)) { color in
                    guard let rgb = color.usingColorSpace(.sRGB) else { return }
                    let hex = UInt32((rgb.redComponent * 255).rounded()) << 16
                        | UInt32((rgb.greenComponent * 255).rounded()) << 8
                        | UInt32((rgb.blueComponent * 255).rounded())
                    AgentAccountStore.shared.setColor(hex, for: account.id)
                }
            } label: {
                if AgentAccountStore.colorNames.contains(where: { $0.color == account.color }) {
                    Text("Custom Color…")
                } else {
                    Label("Custom Color…", systemImage: "checkmark")
                }
            }
        }
    }

    /// A filled circle in `color`, ringed when it's the account's color.
    private static func swatch(_ color: UInt32, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor(Color(agentHex: color)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: selected ? 4 : 2, dy: selected ? 4 : 2)).fill()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                ring.stroke()
            }
            return true
        }
    }
}

/// Choose a tab's color: one from the palette, or any color from the
/// system color panel.
private struct AgentTabColorMenu: View {
    let window: TerminalWindow

    var body: some View {
        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    window.setTabColor(color)
                } label: {
                    Label {
                        Text(color.localizedName)
                    } icon: {
                        Image(nsImage: color.swatchImage(
                            selected: window.customTabColor == nil && window.tabColor == color))
                    }
                }
            }
            Divider()
            Button {
                CustomColorPicker.shared.pick(initial: window.effectiveTabColor) { [weak window] color in
                    window?.setTabColor(custom: color)
                }
            } label: {
                if window.customTabColor != nil {
                    Label("Custom Color…", systemImage: "checkmark")
                } else {
                    Text("Custom Color…")
                }
            }
        }
    }
}

/// The dashed round "+" button at the end of the bar. It opens the new tab
/// menu; ⌘T still opens a plain tab.
private struct AgentNewTabButton: View {
    let size: CGFloat

    /// Called with the button's frame on screen.
    let action: (CGRect) -> Void

    @State private var hovering = false
    @State private var anchor = AgentScreenAnchor()

    var body: some View {
        Button { action(anchor.screenRect) } label: {
            Text("+")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(hovering ? AgentTabBarColors.plusTextHovered : AgentTabBarColors.plusText)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(
                        hovering ? AgentTabBarColors.plusBorderHovered : AgentTabBarColors.plusBorder,
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(AgentScreenAnchorView(anchor: anchor))
        .accessibilityLabel("New Tab Menu")
    }
}

/// Shows every tab at once in a grid, or goes back to tabs.
private struct AgentGridButton: View {
    let size: CGFloat
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "rectangle.inset.filled" : "square.grid.2x2")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundColor(hovering || active ? AgentTabBarColors.plusTextHovered : AgentTabBarColors.plusText)
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AgentTabBarColors.selected : .clear))
                .overlay(
                    Circle().strokeBorder(
                        hovering || active ? AgentTabBarColors.plusBorderHovered : AgentTabBarColors.plusBorder,
                        lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active ? "Back to Tabs (⌘⇧E)" : "Show All Tabs in a Grid (⌘⇧E)")
        .accessibilityLabel(active ? "Back to Tabs" : "Show All Tabs in a Grid")
    }
}

/// One tab: its face, a highlight when selected or hovered, and a details card
/// on hover.
private struct AgentTabButton: View {
    @ObservedObject var model: AgentTabBarModel
    let tab: AgentTab
    let faceSize: CGFloat
    let slot: CGFloat
    let button: CGFloat
    let barEdge: Edge

    @ObservedObject private var settings = AgentTabBarSettings.shared
    @State private var hovering = false
    @State private var anchor = AgentScreenAnchor()

    /// The tab's background. With an account and the background style, the
    /// usual background gets a light tint of the account color, so the face
    /// stays the loudest thing and a selected tab still reads as selected.
    /// Without one, a tab color the user picked tints it instead; it always
    /// outlines the tab. Otherwise the design's gray highlight.
    private var background: Color {
        if settings.accountStyle == .background, let account = tab.account {
            if tab.isSelected {
                return AgentTabBarColors.blend(AgentTabBarColors.selected, account.swiftUIColor, 0.24)
            }
            return AgentTabBarColors.blend(AgentTabBarColors.bar, account.swiftUIColor, hovering ? 0.2 : 0.14)
        }
        if let color = tab.color {
            if tab.isSelected {
                return AgentTabBarColors.blend(AgentTabBarColors.selected, color, 0.24)
            }
            return AgentTabBarColors.blend(AgentTabBarColors.bar, color, hovering ? 0.2 : 0.14)
        }
        if tab.isSelected { return AgentTabBarColors.selected }
        if hovering { return AgentTabBarColors.hovered }
        return AgentTabBarColors.bar
    }

    var body: some View {
        Button {
            AgentTabCardPanel.shared.hide()
            model.select(tab)
        } label: {
            ZStack {
                if let status = tab.status, status.state != .clear {
                    AgentFaceView(
                        state: status.state, size: faceSize, background: background, motion: model.faceMotion,
                        agents: tab.agents, shells: tab.shells)
                } else {
                    ShellGlyphView(size: faceSize)
                }
            }
            .frame(width: slot, height: slot)
            .overlay(
                // The account ring: the slot's 2pt border, in the account's
                // color. None for plain shells and agents without an account.
                Circle().strokeBorder(
                    settings.accountStyle == .ring ? tab.account?.swiftUIColor ?? .clear : .clear,
                    lineWidth: 2))
            .overlay(alignment: .bottomLeading) {
                // Bottom left, so it shows beside the face's own agents and
                // shells badges at the bottom right instead of hiding them.
                if tab.status?.state == .working, tab.subagents > 0 {
                    AgentSubagentBadge(count: tab.subagents)
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: button, height: button)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(background))
            .overlay(
                // The tab color outlines the tab, so it shows alongside the
                // account tint.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tab.color?.opacity(tab.isSelected ? 0.9 : 0.55) ?? .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(AgentScreenAnchorView(anchor: anchor))
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                // Wait a moment so moving across the bar doesn't flash cards.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard hovering, let window = model.window else { return }
                    AgentTabCardPanel.shared.show(
                        AgentTabCard(tab: tab),
                        barEdge: barEdge,
                        anchor: anchor.screenRect,
                        in: window)
                }
            } else {
                AgentTabCardPanel.shared.hide()
            }
        }
        .onChange(of: tab) { newTab in
            // Keep an open card up to date while the agent works.
            guard hovering, let window = model.window else { return }
            AgentTabCardPanel.shared.update(AgentTabCard(tab: newTab), in: window)
        }
        .contextMenu {
            Button("Rename Tab…") { model.rename(tab) }
            if let window = model.terminalWindow(for: tab) {
                AgentTabColorMenu(window: window)
            }
            Divider()
            Button("Close Tab") { model.close(tab) }
            if let account = tab.account {
                Divider()
                AgentAccountColorMenu(account: account)
            }
            Divider()
            AgentTabBarMenu()
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(tab.isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        if let status = tab.status, status.state != .clear {
            return "\(tab.title), \(status.stateLabel)"
        }
        return tab.title
    }
}

/// The details shown when hovering a tab.
private struct AgentTabCard: View {
    let tab: AgentTab

    private var status: Ghostty.Action.ProgramStatus? {
        guard let status = tab.status, status.state != .clear else { return nil }
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tab.title.isEmpty ? "Terminal" : tab.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AgentTabBarColors.cardTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let shortcut = tab.shortcut {
                    Text(shortcut)
                        .font(.system(size: 12.5))
                        .foregroundColor(AgentTabBarColors.cardMuted)
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                (Text(status?.stateLabel ?? "Shell")
                    .foregroundColor(AgentTabBarColors.label(for: status?.state))
                    .fontWeight(.semibold)
                 + Text(" · \(elapsed(now: context.date))")
                    .foregroundColor(AgentTabBarColors.cardMuted))
                    .font(.system(size: 12.5))
            }
            .padding(.top, 2)

            Text(detail)
                .font(.system(size: 12.5))
                .foregroundColor(AgentTabBarColors.cardText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let context = status?.context {
                AgentContextBar(percent: Int(context))
                    .padding(.top, 10)
            }

            if let last = status?.last {
                Text("“\(last)”")
                    .font(.system(size: 12.5).italic())
                    .foregroundColor(AgentTabBarColors.cardQuote)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AgentTabBarColors.cardInset))
                    .padding(.top, 10)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(tab.account?.swiftUIColor ?? AgentTabBarColors.shellAccount)
                    .frame(width: 8, height: 8)
                Text(footer)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5))
            .foregroundColor(AgentTabBarColors.cardMuted)
            .padding(.top, 10)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AgentTabBarColors.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AgentTabBarColors.cardBorder, lineWidth: 1))
    }

    /// What the agent is doing, like the design's "Editing
    /// src/auth/session.ts (2 subagents running)".
    private var detail: String {
        guard let status else { return "Plain shell, no agent" }
        var text = status.msg ?? (status.state == .idle ? "Ready for a prompt" : status.stateLabel)
        if status.state == .working, tab.subagents > 0 {
            text += " (\(tab.subagents) \(tab.subagents == 1 ? "subagent" : "subagents") running)"
        }
        var counts: [String] = []
        if tab.agents > 1 { counts.append("\(tab.agents) agents") }
        if tab.shells > 0 { counts.append("\(tab.shells) \(tab.shells == 1 ? "shell" : "shells") running") }
        if !counts.isEmpty { text += " · " + counts.joined(separator: " · ") }
        return text
    }

    /// The account, folder and branch, like the design's "Work · ~/code/api
    /// · feat/nav", or "No account · ~" for a shell. An agent that reports no
    /// account shows its name instead.
    private var footer: String {
        let pwd = tab.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        guard let status else { return ["No account", pwd, tab.branch].compactMap { $0 }.joined(separator: " · ") }
        let who = tab.account?.name ?? status.appDisplayName
        return [who, pwd ?? status.title, tab.branch].compactMap { $0 }.joined(separator: " · ")
    }

    /// The time part of the state line, worded like the design:
    /// "2m 14s" working, "waiting 1m", "3m ago" done, "idle 12m", "open 40m".
    private func elapsed(now: Date) -> String {
        guard let status else { return "open \(AgentTime.duration(from: tab.openedAt, to: now, seconds: false))" }
        let short = AgentTime.duration(from: status.since, to: now, seconds: false)
        switch status.state {
        case .working: return AgentTime.duration(from: status.since, to: now, seconds: true)
        case .blocked: return "waiting \(short)"
        case .done, .error: return "\(short) ago"
        case .idle, .clear: return "idle \(short)"
        }
    }
}

/// How much of the agent's context window is used: a label, the percent and
/// a 4pt bar that turns amber above 70%.
private struct AgentContextBar: View {
    let percent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Context used")
                Spacer(minLength: 0)
                Text("\(percent)%").monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundColor(AgentTabBarColors.cardMuted)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AgentTabBarColors.contextTrack)
                    Capsule()
                        .fill(percent > 70 ? AgentTabBarColors.contextBarHigh : AgentTabBarColors.contextBar)
                        .frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
        }
    }
}

/// The git branch of a folder, read from the repository's HEAD without
/// running git. Tabs refresh on every status report, so results are kept for
/// a few seconds.
final class AgentGitBranch {
    static let shared = AgentGitBranch()

    private var cache: [String: (branch: String?, at: Date)] = [:]

    func branch(at path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = cache[path], Date().timeIntervalSince(cached.at) < 5 { return cached.branch }
        let branch = Self.readBranch(at: path)
        cache[path] = (branch, Date())
        return branch
    }

    /// The branch HEAD points to, or the short commit when detached. A
    /// worktree's `.git` is a file that points to its git folder.
    private static func readBranch(at path: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          text.hasPrefix("gitdir:") else { return nil }
                    let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = URL(fileURLWithPath: target, relativeTo: dir)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") {
                    return String(head.dropFirst("ref: refs/heads/".count))
                }
                return head.isEmpty ? nil : String(head.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }
}

/// A floating panel that shows a tab's hover card next to its face. It's a
/// separate borderless window so the card can draw over the terminal, and it
/// never becomes key, so the terminal keeps keyboard focus.
final class AgentTabCardPanel {
    static let shared = AgentTabCardPanel()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        return panel
    }()

    private weak var parent: NSWindow?
    private var barEdge: Edge = .top
    private var anchor: CGRect = .zero

    /// Show a card next to `anchor`, a frame on screen, on the side away
    /// from a tab bar at `barEdge`.
    func show<Card: View>(_ card: Card, barEdge: Edge, anchor: CGRect, in window: NSWindow) {
        self.barEdge = barEdge
        self.anchor = anchor
        update(card, in: window)
    }

    func update<Card: View>(_ card: Card, in window: NSWindow) {
        let host = NSHostingView(rootView: card.fixedSize())
        host.frame.size = host.fittingSize
        panel.contentView = host

        let size = host.fittingSize
        let origin = anchor.popupOrigin(size: size, awayFrom: barEdge, gap: 8, on: window.screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }
}
