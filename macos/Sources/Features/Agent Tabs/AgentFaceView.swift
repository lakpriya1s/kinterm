import SwiftUI

/// A small animated face that shows what a program in a tab, usually a coding
/// agent, is doing. Every state has its own color, expression and motion, so
/// the states can be told apart without relying on color alone.
///
/// The face is drawn on the design's 40x40 grid and scaled to `size`. The
/// canvas is 7 grid units larger on every side so the spinner ring, the pulse,
/// the "z", the "?" and the unread dot have room.
/// See scope/designs/02-agent-faces.md for the design, and
/// scope/designs/06-face-sets.md for the other sets (AgentFaceSets.swift).
struct AgentFaceView: View {
    typealias State = Ghostty.Action.ProgramStatus.State
    typealias Style = AgentTabBarSettings.FaceStyle

    let state: State
    var size: CGFloat

    /// The color behind the face, used to cut out the unread dot.
    var background: Color

    /// Which faces move. Each animation frame lays out the whole window, so
    /// faces nobody can see stay still.
    var motion: Motion

    /// A face set to draw instead of the chosen one, for previews.
    var styleOverride: Style?

    /// How many agents the face stands for, such as two side by side in
    /// splits, and how many shells they left running in the background,
    /// such as a dev server, and how many subagents it's running. Shown as
    /// badges; see `drawBadges`.
    var agents: Int
    var shells: Int
    var subagents: Int

    @ObservedObject private var settings = AgentTabBarSettings.shared

    init(
        state: State, size: CGFloat = 40, background: Color = AgentTabBarColors.bar, motion: Motion = .all,
        style: Style? = nil, agents: Int = 1, shells: Int = 0, subagents: Int = 0
    ) {
        self.state = state
        self.size = size
        self.background = background
        self.motion = motion
        self.styleOverride = style
        self.agents = agents
        self.shells = shells
        self.subagents = subagents
    }

    private var style: Style { styleOverride ?? settings.faceStyle }

    enum Motion {
        /// Every state that moves.
        case all

        /// Only working and waiting, which should still catch the eye from
        /// another app. The idle "z" holds still.
        case attention

        /// Nothing moves.
        case none
    }

    /// Grid units around the face reserved for rings and badges.
    static let pad: CGFloat = 7

    /// The width and height of the view for a face of the given size.
    static func side(for size: CGFloat) -> CGFloat {
        size + pad * 2 * size / 40
    }

    var body: some View {
        let scale = size / 40
        TimelineView(.animation(minimumInterval: frameInterval, paused: frameInterval == nil)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, _ in
                gc.scaleBy(x: scale, y: scale)
                gc.translateBy(x: Self.pad, y: Self.pad)
                // The faces move the context around, the badges stay put.
                var badges = gc
                switch style {
                case .faces: draw(in: &gc, time: time)
                case .squares: drawSquare(in: &gc, time: time)
                case .orbs: drawOrb(in: &gc, time: time)
                case .shapes: drawShape(in: &gc, time: time)
                case .bots: drawBot(in: &gc, time: time)
                case .spark: drawSpark(in: &gc, time: time)
                }
                drawBadges(in: &badges)
            }
        }
        .frame(width: Self.side(for: size), height: Self.side(for: size))
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
    }

    /// How often to redraw. Faces that don't move aren't redrawn.
    private var frameInterval: Double? {
        switch (state, motion) {
        case (_, .none): return nil
        case (.working, _), (.blocked, _): return 1.0 / 30
        // Bots sleep still; every other set's idle face breathes or fades.
        case (.idle, .all): return style == .bots ? nil : 1.0 / 12
        // A short shake every 2.4s needs more frames than breathing.
        case (.error, .all): return style == .faces ? nil : 1.0 / 24
        default: return nil
        }
    }

    private var accessibilityText: String {
        var parts: [String]
        switch state {
        case .idle: parts = ["Idle"]
        case .working: parts = ["Working"]
        case .done: parts = ["Done"]
        case .blocked: parts = ["Waiting on you"]
        case .error: parts = ["Error"]
        case .clear: parts = []
        }
        if agents > 1 { parts.append("\(agents) agents") }
        if shells > 0 { parts.append("\(shells) \(shells == 1 ? "shell" : "shells") running") }
        if subagents > 0 { parts.append("\(subagents) \(subagents == 1 ? "subagent" : "subagents") running") }
        return parts.joined(separator: ", ")
    }

    // MARK: Colors

    static let ink = Color(agentHex: 0x15161b)

    static func color(for state: State) -> Color {
        switch state {
        case .idle, .clear: return Color(agentHex: 0x8b9099)
        case .working: return Color(agentHex: 0x5ca0ff)
        case .blocked: return Color(agentHex: 0xf5a524)
        case .done: return Color(agentHex: 0x3fb950)
        case .error: return Color(agentHex: 0xf85149)
        }
    }

    // MARK: Motion

    /// 0 at the start and end of each period, 1 in the middle, eased like
    /// CSS `ease-in-out` keyframes at 0%, 50% and 100%.
    static func wave(_ time: TimeInterval, period: Double) -> Double {
        (1 - cos(2 * .pi * time / period)) / 2
    }

    // MARK: Drawing

    private func draw(in gc: inout GraphicsContext, time: TimeInterval) {
        let color = Self.color(for: state)
        let ink = GraphicsContext.Shading.color(Self.ink)
        let line = StrokeStyle(lineWidth: 2.5, lineCap: .butt)

        if state == .blocked {
            // Bounces up 2 units and pulses: a solid ring that grows to 7
            // units while fading out, every 1.5s.
            gc.translateBy(x: 0, y: -2 * Self.wave(time, period: 1.5))
            let pulse = Self.wave(time, period: 1.5)
            let radius = 20 + 7 * pulse
            gc.fill(
                Path(ellipseIn: CGRect(x: 20 - radius, y: 20 - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(0.55 * (1 - pulse))))
        }

        if state == .working {
            // A 2.5 unit ring 6 units outside the face. The top quarter is
            // solid and turns once every 0.9s.
            let radius: CGFloat = 26 - 1.25
            let track = Path(ellipseIn: CGRect(x: 20 - radius, y: 20 - radius, width: radius * 2, height: radius * 2))
            gc.stroke(track, with: .color(color.opacity(0.18)), lineWidth: 2.5)
            let turn = (time / 0.9).truncatingRemainder(dividingBy: 1) * 360
            var arc = Path()
            arc.addArc(center: CGPoint(x: 20, y: 20), radius: radius,
                       startAngle: .degrees(-135 + turn), endAngle: .degrees(-45 + turn), clockwise: false)
            gc.stroke(arc, with: .color(color), lineWidth: 2.5)
        }

        if state != .clear {
            gc.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: 40, height: 40)), with: .color(color))
        }

        switch state {
        case .clear:
            break

        case .idle:
            // Eyes closed, small mouth, and a "z" that drifts and fades.
            gc.fill(Path(roundedRect: CGRect(x: 10, y: 18, width: 7, height: 2.5), cornerRadius: 1.25), with: ink)
            gc.fill(Path(roundedRect: CGRect(x: 23, y: 18, width: 7, height: 2.5), cornerRadius: 1.25), with: ink)
            gc.fill(Path(roundedRect: CGRect(x: 17, y: 26, width: 6, height: 2.5), cornerRadius: 1.25), with: ink)
            let drift = Self.wave(time, period: 2.6)
            var z = gc
            z.opacity = 0.25 + 0.75 * drift
            z.draw(
                Text("z").font(.system(size: 11, weight: .bold)).foregroundColor(Color(agentHex: 0xa8adb7)),
                at: CGPoint(x: 42 + 2 * drift, y: -2.5 + 2 - 4 * drift))

        case .working:
            // Eyes look left and right every 1.3s.
            let look = -1.5 * cos(2 * .pi * time / 1.3)
            gc.fill(Path(roundedRect: CGRect(x: 11 + look, y: 14, width: 5, height: 8), cornerRadius: 2.5), with: ink)
            gc.fill(Path(roundedRect: CGRect(x: 24 + look, y: 14, width: 5, height: 8), cornerRadius: 2.5), with: ink)
            gc.fill(Path(roundedRect: CGRect(x: 16.5, y: 26, width: 7, height: 2.5), cornerRadius: 1.25), with: ink)

        case .blocked:
            // Surprised: big eyes, an "o" mouth and a "?".
            gc.fill(Path(roundedRect: CGRect(x: 11, y: 12, width: 6, height: 9), cornerRadius: 3), with: ink)
            gc.fill(Path(roundedRect: CGRect(x: 23, y: 12, width: 6, height: 9), cornerRadius: 3), with: ink)
            gc.stroke(Path(ellipseIn: CGRect(x: 16.75, y: 26.25, width: 6.5, height: 6.5)), with: ink, lineWidth: 2.5)
            gc.draw(
                Text("?").font(.system(size: 14, weight: .heavy)).foregroundColor(color),
                at: CGPoint(x: 42, y: -1.5))

        case .done:
            // Happy: arched eyes and a smile, plus a white dot until it's seen.
            var eyes = Path()
            for center in [13.5, 26.5] {
                eyes.move(to: CGPoint(x: center - 3.25, y: 20))
                eyes.addArc(center: CGPoint(x: center, y: 19.5), radius: 3.25,
                            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                eyes.addLine(to: CGPoint(x: center + 3.25, y: 20))
            }
            gc.stroke(eyes, with: ink, style: line)
            var smile = Path()
            smile.addArc(center: CGPoint(x: 20, y: 22), radius: 6.75,
                         startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            gc.stroke(smile, with: ink, style: line)
            drawUnreadDot(in: &gc)

        case .error:
            // X eyes and a frown.
            var eyes = Path()
            for center in [13.25, 27.25] {
                eyes.move(to: CGPoint(x: center - 3.54, y: 17 - 3.54))
                eyes.addLine(to: CGPoint(x: center + 3.54, y: 17 + 3.54))
                eyes.move(to: CGPoint(x: center + 3.54, y: 17 - 3.54))
                eyes.addLine(to: CGPoint(x: center - 3.54, y: 17 + 3.54))
            }
            gc.stroke(eyes, with: ink, style: line)
            var frown = Path()
            frown.addArc(center: CGPoint(x: 20, y: 32), radius: 4.75,
                         startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            gc.stroke(frown, with: ink, style: line)
        }
    }

    static let agentsBadgeColor = Color(agentHex: 0xa8adb7)
    static let shellsBadgeColor = Color(agentHex: 0x5ca0ff)

    static let subagentsBadgeColor = Color(agentHex: 0xb48cff)

    /// The badges at the bottom right: how many subagents are running, in
    /// purple, how many agents, when more than one, in gray, and how many
    /// shells, in blue. Alone, a badge shows its count. Together they stack
    /// in that order: the front badge shows its count and the ones behind
    /// it peek out to its left without theirs.
    private func drawBadges(in gc: inout GraphicsContext) {
        guard state != .clear else { return }
        var badges: [(color: Color, count: Int)] = []
        if subagents > 0 { badges.append((Self.subagentsBadgeColor, subagents)) }
        if agents > 1 { badges.append((Self.agentsBadgeColor, agents)) }
        if shells > 0 { badges.append((Self.shellsBadgeColor, shells)) }
        let front = CGRect(x: 27, y: 27, width: 16, height: 16)
        // Back to front, so each badge is cut out of the ones behind it.
        for (i, badge) in badges.enumerated().reversed() {
            drawBadge(
                in: &gc, front.offsetBy(dx: CGFloat(-6 * i), dy: 0), color: badge.color,
                count: i == 0 ? badge.count : nil)
        }
    }

    /// A 16 unit badge with its count if given, cut out of what's under it
    /// so it reads on any background.
    private func drawBadge(in gc: inout GraphicsContext, _ rect: CGRect, color: Color, count: Int?) {
        var cut = gc
        cut.blendMode = .clear
        cut.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.black))
        gc.fill(Path(ellipseIn: rect), with: .color(color))
        guard let count else { return }
        gc.draw(
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: count > 9 ? 9 : 12, weight: .heavy))
                .foregroundColor(Self.ink),
            at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The white dot on a done face until it's seen, cut out of the
    /// background. `origin` is the top left of the 15 unit cutout.
    func drawUnreadDot(in gc: inout GraphicsContext, at origin: CGPoint = CGPoint(x: 28, y: -3)) {
        gc.fill(Path(ellipseIn: CGRect(x: origin.x, y: origin.y, width: 15, height: 15)), with: .color(background))
        gc.fill(Path(ellipseIn: CGRect(x: origin.x + 2, y: origin.y + 2, width: 11, height: 11)),
                with: .color(Color(agentHex: 0xf1f2f4)))
    }
}

/// The face for a tab without an agent: a plain terminal prompt, drawn in the
/// chosen face set's style.
struct ShellGlyphView: View {
    var size: CGFloat = 40

    /// A face set to draw instead of the chosen one, for previews.
    var styleOverride: AgentTabBarSettings.FaceStyle?

    @ObservedObject private var settings = AgentTabBarSettings.shared

    init(size: CGFloat = 40, style: AgentTabBarSettings.FaceStyle? = nil) {
        self.size = size
        self.styleOverride = style
    }

    var body: some View {
        let style = styleOverride ?? settings.faceStyle
        if style == .faces {
            facesGlyph
        } else {
            let scale = size / 40
            Canvas { gc, _ in
                gc.scaleBy(x: scale, y: scale)
                AgentFaceSets.drawShell(style, in: &gc)
            }
            .frame(width: size, height: size)
        }
    }

    private var facesGlyph: some View {
        let scale = size / 40
        return RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
            .fill(Color(agentHex: 0x2a2c33))
            .overlay(
                RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
                    .strokeBorder(Color(agentHex: 0x4a4e59), lineWidth: 1.5 * scale))
            .overlay(
                Text(">_")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(agentHex: 0xc2c6cf)))
            .frame(width: size, height: size)
    }
}

/// The face shown in a native macOS tab's accessory area. Shows nothing when
/// no program in the tab reports its status.
struct AgentTabFaceView: View {
    let status: Ghostty.Action.ProgramStatus?

    var body: some View {
        if let status, status.state != .clear {
            AgentFaceView(state: status.state, size: 16, background: .clear)
        }
    }
}

extension Color {
    /// A color from a 0xRRGGBB value, as written in the design.
    init(agentHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity)
    }
}

extension Ghostty.Action.ProgramStatus {
    /// A short label for the state, for tooltips and menus.
    var stateLabel: String {
        switch state {
        case .idle: return "Idle"
        case .working: return "Working"
        case .done: return "Done · unread"
        case .error: return "Error"
        case .clear: return ""
        case .blocked:
            switch kind {
            case .permission: return "Waiting on you (permission)"
            case .question: return "Waiting on you (question)"
            case .auth: return "Waiting on you (sign in)"
            case nil: return "Waiting on you"
            }
        }
    }

    /// Text for the native tab's tooltip.
    var tooltip: String {
        var lines = ["\(appDisplayName) · \(stateLabel)"]
        if let title { lines.append(title) }
        if let msg { lines.append(msg) }
        lines.append("Since \(since.formatted(date: .omitted, time: .shortened))")
        return lines.joined(separator: "\n")
    }
}
