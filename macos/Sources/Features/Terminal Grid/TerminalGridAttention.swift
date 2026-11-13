import AppKit
import CoreAudio
import OSLog
import SwiftUI

/// Getting you to the agent that needs you.
///
/// In Grid View it moves the keyboard to a tile whose agent is waiting on a
/// permission prompt or a question, and, if you choose, one that finished or
/// failed: Tab Bar menu › Grid View. It never takes the keyboard from you
/// mid-prompt: while you're typing or dictating in a tile, it waits until
/// you send (Return, or the agent starting to work, which catches voice) or
/// clear the line (Esc, ⌃C), and while any app has the
/// microphone open, it waits for that to stop. It doesn't leave a tile whose
/// own agent is waiting on you, and it only acts on a change, so an agent
/// that was already waiting isn't pushed on you again. The tile it moves to
/// pulses and says why.
///
/// ⌘J (`AgentsPanel.jumpToNextWaiting`) does it by hand, whatever the
/// setting, and in a grid lands on the tile the same way.
private let log = Logger(subsystem: "com.kinterm.app", category: "grid-attention")

@MainActor
final class TerminalGridAttention: NSObject, ObservableObject {
    static let shared = TerminalGridAttention()

    /// The tile that just got the keyboard, while it pulses, and why.
    @Published private(set) var pulsing: (id: ObjectIdentifier, reason: String)?

    /// Tabs whose agent started needing you and that you haven't been to
    /// since, with when it started.
    private var pending: [ObjectIdentifier: (controller: Weak<BaseTerminalController>, since: Date)] = [:]

    /// The tab you've typed or dictated into and not sent yet.
    private var composingIn: ObjectIdentifier?
    private var lastInput = Date.distantPast
    private var keyMonitor: Any?
    private var retry: DispatchWorkItem?

    override private init() {
        super.init()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.noteKey(event)
            return event
        }
    }

    // MARK: Input

    private func noteKey(_ event: NSEvent) {
        lastInput = Date()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let tab = (event.window?.firstResponder as? Ghostty.SurfaceView)
            .flatMap(BaseTerminalController.controller(owning:))
            .map(ObjectIdentifier.init)

        switch event.keyCode {
        case 36, 76: // Return, Enter: sent.
            guard !mods.contains(.shift), !mods.contains(.option) else { return } // A newline in the prompt.
            sent()
            return
        case 53: // Escape: cleared, or the agent interrupted.
            sent()
            return
        default: break
        }
        if mods.contains(.control), event.charactersIgnoringModifiers == "c" { sent(); return }
        if mods.contains(.command) {
            // Pasting is composing; other shortcuts aren't.
            if event.charactersIgnoringModifiers == "v", let tab { composingIn = tab }
            return
        }
        // Typed text, not arrows or function keys.
        if let chars = event.characters, let scalar = chars.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 || scalar.value > 0xF8FF,
           let tab {
            // Only a terminal's prompt counts, not the review's note box.
            composingIn = tab
        }
    }

    /// Text that arrived without a key press: dictation, or an input method.
    func noteCommittedText(in surface: Ghostty.SurfaceView) {
        lastInput = Date()
        composingIn = BaseTerminalController.controller(owning: surface).map(ObjectIdentifier.init)
    }

    /// The prompt was sent or cleared: a good moment to move on.
    private func sent() {
        composingIn = nil
        guard !pending.isEmpty else { return }
        scheduleRetry(after: 0.8)
    }

    /// Whether any app has the default microphone open: dictation, an
    /// agent's voice mode, a voice-to-text app.
    private var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: Automatic

    /// Called whenever a tab's agent status changes.
    func statusChanged(_ controller: BaseTerminalController,
                       from old: Ghostty.Action.ProgramStatus.State?,
                       to new: Ghostty.Action.ProgramStatus.State?) {
        let id = ObjectIdentifier(controller)
        log.debug("status \(controller.window?.title ?? "?", privacy: .public): \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)")
        if let new, wants(new) {
            if old != new { pending[id] = (Weak(controller), Date()) }
        } else {
            pending[id] = nil
        }
        // The agent started working: whatever you were writing to it was
        // sent, however it was sent (Return, voice, a voice app pressing
        // Enter for you). That tile doesn't need you now.
        if new == .working, old != .working, composingIn == id {
            composingIn = nil
            log.debug("sent (agent started working)")
        }
        // Even a tile settling down matters: answering the tile you're in
        // is when to move on to the next one waiting.
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func wants(_ state: Ghostty.Action.ProgramStatus.State) -> Bool {
        switch AgentTabBarSettings.shared.gridAutoFocus {
        case .off: return false
        case .waiting: return state == .blocked
        case .waitingOrFinished: return Self.needsYou(state)
        }
    }

    private static func needsYou(_ state: Ghostty.Action.ProgramStatus.State?) -> Bool {
        state == .blocked || state == .error || state == .done
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate() {
        retry?.cancel()
        retry = nil
        pending = pending.filter { $0.value.controller.value != nil }
        guard AgentTabBarSettings.shared.gridAutoFocus != .off else { pending = [:]; return }

        // The grid the keyboard is in, or else any grid with a tile waiting.
        let grid = TerminalGridModel.shared
        let hosts = pending.values.compactMap { $0.controller.value }
            .compactMap { $0.gridWindow ?? $0.window }
            .filter { grid.isActive(for: $0) }
            .map { $0.tabGroup?.selectedWindow ?? $0 }
        guard let host = hosts.first(where: \.isKeyWindow) ?? (NSApp.isActive ? nil : hosts.first) else {
            log.debug("evaluate: no host (pending \(self.pending.count), grid hosts \(hosts.count), key \(NSApp.keyWindow?.title ?? "nil", privacy: .public))")
            return
        }

        let current = grid.focusedController(in: host)
        if let current {
            // Being in a tile counts as having seen it.
            pending[ObjectIdentifier(current)] = nil
            // Its own agent is waiting on you: that comes first.
            if current.programStatus?.state == .blocked { log.debug("evaluate: current tile is blocked"); return }
            // You're mid-prompt there: wait until you send it.
            if composingIn == ObjectIdentifier(current) { log.debug("evaluate: composing in current"); return }
        }

        let tiles = TerminalGridModel.tabWindows(of: host)
            .compactMap { $0.windowController as? BaseTerminalController }
            .filter { $0 !== current && pending[ObjectIdentifier($0)] != nil && wants($0.programStatus?.state ?? .clear) }
        guard let target = mostUrgent(tiles) else {
            log.debug("evaluate: no target (current \(current?.window?.title ?? "nil", privacy: .public), pending \(self.pending.count))")
            return
        }

        // Talking to something, or just pressed a key: try again shortly.
        if microphoneInUse { log.debug("evaluate: microphone in use"); scheduleRetry(after: 1); return }
        let idle = Date().timeIntervalSince(lastInput)
        if idle < 1 { log.debug("evaluate: just typed"); scheduleRetry(after: 1 - idle + 0.1); return }
        log.debug("evaluate: focusing \(target.window?.title ?? "?", privacy: .public)")

        pending[ObjectIdentifier(target)] = nil
        grid.focus(target)
        pulse(target)
    }

    /// Most urgent first; on a tie, whoever has waited longest.
    private func mostUrgent(_ controllers: [BaseTerminalController]) -> BaseTerminalController? {
        controllers.max { a, b in
            let ua = a.programStatus?.state.urgency ?? 0, ub = b.programStatus?.state.urgency ?? 0
            if ua != ub { return ua < ub }
            return (pending[ObjectIdentifier(a)]?.since ?? .distantFuture)
                > (pending[ObjectIdentifier(b)]?.since ?? .distantFuture)
        }
    }

    /// Make a tile pulse and say why it has the keyboard.
    func pulse(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        let reason: String
        switch controller.programStatus?.state {
        case .blocked: reason = "Waiting on you"
        case .error: reason = "Stopped with an error"
        case .done: reason = "Finished"
        default: reason = "Needs you"
        }
        pulsing = (id, reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.pulsing?.id == id { self?.pulsing = nil }
        }
    }
}

/// A glow around a tile the keyboard just moved to, and why.
struct TerminalGridPulse: View {
    let color: Color
    let reason: String
    @State private var on = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color, lineWidth: 4)
                .opacity(on ? 0.9 : 0.15)
                .shadow(color: color.opacity(0.8), radius: on ? 10 : 2)
            Text(reason)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(color))
                .shadow(radius: 4)
                .padding(.top, 34)
                .transition(.opacity)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatCount(5, autoreverses: true)) { on = true }
        }
    }
}
