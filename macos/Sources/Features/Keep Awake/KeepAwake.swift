import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Keeps the Mac from going to sleep while there's work going on: while
/// agents work, for a while, until you turn it off, or until a command or
/// an agent's turn in one tab finishes.
///
/// It holds a power assertion, the same thing `caffeinate` does: the Mac
/// doesn't idle-sleep, and the display may (unless "Keep Display On"). The
/// system lets go of it if KinTerm quits or crashes, so the Mac can't be
/// left stuck awake. Closing the lid still sleeps a Mac that isn't on power
/// with an external display: only root can change that.
///
/// Shown in the agents' menu bar item (a cup), the View menu, the dock
/// menu, the command palette, the right-click menus of terminals and agent
/// tabs, and to agents through `kinterm-ctl awake` and the `keep_awake`
/// MCP tool.
@MainActor
final class KeepAwake: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = KeepAwake()

    typealias State = Ghostty.Action.ProgramStatus.State

    // MARK: Settings

    /// How long an agent waiting on you keeps the Mac awake.
    enum WaitingLimit: Int, CaseIterable {
        case never = 0
        case fifteenMinutes = 15
        case thirtyMinutes = 30
        case oneHour = 60
        case untilAnswered = -1

        var label: String {
            switch self {
            case .never: return "Don't Count Waiting"
            case .fifteenMinutes: return "Up to 15 Minutes"
            case .thirtyMinutes: return "Up to 30 Minutes"
            case .oneHour: return "Up to 1 Hour"
            case .untilAnswered: return "Until Answered"
            }
        }
    }

    /// When the battery stops it keeping the Mac awake.
    enum BatteryGuard: Int, CaseIterable {
        case never = 0
        case below20 = 20
        case below10 = 10
        case onBattery = 100

        var label: String {
            switch self {
            case .never: return "Keep Awake on Battery"
            case .below20: return "Stop Below 20%"
            case .below10: return "Stop Below 10%"
            case .onBattery: return "Stop on Battery"
            }
        }
    }

    /// The choices for "After Agents Finish", in minutes.
    static let graceChoices = [0, 2, 5, 10, 15]

    /// The timed choices, in minutes.
    static let durations = [15, 60, 120, 240]

    private enum Key {
        static let agents = "KeepAwakeWhileAgentsWork"
        static let manualUntil = "KeepAwakeManualUntil"
        static let display = "KeepAwakeDisplayOn"
        static let waiting = "KeepAwakeWaitingLimit"
        static let grace = "KeepAwakeGraceMinutes"
        static let battery = "KeepAwakeBatteryGuard"
        static let notify = "KeepAwakeNotify"
        static let menuBar = "KeepAwakeInMenuBar"
    }

    private let defaults = UserDefaults.ghostty

    /// Keep the Mac awake whenever an agent in any tab is working.
    @Published var whileAgentsWork: Bool {
        didSet { defaults.set(whileAgentsWork, forKey: Key.agents); evaluate() }
    }

    @Published var keepDisplayOn: Bool {
        didSet { defaults.set(keepDisplayOn, forKey: Key.display); evaluate() }
    }

    @Published var waitingLimit: WaitingLimit {
        didSet { defaults.set(waitingLimit.rawValue, forKey: Key.waiting); evaluate() }
    }

    /// Minutes to stay awake after the last agent finishes, to read what
    /// it did or to give it the next thing.
    @Published var graceMinutes: Int {
        didSet { defaults.set(graceMinutes, forKey: Key.grace); evaluate() }
    }

    @Published var batteryGuard: BatteryGuard {
        didSet { defaults.set(batteryGuard.rawValue, forKey: Key.battery); evaluate() }
    }

    /// A notification when the Mac can sleep again on its own (agents
    /// finished, the timer ran out, a command ended, the battery ran low).
    @Published var notifies: Bool {
        didSet { defaults.set(notifies, forKey: Key.notify) }
    }

    /// The cup in the menu bar while it's keeping the Mac awake.
    @Published var showsInMenuBar: Bool {
        didSet { defaults.set(showsInMenuBar, forKey: Key.menuBar); changed() }
    }

    // MARK: State

    /// Turned on by hand: until a time, or until turned off
    /// (`Date.distantFuture`). Kept across restarts.
    @Published private(set) var manualUntil: Date?

    /// The minutes picked for the timer, to show a check mark beside it.
    private(set) var manualMinutes: Int?

    /// Keeping awake until something in one terminal finishes: its command,
    /// or its agent's turn.
    final class Hold {
        enum Source: String { case user, agent, pane }

        let surfaceID: UUID
        weak var surface: Ghostty.SurfaceView?
        let reason: String
        let source: Source
        let created = Date()
        let expires: Date?
        /// Whether a command ending in it ends the hold. Not for a timer
        /// asked for from a shell prompt: there the command that asked is
        /// the one that ends.
        let endsWithCommand: Bool
        /// Commands that end before this are the one that asked for it
        /// (`kinterm-ctl awake; make` ends with `make`).
        let ignoresCommandsUntil: Date

        init(
            surface: Ghostty.SurfaceView,
            reason: String,
            source: Source,
            expires: Date?,
            endsWithCommand: Bool,
            ignoresCommandsUntil: Date
        ) {
            self.surfaceID = surface.id
            self.surface = surface
            self.reason = reason
            self.source = source
            self.expires = expires
            self.endsWithCommand = endsWithCommand
            self.ignoresCommandsUntil = ignoresCommandsUntil
        }
    }

    @Published private(set) var holds: [Hold] = []

    /// One thing keeping the Mac awake now.
    struct Reason: Equatable {
        enum Kind { case agents, finishing, manual, hold }
        let kind: Kind
        let text: String
    }

    @Published private(set) var reasons: [Reason] = []

    /// Whether the power assertion is held right now.
    @Published private(set) var isHolding = false

    /// Something would keep the Mac awake, but the battery guard stopped it.
    @Published private(set) var stoppedForBattery = false

    /// When an agent last worked (or waited, when that counts).
    private var lastAgentActivity: Date?
    private var assertionID: IOPMAssertionID = 0
    private var assertionDisplay = false
    private var heldSince: Date?
    /// Set when you turn it off, so that's not announced.
    private var releasedByUser = false

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var powerSource: CFRunLoopSource?

    override private init() {
        let d = UserDefaults.ghostty
        whileAgentsWork = d.object(forKey: Key.agents) as? Bool ?? true
        keepDisplayOn = d.bool(forKey: Key.display)
        waitingLimit = WaitingLimit(rawValue: d.object(forKey: Key.waiting) as? Int ?? 15) ?? .fifteenMinutes
        graceMinutes = d.object(forKey: Key.grace) as? Int ?? 5
        batteryGuard = BatteryGuard(rawValue: d.object(forKey: Key.battery) as? Int ?? 20) ?? .below20
        notifies = d.object(forKey: Key.notify) as? Bool ?? true
        showsInMenuBar = d.object(forKey: Key.menuBar) as? Bool ?? true
        if let until = d.object(forKey: Key.manualUntil) as? Date, until > Date() {
            manualUntil = until
        }
        super.init()
    }

    /// Start following agents and the power source. Safe to call more than once.
    func start() {
        guard cancellables.isEmpty else { return }
        AgentTabBarModel.changesPublisher
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            .store(in: &cancellables)

        // Plugged in or out, or the charge changed.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { KeepAwake.shared.evaluate() } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        // States change inside a tab without its summary changing, timers
        // run out and grace periods end: look again now and then.
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    // MARK: Turning it on and off

    /// Keep awake for `minutes`, or until turned off when nil.
    func keepAwake(minutes: Int?) {
        releasedByUser = false
        manualMinutes = minutes
        manualUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        defaults.set(manualUntil, forKey: Key.manualUntil)
        evaluate()
    }

    /// Stop the timer or "until I turn it off", and every hold. Keeping
    /// awake while agents work is a setting of its own, left as it is.
    func turnOff() {
        releasedByUser = true
        clearManual()
        holds.removeAll()
        evaluate()
    }

    /// The menu's shortcut: off if anything turned on by hand is keeping
    /// the Mac awake, otherwise on until turned off.
    func toggle() {
        if manualUntil != nil || !holds.isEmpty {
            turnOff()
        } else {
            keepAwake(minutes: nil)
        }
    }

    private func clearManual() {
        manualUntil = nil
        manualMinutes = nil
        defaults.removeObject(forKey: Key.manualUntil)
    }

    /// Keep awake until what runs in `surface` finishes: its command, or its
    /// agent's turn. Replaces a hold it already had.
    @discardableResult
    func hold(
        _ surface: Ghostty.SurfaceView,
        reason: String? = nil,
        source: Hold.Source = .user,
        minutes: Int? = nil,
        endsWithCommand: Bool = true
    ) -> Hold {
        releasedByUser = false
        holds.removeAll { $0.surfaceID == surface.id }
        // Asked from the terminal's own shell (an agent's tool, or by hand),
        // the line that asked ends right after: that's not the end.
        let asking: TimeInterval = source == .agent ? 3 : 0
        let hold = Hold(
            surface: surface,
            reason: reason ?? Self.describe(surface),
            source: source,
            expires: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) },
            endsWithCommand: endsWithCommand,
            ignoresCommandsUntil: Date().addingTimeInterval(asking))
        holds.append(hold)
        evaluate()
        return hold
    }

    func release(_ surface: Ghostty.SurfaceView) {
        guard holds.contains(where: { $0.surfaceID == surface.id }) else { return }
        releasedByUser = true
        holds.removeAll { $0.surfaceID == surface.id }
        evaluate()
    }

    func hold(for surface: Ghostty.SurfaceView) -> Hold? {
        holds.first { $0.surfaceID == surface.id }
    }

    /// A command in `surface` ended and its shell is back at the prompt.
    func commandFinished(in surface: Ghostty.SurfaceView) {
        let now = Date()
        let ending = holds.filter {
            $0.surfaceID == surface.id && $0.endsWithCommand && now >= $0.ignoresCommandsUntil
        }
        guard !ending.isEmpty else { return }
        releasedByUser = false
        holds.removeAll { hold in ending.contains { $0 === hold } }
        finished.append(contentsOf: ending.map { "\($0.reason) finished." })
        evaluate()
    }

    /// Holds that ended since the last look, for the notification.
    private var finished: [String] = []

    /// Whether "Until This Finishes" makes sense for `surface`: something is
    /// running in it, or its agent is busy.
    static func isBusy(_ surface: Ghostty.SurfaceView) -> Bool {
        if let state = surface.programStatus?.state, state == .working || state == .blocked { return true }
        return surface.needsConfirmQuit
    }

    /// "Until make test finishes", or for a timer, "test run: 25 min more".
    static func describe(_ hold: Hold, now: Date = Date()) -> String {
        if !hold.endsWithCommand, let expires = hold.expires {
            return "\(hold.reason): \(remaining(until: expires, now: now)) more"
        }
        return "Until \(hold.reason) finishes"
    }

    /// "claude in ~/code/api", "make test in ~/code/api", or the title.
    static func describe(_ surface: Ghostty.SurfaceView) -> String {
        let folder = surface.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let what: String
        if let status = surface.programStatus, status.state != .clear {
            what = status.appDisplayName
        } else if !surface.title.isEmpty {
            what = surface.title
        } else {
            what = "Terminal"
        }
        guard let folder, !what.contains(folder) else { return what }
        return "\(what) in \(folder)"
    }

    // MARK: Deciding

    /// Every terminal in every window, shown or hidden.
    private var allSurfaces: [Ghostty.SurfaceView] {
        NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap(\.allSurfaces)
    }

    func evaluate() {
        let now = Date()
        var reasons: [Reason] = []
        var ended: [String] = finished
        finished = []

        // Timer or "until I turn it off".
        if let until = manualUntil {
            if until <= now {
                clearManual()
                ended.append(manualMinutes.map { "The \(Self.duration(minutes: $0)) timer ran out." }
                    ?? "The timer ran out.")
            } else if until == .distantFuture {
                reasons.append(.init(kind: .manual, text: "Until you turn it off"))
            } else {
                reasons.append(.init(kind: .manual, text: "For \(Self.remaining(until: until, now: now)) more"))
            }
        }

        // Holds on one terminal each.
        let surfaces = allSurfaces
        let byID = Dictionary(surfaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        holds = holds.filter { hold in
            guard let surface = hold.surface, byID[hold.surfaceID] != nil else {
                ended.append("\(hold.reason) closed.")
                return false
            }
            if let expires = hold.expires, expires <= now {
                ended.append("\(hold.reason): time's up.")
                return false
            }
            // Its agent's turn ended since.
            if let status = surface.programStatus, status.since > hold.created,
               status.state == .done || status.state == .error {
                ended.append("\(hold.reason) finished.")
                return false
            }
            return true
        }
        for hold in holds {
            reasons.append(.init(kind: .hold, text: Self.describe(hold, now: now)))
        }

        // Agents at work.
        if whileAgentsWork {
            var working = 0
            var waiting = 0
            for surface in surfaces {
                guard let status = surface.programStatus else { continue }
                switch status.state {
                case .working:
                    working += 1
                case .blocked:
                    switch waitingLimit {
                    case .never: break
                    case .untilAnswered: waiting += 1
                    default:
                        if now.timeIntervalSince(status.since) < TimeInterval(waitingLimit.rawValue * 60) {
                            waiting += 1
                        }
                    }
                default:
                    break
                }
            }
            if working + waiting > 0 {
                lastAgentActivity = now
                var parts: [String] = []
                if working > 0 { parts.append("\(working) \(working == 1 ? "agent" : "agents") working") }
                if waiting > 0 { parts.append("\(waiting) waiting on you") }
                reasons.append(.init(kind: .agents, text: parts.joined(separator: ", ")))
            } else if let last = lastAgentActivity {
                let end = last.addingTimeInterval(TimeInterval(graceMinutes * 60))
                if end > now {
                    reasons.append(.init(
                        kind: .finishing,
                        text: "Agents finished · sleeps in \(Self.remaining(until: end, now: now))"))
                } else {
                    lastAgentActivity = nil
                    ended.append("Your agents finished.")
                }
            }
        } else {
            lastAgentActivity = nil
        }

        // The battery.
        let battery = Self.battery()
        let tooLow: Bool = switch batteryGuard {
        case .never: false
        case .onBattery: battery.onBattery
        case .below20, .below10: battery.onBattery && (battery.percent ?? 100) < batteryGuard.rawValue
        }
        let wasStopped = stoppedForBattery
        stoppedForBattery = !reasons.isEmpty && tooLow
        if stoppedForBattery, !wasStopped, isHolding {
            let charge = battery.percent.map { " (\($0)%)" } ?? ""
            announce("Stopped keeping your Mac awake: it's on battery\(charge). It starts again when you plug in.")
        }

        if self.reasons != reasons { self.reasons = reasons }
        let shouldHold = !reasons.isEmpty && !tooLow

        if shouldHold {
            takeAssertion(details: reasons.map(\.text).joined(separator: "; "))
        } else if isHolding {
            let held = heldSince.map { now.timeIntervalSince($0) } ?? 0
            dropAssertion()
            // Don't announce what you did, a blip, or the battery (it was).
            if !releasedByUser, !tooLow, held >= 5 * 60, let why = ended.first {
                announce("\(why) Your Mac can sleep again.")
            }
        }
        releasedByUser = false
        changed()
    }

    private func changed() {
        AgentSummary.shared.update()
    }

    // MARK: Power assertion

    private func takeAssertion(details: String) {
        if isHolding, assertionDisplay != keepDisplayOn { dropAssertion() }
        if !isHolding {
            let type = keepDisplayOn
                ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                : kIOPMAssertionTypePreventUserIdleSystemSleep
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "KinTerm is keeping your Mac awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else {
                AppDelegate.logger.warning("keep awake: couldn't create the power assertion (\(result))")
                return
            }
            assertionID = id
            assertionDisplay = keepDisplayOn
            heldSince = Date()
            isHolding = true
        }
        // What `pmset -g assertions` shows beside it.
        IOPMAssertionSetProperty(assertionID, kIOPMAssertionDetailsKey as CFString, details as CFString)
    }

    private func dropAssertion() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        heldSince = nil
        isHolding = false
    }

    // MARK: Battery

    struct Battery {
        var onBattery: Bool
        var percent: Int?
    }

    static func battery() -> Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .init(onBattery: false, percent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                        as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                percent = current * 100 / max
            }
        }
        return .init(onBattery: onBattery, percent: percent)
    }

    /// Whether this Mac has a battery at all: no battery options without one.
    static let hasBattery: Bool = battery().percent != nil

    // MARK: Notifications

    /// In the userInfo of Keep Mac Awake's notifications, so they show
    /// while KinTerm is in front: they belong to no terminal.
    nonisolated static let notificationKey = "kinterm.keepAwake"

    private func announce(_ body: String) {
        guard notifies else { return }
        let content = UNMutableNotificationContent()
        content.title = "Keep Mac Awake"
        content.body = body
        content.sound = nil
        content.userInfo = [Self.notificationKey: true]
        let request = UNNotificationRequest(identifier: "keep-awake-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: Text

    /// "Keeping your Mac awake" with what for, or what it's set to do.
    var headline: String {
        if stoppedForBattery { return "Stopped on battery" }
        if isHolding { return "Keeping your Mac awake" }
        return whileAgentsWork ? "Will stay awake while agents work" : "Your Mac sleeps as usual"
    }

    var detail: String? {
        if isHolding || stoppedForBattery {
            return reasons.map(\.text).joined(separator: " · ")
        }
        return nil
    }

    /// The short countdown beside the menu bar cup, for the timer.
    var menuBarCountdown: String? {
        guard isHolding, let until = manualUntil, until != .distantFuture else { return nil }
        return Self.remaining(until: until, now: Date(), compact: true)
    }

    /// "1 hr", "15 min".
    static func duration(minutes: Int) -> String {
        minutes % 60 == 0
            ? "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")"
            : "\(minutes) minutes"
    }

    /// "1h 20m" / "14 min", rounded up so it never says 0 while running.
    static func remaining(until: Date, now: Date, compact: Bool = false) -> String {
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return compact ? "\(minutes)m" : "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// For the control socket: what's keeping the Mac awake.
    var summary: [String: Any] {
        var out: [String: Any] = [
            "awake": isHolding,
            "whileAgentsWork": whileAgentsWork,
            "keepDisplayOn": keepDisplayOn,
            "reasons": reasons.map(\.text),
        ]
        if stoppedForBattery { out["stoppedForBattery"] = true }
        if let until = manualUntil {
            out["manualUntil"] = until == .distantFuture ? "off" : ISO8601DateFormatter().string(from: until)
        }
        return out
    }

    // MARK: Menus

    /// "Keep Mac Awake" with its choices as a submenu, rebuilt as it opens.
    /// With `surface`, also "Until This Finishes" for it.
    func menuItem(title: String = "Keep Mac Awake", surface: Ghostty.SurfaceView? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        menu.autoenablesItems = false
        if let surface { menuSurfaces.setObject(surface, forKey: menu) }
        item.submenu = menu
        item.setImageIfDesired(systemSymbolName: "cup.and.saucer")
        return item
    }

    /// The terminal each open menu is for.
    private let menuSurfaces = NSMapTable<NSMenu, Ghostty.SurfaceView>.weakToWeakObjects()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu, surface: menuSurfaces.object(forKey: menu))
    }

    /// Every choice, for a menu of its own.
    func fill(_ menu: NSMenu, surface: Ghostty.SurfaceView?) {
        let status = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.setImageIfDesired(systemSymbolName: isHolding ? "cup.and.saucer.fill" : "cup.and.saucer")
        menu.addItem(status)
        if let detail, !detail.isEmpty {
            let line = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
            menu.addItem(line)
        }
        menu.addItem(.separator())
        addChoices(to: menu, surface: surface)
    }

    /// The choices without the status lines: the menu bar's menu shows a
    /// card for those.
    func addChoices(to menu: NSMenu, surface: Ghostty.SurfaceView?) {
        let agents = action("While Agents Work", #selector(toggleAgents(_:)))
        agents.state = whileAgentsWork ? .on : .off
        agents.toolTip = "Stays awake while an agent in any tab works, then for a few minutes after."
        menu.addItem(agents)
        menu.addItem(.separator())

        let manual = manualUntil
        for minutes in Self.durations {
            let chosen = manual != nil && manual != .distantFuture && manualMinutes == minutes
            var title = "For \(Self.duration(minutes: minutes))"
            if chosen, let until = manual { title += " (\(Self.remaining(until: until, now: Date())) left)" }
            let item = action(title, #selector(chooseDuration(_:)))
            item.tag = minutes
            item.state = chosen ? .on : .off
            menu.addItem(item)
        }
        let forever = action("Until I Turn It Off", #selector(chooseForever(_:)))
        forever.state = manual == .distantFuture ? .on : .off
        menu.addItem(forever)

        if let surface {
            menu.addItem(.separator())
            if let hold = hold(for: surface) {
                let item = action("Stop Waiting for \(hold.reason)", #selector(releaseSurface(_:)))
                item.representedObject = surface
                menu.addItem(item)
            } else {
                let item = action("Until This Finishes", #selector(holdSurface(_:)))
                item.representedObject = surface
                item.isEnabled = Self.isBusy(surface)
                item.toolTip = Self.isBusy(surface)
                    ? "Stays awake until \(Self.describe(surface)) finishes."
                    : "Nothing is running here."
                menu.addItem(item)
            }
        }

        let others = holds.filter { $0.surfaceID != surface?.id }
        if !others.isEmpty {
            menu.addItem(.separator())
            for hold in others {
                let item = action("Until \(hold.reason) Finishes", #selector(releaseHold(_:)))
                item.state = .on
                item.representedObject = hold.surfaceID
                item.toolTip = hold.source == .user
                    ? "Choose to stop waiting for it."
                    : "Asked for by an agent. Choose to stop waiting for it."
                menu.addItem(item)
            }
        }

        if manual != nil || !holds.isEmpty {
            menu.addItem(.separator())
            menu.addItem(action("Turn Off", #selector(turnOffFromMenu(_:))))
        }

        menu.addItem(.separator())
        let options = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        options.submenu = optionsMenu()
        menu.addItem(options)
    }

    private func optionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Options")
        menu.autoenablesItems = false

        let display = action("Keep Display On", #selector(toggleDisplay(_:)))
        display.state = keepDisplayOn ? .on : .off
        display.toolTip = "Off, the screen still dims and sleeps; only the Mac stays awake."
        menu.addItem(display)

        let waiting = NSMenu(title: "When an Agent Waits on You")
        for limit in WaitingLimit.allCases {
            let item = action(limit.label, #selector(chooseWaiting(_:)))
            item.tag = limit.rawValue
            item.state = waitingLimit == limit ? .on : .off
            waiting.addItem(item)
        }
        let waitingItem = NSMenuItem(title: "When an Agent Waits on You", action: nil, keyEquivalent: "")
        waitingItem.submenu = waiting
        menu.addItem(waitingItem)

        let grace = NSMenu(title: "After Agents Finish")
        for minutes in Self.graceChoices {
            let item = action(minutes == 0 ? "Sleep Right Away" : "Stay Awake \(minutes) Minutes", #selector(chooseGrace(_:)))
            item.tag = minutes
            item.state = graceMinutes == minutes ? .on : .off
            grace.addItem(item)
        }
        let graceItem = NSMenuItem(title: "After Agents Finish", action: nil, keyEquivalent: "")
        graceItem.submenu = grace
        menu.addItem(graceItem)

        if Self.hasBattery {
            let battery = NSMenu(title: "Battery")
            for choice in BatteryGuard.allCases {
                let item = action(choice.label, #selector(chooseBattery(_:)))
                item.tag = choice.rawValue
                item.state = batteryGuard == choice ? .on : .off
                battery.addItem(item)
            }
            let batteryItem = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
            batteryItem.submenu = battery
            menu.addItem(batteryItem)
        }

        menu.addItem(.separator())
        let notify = action("Notify When the Mac Can Sleep Again", #selector(toggleNotify(_:)))
        notify.state = notifies ? .on : .off
        menu.addItem(notify)
        let bar = action("Show Cup in Menu Bar", #selector(toggleMenuBar(_:)))
        bar.state = showsInMenuBar ? .on : .off
        menu.addItem(bar)

        menu.addItem(.separator())
        let lid = NSMenuItem(title: "Closing the lid still sleeps the Mac unless it's", action: nil, keyEquivalent: "")
        lid.isEnabled = false
        menu.addItem(lid)
        let lid2 = NSMenuItem(title: "plugged in with an external display.", action: nil, keyEquivalent: "")
        lid2.isEnabled = false
        menu.addItem(lid2)
        return menu
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleAgents(_ sender: NSMenuItem) { whileAgentsWork.toggle() }
    @objc private func chooseDuration(_ sender: NSMenuItem) { keepAwake(minutes: sender.tag) }
    @objc private func chooseForever(_ sender: NSMenuItem) {
        if manualUntil == .distantFuture { turnOff() } else { keepAwake(minutes: nil) }
    }
    @objc private func turnOffFromMenu(_ sender: NSMenuItem) { turnOff() }
    @objc func toggleFromMenu(_ sender: Any?) { toggle() }

    @objc private func holdSurface(_ sender: NSMenuItem) {
        guard let surface = sender.representedObject as? Ghostty.SurfaceView else { return }
        hold(surface)
    }

    @objc private func releaseSurface(_ sender: NSMenuItem) {
        guard let surface = sender.representedObject as? Ghostty.SurfaceView else { return }
        release(surface)
    }

    @objc private func releaseHold(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        releasedByUser = true
        holds.removeAll { $0.surfaceID == id }
        evaluate()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) { keepDisplayOn.toggle() }
    @objc private func toggleNotify(_ sender: NSMenuItem) { notifies.toggle() }
    @objc private func toggleMenuBar(_ sender: NSMenuItem) { showsInMenuBar.toggle() }

    @objc private func chooseWaiting(_ sender: NSMenuItem) {
        waitingLimit = WaitingLimit(rawValue: sender.tag) ?? .fifteenMinutes
    }

    @objc private func chooseGrace(_ sender: NSMenuItem) { graceMinutes = sender.tag }

    @objc private func chooseBattery(_ sender: NSMenuItem) {
        batteryGuard = BatteryGuard(rawValue: sender.tag) ?? .below20
    }
}
