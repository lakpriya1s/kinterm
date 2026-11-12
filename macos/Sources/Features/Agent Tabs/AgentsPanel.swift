import AppKit
import SwiftUI

// The Agents panel (⌘⇧A): every agent in every window, filterable, Enter to
// jump. And ⌘J, which jumps to the next agent waiting on you. See
// scope/designs/05-agents-panel.md.

/// Durations worded like the design: "2m 14s", "12m", "1h 5m".
enum AgentTime {
    static func duration(from start: Date, to end: Date, seconds showSeconds: Bool) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return showSeconds ? "\(minutes)m \(seconds)s" : "\(minutes)m" }
        return "\(seconds)s"
    }
}

/// One agent as the panel lists it.
struct AgentRow: Identifiable {
    let id: ObjectIdentifier
    let controller: BaseTerminalController
    let status: Ghostty.Action.ProgramStatus
    let title: String

    /// "Window 1 · tab 2", then the git branch if there is one.
    let location: String
    let account: AgentAccount?

    /// Every agent in every window, most urgent first, then by window and tab.
    static func all() -> [AgentRow] {
        // Number windows (tab groups) and tabs in the order AppKit keeps them.
        var groups: [ObjectIdentifier] = []
        var rows: [(row: AgentRow, order: (Int, Int))] = []
        for window in NSApp.windows where window.isVisible {
            guard let controller = window.windowController as? BaseTerminalController,
                  let status = controller.programStatus, status.state != .clear else { continue }
            let group = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            if !groups.contains(group) { groups.append(group) }
            let windowNumber = (groups.firstIndex(of: group) ?? 0) + 1
            let tabNumber = (window.tabGroup?.windows.firstIndex(of: window) ?? 0) + 1
            let row = AgentRow(
                id: ObjectIdentifier(controller),
                controller: controller,
                status: status,
                title: window.title.isEmpty ? "Terminal" : window.title,
                location: (["Window \(windowNumber) · tab \(tabNumber)"]
                    + [AgentGitBranch.shared.branch(at: controller.focusedSurface?.pwd)].compactMap { $0 })
                    .joined(separator: " · "),
                account: status.account.map { AgentAccountStore.shared.account(for: $0, app: status.app) })
            rows.append((row, (windowNumber, tabNumber)))
        }
        return rows
            .sorted {
                if $0.row.status.state.urgency != $1.row.status.state.urgency {
                    return $0.row.status.state.urgency > $1.row.status.state.urgency
                }
                return $0.order < $1.order
            }
            .map(\.row)
    }

    /// What the agent is doing, for the DOING column.
    var doing: String {
        if let msg = status.msg {
            return status.state == .done ? "Finished · \(msg)" : msg
        }
        switch status.state {
        case .idle: return "Ready for a prompt"
        default: return status.stateLabel
        }
    }

    /// The TIME column: "2m 14s" working, "1m" waiting, "3m ago" done, "12m" idle.
    func time(now: Date) -> String {
        switch status.state {
        case .working: return AgentTime.duration(from: status.since, to: now, seconds: true)
        case .done, .error: return "\(AgentTime.duration(from: status.since, to: now, seconds: false)) ago"
        default: return AgentTime.duration(from: status.since, to: now, seconds: false)
        }
    }
}

/// The design's colors for the panel.
private enum PanelColors {
    static let background = Color(agentHex: 0x1f2026)
    static let border = Color(agentHex: 0x33363f)
    static let divider = Color(agentHex: 0x2e3038)
    static let field = Color(agentHex: 0x16171b)
    static let fieldBorder = Color(agentHex: 0x3a3d47)
    static let chipOn = Color(agentHex: 0x3a3d47)
    static let title = Color(agentHex: 0xf1f2f4)
    static let text = Color(agentHex: 0xd6d9df)
    static let doing = Color(agentHex: 0xc2c6cf)
    static let secondary = Color(agentHex: 0xa8adb7)
    static let muted = Color(agentHex: 0x8a8f99)
    static let rowHover = Color(agentHex: 0x2a2c33)
}

/// Which agents the panel shows.
enum AgentFilter: CaseIterable {
    case all, waiting, working, done

    var label: String {
        switch self {
        case .all: return "All"
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    func matches(_ row: AgentRow) -> Bool {
        switch self {
        case .all: return true
        case .waiting: return row.status.state == .blocked
        case .working: return row.status.state == .working
        case .done: return row.status.state == .done
        }
    }
}

/// The panel's state, shared with the window so arrow keys and Enter work
/// while the filter field has focus.
final class AgentsPanelModel: ObservableObject {
    @Published var rows: [AgentRow] = []
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: AgentFilter = .all { didSet { selection = 0 } }
    @Published var selection = 0

    var jump: (AgentRow) -> Void = { _ in }

    var visible: [AgentRow] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            guard filter.matches(row) else { return false }
            guard !query.isEmpty else { return true }
            return [row.title, row.doing, row.location, row.account?.label ?? row.status.appDisplayName, row.status.stateLabel]
                .contains { $0.lowercased().contains(query) }
        }
    }

    func count(_ filter: AgentFilter) -> Int { rows.filter(filter.matches).count }

    var windowCount: Int {
        Set(rows.map { $0.location.components(separatedBy: " · ").first ?? "" }).count
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func jumpToSelection() {
        let visible = visible
        guard visible.indices.contains(selection) else { return }
        jump(visible[selection])
    }
}

struct AgentsPanelView: View {
    @ObservedObject var model: AgentsPanelModel
    @FocusState private var fieldFocused: Bool

    /// The grid: face, TAB, DOING, ACCOUNT, TIME, with 12pt gaps.
    private static let faceColumn: CGFloat = 30
    private static let accountColumn: CGFloat = 90
    private static let timeColumn: CGFloat = 70

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            columnTitles
            rows
            footer
        }
        .frame(width: 748, height: 488)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PanelColors.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PanelColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("", text: $model.query, prompt: Text("Filter agents…").foregroundColor(PanelColors.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundColor(PanelColors.title)
                .focused($fieldFocused)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelColors.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PanelColors.fieldBorder, lineWidth: 1))
                .onSubmit { model.jumpToSelection() }
                .accessibilityLabel("Filter agents")
            Text("⌘⇧A")
                .font(.system(size: 12))
                .foregroundColor(PanelColors.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(PanelColors.divider).frame(height: 1) }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(AgentFilter.allCases, id: \.self) { filter in
                let on = model.filter == filter
                Button { model.filter = filter } label: {
                    Text("\(filter.label) \(model.count(filter))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(on ? PanelColors.title : PanelColors.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(on ? PanelColors.chipOn : Color.clear))
                        .overlay(Capsule().strokeBorder(PanelColors.fieldBorder, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 4, trailing: 18))
    }

    private var columnTitles: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 22, height: 1)
            Text("TAB").frame(maxWidth: .infinity, alignment: .leading)
            Text("DOING").frame(maxWidth: .infinity, alignment: .leading)
            Text("ACCOUNT").frame(width: Self.accountColumn, alignment: .leading)
            Text("TIME").frame(width: Self.timeColumn, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .tracking(0.46)
        .foregroundColor(PanelColors.muted)
        .padding(EdgeInsets(top: 10, leading: 32, bottom: 6, trailing: 32))
    }

    private var rows: some View {
        let visible = model.visible
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        AgentsPanelRow(row: row, selected: index == model.selection) {
                            model.selection = index
                            model.jumpToSelection()
                        }
                        .id(index)
                    }
                    if visible.isEmpty {
                        Text(model.rows.isEmpty ? "No agents running" : "No agents match")
                            .font(.system(size: 13))
                            .foregroundColor(PanelColors.muted)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 18, bottom: 12, trailing: 18))
            }
            .onChange(of: model.selection) { proxy.scrollTo($0) }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Text("↵ jump to tab")
            Text("⌘J next waiting agent")
            Spacer()
            Text("\(model.rows.count) \(model.rows.count == 1 ? "agent" : "agents") · \(model.windowCount) \(model.windowCount == 1 ? "window" : "windows")")
        }
        .font(.system(size: 12))
        .foregroundColor(PanelColors.muted)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(PanelColors.divider).frame(height: 1) }
    }

    fileprivate static var columns: (face: CGFloat, account: CGFloat, time: CGFloat) {
        (faceColumn, accountColumn, timeColumn)
    }
}

private struct AgentsPanelRow: View {
    let row: AgentRow
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let columns = AgentsPanelView.columns
        Button(action: action) {
            HStack(spacing: 12) {
                // The design draws a 40pt face scaled to 0.6 in a 30pt box.
                AgentFaceView(
                    state: row.status.state, size: 24,
                    background: hovering || selected ? PanelColors.rowHover : PanelColors.background,
                    agents: row.controller.agentCount, shells: row.controller.shellCount)
                    .frame(width: columns.face, height: columns.face)

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(PanelColors.title)
                    Text(row.location)
                        .font(.system(size: 11.5))
                        .foregroundColor(PanelColors.muted)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.doing)
                    .font(.system(size: 13))
                    .foregroundColor(doingColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.account?.swiftUIColor ?? AgentTabBarColors.shellAccount)
                        .frame(width: 3, height: 14)
                    Text(row.account?.label ?? row.status.appDisplayName)
                        .lineLimit(1)
                }
                .font(.system(size: 13))
                .foregroundColor(PanelColors.secondary)
                .frame(width: columns.account, alignment: .leading)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(row.time(now: context.date))
                        .monospacedDigit()
                }
                .font(.system(size: 13))
                .foregroundColor(PanelColors.muted)
                .frame(width: columns.time, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering || selected ? PanelColors.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Waiting rows are amber, idle rows gray, the rest light.
    private var doingColor: Color {
        switch row.status.state {
        case .blocked: return AgentFaceView.color(for: .blocked)
        case .idle: return PanelColors.muted
        default: return PanelColors.doing
        }
    }
}

/// The window the panel lives in, centered over the active terminal window.
final class AgentsPanel {
    static let shared = AgentsPanel()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let model = AgentsPanelModel()
    private var keyMonitor: Any?
    private var resignObserver: Any?

    private lazy var panel: NSPanel = {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 748, height: 488),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: AgentsPanelView(model: model))

        // AppKit hides the panel when KinTerm is deactivated, without calling
        // `hide`. Clean up then too, or the hidden list keeps its faces
        // animating.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hide(restoringFocus: false) }
        return panel
    }()

    private weak var returnWindow: NSWindow?

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        model.rows = AgentRow.all()
        model.query = ""
        model.filter = .all
        model.selection = 0
        model.jump = { [weak self] row in
            self?.hide(restoringFocus: false)
            AgentSummary.focus(row.controller)
        }

        let anchor = NSApp.keyWindow ?? NSApp.mainWindow
        returnWindow = anchor
        let frame = anchor?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(width: 748, height: 488)
        // Centered horizontally, a little above the middle, like Spotlight.
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: self.hide(); return nil // Escape
            case 125: self.model.move(1); return nil // Down
            case 126: self.model.move(-1); return nil // Up
            case 36, 76: self.model.jumpToSelection(); return nil // Return, Enter
            default: return event
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.hide(restoringFocus: false) }

        // Keep the list live while it's open.
        refresh()
    }

    private func refresh() {
        guard panel.isVisible else { return }
        let ids = model.rows.map(\.status)
        let rows = AgentRow.all()
        if rows.map(\.status) != ids || rows.count != model.rows.count { model.rows = rows }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func hide(restoringFocus: Bool = true) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        // No rows, no faces: a hidden panel's views stay alive, and their
        // animations would keep laying out the panel.
        model.rows = []
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoringFocus { returnWindow?.makeKeyAndOrderFront(nil) }
    }

    // MARK: Shortcuts

    private static var shortcutMonitor: Any?

    /// ⌘⇧A toggles the panel. ⌘J jumps to the next agent waiting on you; with
    /// none waiting it does what it normally does in KinTerm.
    static func installShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (mods, event.keyCode) {
            case ([.command, .shift], 0): // A
                shared.toggle()
                return nil
            case ([.command], 38): // J
                return jumpToNextWaiting() ? nil : event
            default:
                return event
            }
        }
    }

    /// Focus the next agent waiting on you after the current tab, wrapping
    /// around. Returns false if none is waiting.
    @discardableResult
    static func jumpToNextWaiting() -> Bool {
        let waiting = AgentRow.all()
            .filter { $0.status.state == .blocked }
            .sorted { $0.location.localizedStandardCompare($1.location) == .orderedAscending }
        guard !waiting.isEmpty else { return false }
        let current = NSApp.keyWindow?.windowController as? BaseTerminalController
        let next: AgentRow
        if let current, let index = waiting.firstIndex(where: { $0.controller === current }) {
            next = waiting[(index + 1) % waiting.count]
        } else {
            next = waiting[0]
        }
        shared.hide(restoringFocus: false)
        AgentSummary.focus(next.controller)
        return true
    }
}
