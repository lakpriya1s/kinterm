import Cocoa
import SwiftUI

/// The Setup Assistant: a wizard for KinTerm's own options (faces, the tab
/// bar, the Claude Code hook, notifications and the summaries) and its
/// tools (Grid View, Code Review, the browser), shown on first launch and
/// from KinTerm › Setup Assistant… after that. After an update with new
/// tools, people who finished it see just those, once ("What's New"). Choices apply
/// as they're made, so the windows behind it show them right away.
final class OnboardingController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingController()

    private static let completedKey = "OnboardingCompleted"

    /// The newest pages seen, so people who finished the wizard before a
    /// page existed see it once, alone, as "What's New". Bump with a new
    /// page and list it in `OnboardingView.Mode.whatsNew`.
    private static let featuresKey = "OnboardingFeaturesSeen"
    private static let features = 1

    private var mode: OnboardingView.Mode = .setup

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = "Welcome to KinTerm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = view(.setup)
    }

    private func view(_ mode: OnboardingView.Mode) -> NSView {
        NSHostingView(rootView: OnboardingView(mode: mode, finish: { [weak self] in self?.finish() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Add "Setup Assistant…" to the app menu, and show the wizard if it
    /// hasn't been finished yet.
    func start() {
        installMenuItem()
        var force = false, forceNew = false
        #if DEBUG
        force = ProcessInfo.processInfo.environment["KINTERM_ONBOARDING_STEP"] != nil
        forceNew = ProcessInfo.processInfo.environment["KINTERM_WHATS_NEW"] != nil
        #endif
        let defaults = UserDefaults.ghostty
        let mode: OnboardingView.Mode
        if force || !defaults.bool(forKey: Self.completedKey) {
            mode = .setup
        } else if forceNew || defaults.integer(forKey: Self.featuresKey) < Self.features {
            mode = .whatsNew
        } else {
            return
        }
        // After the first terminal window is up, so the wizard sits on top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.present(mode) }
    }

    /// The whole wizard, from KinTerm › Setup Assistant….
    @objc func show() {
        present(.setup)
    }

    private func present(_ mode: OnboardingView.Mode) {
        guard let window else { return }
        if !window.isVisible || mode != self.mode {
            self.mode = mode
            window.contentView = view(mode)
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts too: everything has a working default, and
        // the wizard is always in the KinTerm menu.
        UserDefaults.ghostty.set(true, forKey: Self.completedKey)
        UserDefaults.ghostty.set(Self.features, forKey: Self.featuresKey)
    }

    private func installMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              !appMenu.items.contains(where: { $0.action == #selector(show) }) else { return }
        let item = NSMenuItem(title: "Setup Assistant…", action: #selector(show), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "wand.and.stars")
        // Right after "About KinTerm".
        appMenu.insertItem(item, at: min(1, appMenu.items.count))
    }
}
