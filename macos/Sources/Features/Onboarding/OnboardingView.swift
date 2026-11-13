import SwiftUI
import UserNotifications

/// The Setup Assistant's pages. See `OnboardingController`.
struct OnboardingView: View {
    /// The whole wizard, or only what's new since you last saw it.
    enum Mode { case setup, whatsNew }

    var mode: Mode = .setup
    let finish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, faces, tabBar, claude, tools, stayInLoop, done
    }

    /// The pages of this mode, in order.
    private var steps: [Step] { mode == .setup ? Step.allCases : [.tools] }

    @State private var index = Self.firstIndex

    /// Connect Agents on the tools page.
    @StateObject private var connect = OnboardingConnect()

    private var step: Step { steps[min(index, steps.count - 1)] }

    /// Debug builds can open on a page, to check its layout:
    /// KINTERM_ONBOARDING_STEP=claude.
    private static var firstIndex: Int {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["KINTERM_ONBOARDING_STEP"],
           let step = Step.allCases.first(where: { "\($0)" == name }) {
            return step.rawValue
        }
        #endif
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: OnboardingWelcome()
                case .faces: OnboardingFaces()
                case .tabBar: OnboardingTabBar()
                case .claude: OnboardingClaude()
                case .tools: OnboardingTools(isNew: mode == .whatsNew, connect: connect)
                case .stayInLoop: OnboardingStayInLoop()
                case .done: OnboardingDone()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 44)

            footer
        }
        .frame(width: 760, height: 560)
        .background(OnboardingColors.background)
        .foregroundColor(OnboardingColors.text)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if steps.count > 1 {
                    ForEach(steps, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? OnboardingColors.accent : OnboardingColors.dot)
                            .frame(width: item == step ? 18 : 6, height: 6)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: step)

            Spacer()

            if index > 0 {
                Button("Back") { move(-1) }
                    .buttonStyle(OnboardingButtonStyle(primary: false))
            }
            if step == .tools, connect.state != .done {
                // Connecting is the default here; skipping is one click.
                Button("Not Now") { next() }
                    .buttonStyle(OnboardingButtonStyle(primary: false))
                Button(connect.state == .working ? "Connecting…" : "Connect Agents") { connect.run() }
                    .buttonStyle(OnboardingButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(connect.state == .working)
                    .help("Install the KinTerm skill and the browser's tools for Claude Code and Codex")
            } else {
                Button(primaryTitle) { next() }
                    .buttonStyle(OnboardingButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 20)
        .background(OnboardingColors.footer)
        .overlay(Rectangle().fill(OnboardingColors.border).frame(height: 1), alignment: .top)
    }

    private var primaryTitle: String {
        if mode == .whatsNew { return "Got It" }
        switch step {
        case .welcome: return "Get Started"
        case .done: return "Start Using KinTerm"
        default: return "Continue"
        }
    }

    private func next() {
        if index >= steps.count - 1 { finish() } else { move(1) }
    }

    private func move(_ offset: Int) {
        index = max(0, min(steps.count - 1, index + offset))
    }
}

// MARK: - Pages

private struct OnboardingWelcome: View {
    var body: some View {
        VStack(spacing: 18) {
            KinTermMark().frame(width: 120, height: 120)
            KinTermWordmark(size: 42)
            Text("Your agents, at a glance.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(OnboardingColors.secondary)
            HStack(spacing: 22) {
                ForEach(OnboardingSample.states, id: \.label) { sample in
                    VStack(spacing: 6) {
                        AgentFaceView(state: sample.state, size: 38, background: OnboardingColors.background)
                        Text(sample.label).font(.system(size: 11)).foregroundColor(OnboardingColors.muted)
                    }
                }
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }
}

private struct OnboardingFaces: View {
    @ObservedObject private var settings = AgentTabBarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeading(title: "Pick your faces")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(AgentTabBarSettings.FaceStyle.allCases, id: \.self) { style in
                    OnboardingChoice(value: style, selection: $settings.faceStyle) {
                        VStack(spacing: 10) {
                            HStack(spacing: 6) {
                                ForEach([AgentFaceView.State.working, .blocked, .done], id: \.self) { state in
                                    AgentFaceView(state: state, size: 30, background: OnboardingColors.card, style: style)
                                }
                            }
                            Text(style.label).font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            HStack(spacing: 12) {
                ForEach(AgentTabBarSettings.FaceSize.allCases, id: \.self) { size in
                    OnboardingChoice(value: size, selection: $settings.faceSize) {
                        HStack(spacing: 12) {
                            AgentFaceView(state: .working, size: 40 * size.scale, background: OnboardingColors.card)
                                .frame(width: 66, height: 66)
                            Text(size.label).font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingTabBar: View {
    @ObservedObject private var settings = AgentTabBarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeading(title: "Where do the faces go?")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(AgentTabBarSettings.Position.allCases, id: \.self) { position in
                    OnboardingChoice(value: position, selection: $settings.position) {
                        VStack(alignment: .leading, spacing: 10) {
                            OnboardingTabBarSketch(position: position)
                                .frame(height: 96)
                            Text(position.label).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
            }
        }
    }
}

private struct OnboardingClaude: View {
    @ObservedObject private var settings = AgentTabBarSettings.shared

    /// An agent's config folder: one account.
    struct Folder: Hashable {
        let url: URL
        let agent: AgentKind
    }

    @State private var folders: [Folder] = []
    @State private var chosen: Set<Folder> = []
    @State private var results: [Folder: String] = [:]
    @State private var installed: Set<Folder> = []
    @State private var didInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeading(
                title: "Connect Your Agents",
                detail: "Claude Code and Codex. Each config folder is an account.")

            if folders.isEmpty {
                OnboardingNote(
                    symbol: "questionmark.folder",
                    text: "No Claude Code or Codex config yet. Run one of them once, then reopen KinTerm › Setup Assistant.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(folders, id: \.self) { folder in
                            row(for: folder)
                            if folder != folders.last {
                                Rectangle().fill(OnboardingColors.border).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 176)
                .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingColors.border))

                if installed.count == folders.count {
                    Label(didInstall ? "Connected. Restart running sessions." : "All connected",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OnboardingColors.done)
                } else {
                    Button(installTitle) { install() }
                        .buttonStyle(OnboardingButtonStyle(primary: true))
                        .disabled(chosen.isEmpty)
                }
            }

            HStack(spacing: 12) {
                ForEach(AgentTabBarSettings.AccountStyle.allCases, id: \.self) { style in
                    OnboardingChoice(value: style, selection: $settings.accountStyle) {
                        HStack(spacing: 14) {
                            OnboardingAccountSample(style: style)
                            Text(style == .background ? "Tinted tab" : "Ring")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
    }

    private func row(for folder: Folder) -> some View {
        let isInstalled = installed.contains(folder)
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isInstalled || chosen.contains(folder) },
                set: { on in if on { chosen.insert(folder) } else { chosen.remove(folder) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isInstalled)
            Text(folder.agent.displayName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(OnboardingColors.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().strokeBorder(OnboardingColors.border))
            Text(AgentAccountStore.name(for: folder.url.lastPathComponent))
                .font(.system(size: 13, weight: .semibold))
            Text((folder.url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(OnboardingColors.muted)
            Spacer()
            if let error = results[folder] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(OnboardingColors.error)
                    .help(error)
            } else if isInstalled {
                Image(systemName: "checkmark.circle.fill").foregroundColor(OnboardingColors.done)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var installTitle: String {
        chosen.count == 1 ? "Connect 1 Account" : "Connect \(chosen.count) Accounts"
    }

    private func load() {
        folders = AgentKind.allCases.flatMap { agent in
            AgentAccountStore.configFolders(for: agent).map { Folder(url: $0, agent: agent) }
        }
        installed = Set(folders.filter { AgentHookInstaller.isInstalled(in: $0.url, for: $0.agent) })
        chosen = Set(folders).subtracting(installed)
    }

    private func install() {
        for folder in chosen {
            do {
                try AgentHookInstaller.install(into: folder.url, for: folder.agent)
                installed.insert(folder)
                results[folder] = nil
            } catch {
                results[folder] = error.localizedDescription
            }
        }
        chosen.subtract(installed)
        didInstall = true
    }
}

/// The views for checking on agents' work: Grid View, Code Review and the
/// browser, and a few other things worth knowing. Also shown alone as
/// "What's New" to people who finished the wizard before these existed.
private struct OnboardingTools: View {
    let isNew: Bool
    @ObservedObject var connect: OnboardingConnect

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeading(
                title: isNew ? "New in KinTerm" : "Work alongside your agents",
                detail: "See every agent at once, check what they changed, and watch your app as they build it.")

            HStack(alignment: .top, spacing: 12) {
                OnboardingTool(
                    title: "Grid View", keys: "⌘⇧E",
                    text: "Every tab as a live tile. The keyboard moves to the agent that needs you.") {
                    OnboardingGridSketch()
                }
                OnboardingTool(
                    title: "Review Changes", keys: "⌘⇧R",
                    text: "GitHub-style diffs in a folder tree, across a workspace's repos. Revert, or comment back.") {
                    OnboardingDiffSketch()
                }
                OnboardingTool(
                    title: "Browser", keys: "⌘⇧B",
                    text: "Your dev server with Chrome DevTools. Agents can click through it while you watch.") {
                    OnboardingBrowserSketch()
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            connectNote

            HStack(spacing: 12) {
                OnboardingTip(keys: "⌥⌘1–9", text: "A Claude Code or Codex tab for an account, in a new git worktree if you like")
                OnboardingTip(keys: "Right-click", text: "A tab's color, or an account's")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OnboardingTools {
    /// What Connect Agents does, then how it went.
    @ViewBuilder fileprivate var connectNote: some View {
        switch connect.state {
        case .idle, .working:
            OnboardingNote(
                symbol: "sparkles",
                text: "Connect Agents installs the KinTerm skill, so Claude Code and Codex know about these, "
                    + (BrowserEngine.isInstalled
                        ? "and lets Claude Code and Codex drive the browser. Restart running agents after."
                        : "for each Claude Code and Codex account. Restart running agents after."))
        case .done:
            let failed = connect.outcomes.filter { !$0.ok }
            OnboardingNote(
                symbol: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                text: failed.isEmpty
                    ? "Connected. Restart running agents to pick it up."
                    : "Some didn't connect: " + failed.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))
        }
    }
}

/// Connect Agents: the skill and the browser's tools, for every account.
final class OnboardingConnect: ObservableObject {
    enum State { case idle, working, done }

    @Published private(set) var state = State.idle
    @Published private(set) var outcomes: [BrowserAgentInstaller.Outcome] = []

    @MainActor
    func run() {
        guard state != .working else { return }
        state = .working
        BrowserAgentInstaller.connect(
            claudeFolders: BrowserAgentInstaller.claudeFolders,
            codexFolders: BrowserAgentInstaller.codexFolders
        ) { [weak self] outcomes in
            self?.outcomes = outcomes
            self?.state = .done
        }
    }
}

/// One of the tools: a sketch, its name and shortcut, and what it's for.
private struct OnboardingTool<Sketch: View>: View {
    let title: String
    let keys: String
    let text: String
    @ViewBuilder let sketch: () -> Sketch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sketch()
                .frame(height: 96)
                .frame(maxWidth: .infinity)
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                OnboardingKeys(keys: keys)
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(OnboardingColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingColors.border))
    }
}

private struct OnboardingKeys: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(OnboardingColors.cardHovered))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(OnboardingColors.border))
    }
}

private struct OnboardingTip: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            OnboardingKeys(keys: keys)
            Text(text).font(.system(size: 12)).foregroundColor(OnboardingColors.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
    }
}

/// Four agent tiles, one with the keyboard.
private struct OnboardingGridSketch: View {
    private let states: [AgentFaceView.State] = [.working, .blocked, .done, .working]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { column in
                        tile(states[row * 2 + column], focused: row == 0 && column == 0)
                    }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(agentHex: 0x22242a)))
    }

    private func tile(_ state: AgentFaceView.State, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(AgentFaceView.color(for: state)).frame(width: 6, height: 6)
                RoundedRectangle(cornerRadius: 1).fill(OnboardingColors.muted.opacity(0.7)).frame(width: 26, height: 3)
            }
            ForEach([0.8, 0.55, 0.7], id: \.self) { width in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(OnboardingColors.muted.opacity(0.35))
                        .frame(width: geo.size.width * width, height: 2.5)
                }
                .frame(height: 2.5)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(agentHex: 0x16171b)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
            focused ? OnboardingColors.accent : OnboardingColors.border, lineWidth: focused ? 1.5 : 1))
    }
}

/// A few lines of a diff.
private struct OnboardingDiffSketch: View {
    private let lines: [(kind: Int, width: CGFloat)] = [
        (0, 0.6), (-1, 0.75), (-1, 0.5), (1, 0.8), (1, 0.65), (1, 0.45), (0, 0.55),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                HStack(spacing: 5) {
                    Text(line.kind > 0 ? "+" : line.kind < 0 ? "−" : " ")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(color(line.kind))
                        .frame(width: 6)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(line.kind == 0 ? OnboardingColors.muted.opacity(0.45) : color(line.kind).opacity(0.8))
                            .frame(width: geo.size.width * line.width, height: 3)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: 9)
                .padding(.horizontal, 4)
                .background(line.kind == 0 ? Color.clear : color(line.kind).opacity(0.14))
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(agentHex: 0x16171b)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OnboardingColors.border))
    }

    private func color(_ kind: Int) -> Color {
        kind > 0 ? Color(agentHex: 0x3fb950) : Color(agentHex: 0xf85149)
    }
}

/// A page with an agent's cursor and the glow it shows while it works.
private struct OnboardingBrowserSketch: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(agentHex: 0x4a4e59)).frame(width: 4, height: 4) }
                RoundedRectangle(cornerRadius: 3).fill(Color(agentHex: 0x2c2e35)).frame(height: 9)
                Capsule().fill(OnboardingColors.accent).frame(width: 22, height: 8)
            }
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color(agentHex: 0x22242a))

            ZStack(alignment: .topLeading) {
                Color.white
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(Color(agentHex: 0x24262d)).frame(width: 70, height: 6)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(agentHex: 0xd0d3d9)).frame(width: 30, height: 11)
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Color(agentHex: 0xb0b4bc)).frame(width: 44, height: 11)
                    }
                }
                .padding(8)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(OnboardingColors.accent)
                    .offset(x: 26, y: 28)
                Rectangle()
                    .strokeBorder(OnboardingColors.accent.opacity(0.5), lineWidth: 8)
                    .blur(radius: 6)
                    .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OnboardingColors.border))
    }
}

private struct OnboardingStayInLoop: View {
    @ObservedObject private var settings = AgentTabBarSettings.shared
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeading(title: "Stay in the loop")

            HStack(alignment: .top, spacing: 12) {
                OnboardingFeature(title: "Notifications") {
                    OnboardingBannerSample()
                } control: {
                    notificationControl
                }

                OnboardingFeature(title: "Dock badge") {
                    KinTermAppIcon(front: AgentFaceView.color(for: .blocked), expression: .waiting)
                        .frame(width: 76, height: 76)
                        .overlay(alignment: .topTrailing) {
                            Text("2")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color(agentHex: 0xff453a)))
                                .offset(x: 2, y: -2)
                                .opacity(settings.showsDockBadge ? 1 : 0)
                        }
                } control: {
                    Toggle("", isOn: $settings.showsDockBadge).toggleStyle(.switch).labelsHidden()
                }

                OnboardingFeature(title: "Menu bar") {
                    OnboardingMenuBarSample(style: settings.menuBarStyle)
                        .opacity(settings.showsMenuBarSummary ? 1 : 0.35)
                } control: {
                    Toggle("", isOn: $settings.showsMenuBarSummary).toggleStyle(.switch).labelsHidden()
                }
            }

            if settings.showsMenuBarSummary {
                HStack(spacing: 12) {
                    ForEach(AgentTabBarSettings.MenuBarStyle.allCases, id: \.self) { style in
                        OnboardingChoice(value: style, selection: $settings.menuBarStyle) {
                            VStack(spacing: 8) {
                                OnboardingMenuBarSample(style: style)
                                Text(style.label).font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingSounds()
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var notificationControl: some View {
        switch notifications {
        case .authorized, .provisional, .ephemeral:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(OnboardingColors.done)
        case .denied:
            Button("Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(OnboardingButtonStyle(primary: false))
        default:
            Button("Allow") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    refresh()
                }
            }
            .buttonStyle(OnboardingButtonStyle(primary: true))
        }
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notifications = settings.authorizationStatus }
        }
    }
}

private struct OnboardingDone: View {
    private let tips: [(keys: String, text: String)] = [
        ("Right-click", "Tab bar options"),
        ("Hover", "Agent details"),
        ("⌘⇧A", "Every agent"),
        ("⌘J", "Agent waiting on you"),
        ("⌘⇧E", "All tabs in a grid"),
        ("⌘⇧R", "Review an agent's changes"),
        ("⌘⇧B", "Browser"),
        ("⌥⌘1–9", "Agent tab for an account"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            KinTermMark(front: OnboardingColors.done, expression: .done).frame(width: 80, height: 80)
            Text("You're all set").font(.system(size: 26, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(tips, id: \.keys) { tip in
                    HStack(spacing: 12) {
                        Text(tip.keys)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 96)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(OnboardingColors.cardHovered))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OnboardingColors.border))
                        Text(tip.text).font(.system(size: 13)).foregroundColor(OnboardingColors.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
                }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - Pieces

private enum OnboardingColors {
    static let background = Color(agentHex: 0x16171b)
    static let footer = Color(agentHex: 0x1a1b20)
    static let card = Color(agentHex: 0x1c1d21)
    static let cardHovered = Color(agentHex: 0x22242a)
    static let border = Color(agentHex: 0x2e3038)
    static let text = Color(agentHex: 0xf1f2f4)
    static let secondary = Color(agentHex: 0xa8adb7)
    static let muted = Color(agentHex: 0x8a8f99)
    static let accent = Color(agentHex: 0x5ca0ff)
    static let dot = Color(agentHex: 0x3a3d47)
    static let done = Color(agentHex: 0x3fb950)
    static let error = Color(agentHex: 0xff7b72)
}

private enum OnboardingSample {
    static let states: [(state: AgentFaceView.State, label: String)] = [
        (.idle, "Idle"), (.working, "Working"), (.blocked, "Needs you"), (.done, "Done"), (.error, "Error"),
    ]
}

private struct OnboardingHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 13.5)).foregroundColor(OnboardingColors.secondary)
            }
        }
    }
}

private struct OnboardingNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundColor(OnboardingColors.muted)
            Text(text).font(.system(size: 13)).foregroundColor(OnboardingColors.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
    }
}

/// A card that chooses `value`, outlined in blue when it's the selection.
private struct OnboardingChoice<Value: Equatable, Content: View>: View {
    let value: Value
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    private var selected: Bool { selection == value }

    var body: some View {
        Button { selection = value } label: {
            content()
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? OnboardingColors.cardHovered : OnboardingColors.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    selected ? OnboardingColors.accent : OnboardingColors.border, lineWidth: selected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A feature shown as a picture, with its name and control below.
private struct OnboardingFeature<Sample: View, Control: View>: View {
    let title: String
    @ViewBuilder let sample: () -> Sample
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 12) {
            sample()
                .frame(height: 92)
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                control()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingColors.border))
    }
}

/// Sounds on or off, with a button per state that plays its sound.
private struct OnboardingSounds: View {
    @ObservedObject private var sounds = AgentSounds.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sounds").font(.system(size: 13, weight: .semibold))
                Text("A different sound for each, when you're not looking")
                    .font(.system(size: 11))
                    .foregroundColor(OnboardingColors.muted)
            }
            Spacer(minLength: 8)
            ForEach(AgentSounds.states, id: \.self) { state in
                Button { sounds.preview(state) } label: {
                    HStack(spacing: 6) {
                        AgentFaceView(state: state, size: 18, background: OnboardingColors.background)
                        Text(AgentSounds.label(for: state)).font(.system(size: 12, weight: .medium))
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(OnboardingColors.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(OnboardingColors.background))
                    .overlay(Capsule().strokeBorder(OnboardingColors.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Play the \(AgentSounds.label(for: state).lowercased()) sound")
            }
            .opacity(sounds.isEnabled ? 1 : 0.35)
            .disabled(!sounds.isEnabled)
            Toggle("", isOn: $sounds.isEnabled).toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingColors.border))
    }
}

/// A notification banner from KinTerm, in miniature.
private struct OnboardingBannerSample: View {
    var body: some View {
        HStack(spacing: 8) {
            KinTermAppIcon(front: AgentFaceView.color(for: .done), expression: .done)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(OnboardingColors.text.opacity(0.85)).frame(width: 70, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(OnboardingColors.muted).frame(width: 92, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(OnboardingColors.muted.opacity(0.6)).frame(width: 54, height: 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(agentHex: 0x2c2e35)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingColors.border))
    }
}

/// The menu bar summary in a style, beside a clock, like in the menu bar.
private struct OnboardingMenuBarSample: View {
    let style: AgentTabBarSettings.MenuBarStyle

    var body: some View {
        HStack(spacing: 10) {
            summary
            Text("9:41").font(.system(size: 11, weight: .medium)).foregroundColor(OnboardingColors.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(agentHex: 0x2c2e35)))
    }

    @ViewBuilder private var summary: some View {
        let waiting = AgentFaceView.color(for: .blocked)
        let working = AgentFaceView.color(for: .working)
        switch style {
        case .compact:
            HStack(spacing: 6) {
                dot(waiting, "1")
                dot(working, "2")
            }
        case .full:
            HStack(spacing: 8) {
                dot(waiting, "1 waiting")
                dot(working, "2 working")
            }
        case .icon:
            Circle().fill(waiting).frame(width: 8, height: 8)
        }
    }

    private func dot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(OnboardingColors.text)
        }
        .fixedSize()
    }
}

/// A tab with an account color, shown either way.
private struct OnboardingAccountSample: View {
    let style: AgentTabBarSettings.AccountStyle

    private let account = Color(agentHex: 0x8b7cf6)

    var body: some View {
        AgentFaceView(state: .working, size: 30, background: tab)
            .overlay(Circle().strokeBorder(style == .ring ? account : .clear, lineWidth: 2))
            .frame(width: 50, height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tab))
    }

    private var tab: Color {
        style == .background ? AgentTabBarColors.blend(AgentTabBarColors.bar, account, 0.18) : AgentTabBarColors.bar
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(primary ? .white : OnboardingColors.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                primary ? OnboardingColors.accent : OnboardingColors.cardHovered))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                primary ? Color.clear : OnboardingColors.border))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// A small window showing where the tab bar sits for `position`.
private struct OnboardingTabBarSketch: View {
    let position: AgentTabBarSettings.Position

    private let faces: [Color] = [.working, .blocked, .done].map { AgentFaceView.color(for: $0) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let title: CGFloat = 14
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(Color(agentHex: 0x2a2c33))
                Rectangle().fill(Color(agentHex: 0x22242a)).frame(height: title)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(agentHex: 0x4a4e59)).frame(width: 5, height: 5) }
                }
                .offset(x: 7, y: 4.5)
                bar(width: width, height: height, title: title)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(agentHex: 0x3a3d47)))
        }
    }

    @ViewBuilder
    private func bar(width: CGFloat, height: CGFloat, title: CGFloat) -> some View {
        let dot: CGFloat = 9
        switch position {
        case .top:
            row(dot: dot).offset(x: 7, y: title + 5)
        case .titleBar:
            row(dot: 7).offset(x: 30, y: 3.5)
        case .bottom:
            row(dot: dot).offset(x: 7, y: height - dot - 6)
        case .left:
            column(dot: dot).offset(x: 6, y: title + 6)
        case .right:
            column(dot: dot).offset(x: width - dot - 6, y: title + 6)
        case .native:
            HStack(spacing: 2) {
                ForEach(faces.indices, id: \.self) { index in
                    HStack(spacing: 3) {
                        Circle().fill(faces[index]).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 1).fill(Color(agentHex: 0x6b707b)).frame(width: 18, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 11)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(index == 0 ? Color(agentHex: 0x363944) : Color(agentHex: 0x2a2c33)))
                }
            }
            .padding(.horizontal, 4)
            .frame(width: width)
            .offset(y: title + 2)
        }
    }

    private func row(dot: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(faces.indices, id: \.self) { Circle().fill(faces[$0]).frame(width: dot, height: dot) }
        }
    }

    private func column(dot: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(faces.indices, id: \.self) { Circle().fill(faces[$0]).frame(width: dot, height: dot) }
        }
    }
}
