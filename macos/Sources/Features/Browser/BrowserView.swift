import AppKit
import SwiftUI

/// A browser: a toolbar over the page.
struct BrowserView: View {
    @ObservedObject var page: BrowserPage

    enum Placement { case panel, tile, window }

    /// Beside a terminal, a grid tile, or its own window. The tile has its
    /// own header with close and pop-out buttons, and its DevTools are a
    /// tile of their own instead of docked under the page.
    var placement: Placement = .panel

    private var docksDevTools: Bool { placement != .tile }

    @ObservedObject private var center = BrowserCenter.shared

    let close: () -> Void

    /// Into a window of its own, or (from the window) back beside the
    /// terminal.
    var popOut: (() -> Void)?

    @State private var address = ""
    @State private var editing = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ReviewColors.border)
            ZStack {
                BrowserContent(view: page.container)
                if let problem = page.problem { problemView(problem) }
            }
            .overlay {
                if page.agentActive {
                    AgentGlow().transition(.opacity.animation(.easeInOut(duration: 0.35)))
                }
            }
            if docksDevTools, page.devTools == .docked {
                DevToolsResizeHandle(height: $center.devToolsHeight)
                BrowserDevTools(page: page)
                    .frame(height: center.devToolsHeight)
            }
        }
        .background(ReviewColors.background)
        .onAppear { address = page.url }
        .onChange(of: page.url) { url in if !editing { address = url } }
        .onChange(of: addressFocused) { page.addressFocused = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddress)) { note in
            guard (note.object as? BrowserPage) === page else { return }
            addressFocused = true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            BrowserButton(symbol: "chevron.left", help: "Back", enabled: page.canGoBack) { page.run(.back) }
            BrowserButton(symbol: "chevron.right", help: "Forward", enabled: page.canGoForward) { page.run(.forward) }
            if page.isLoading {
                BrowserButton(symbol: "xmark", help: "Stop") { page.run(.stop) }
            } else {
                BrowserButton(symbol: "arrow.clockwise", help: "Reload (⇧-click to bypass the cache)") {
                    page.run(NSEvent.modifierFlags.contains(.shift) ? .hardReload : .reload)
                }
            }

            TextField("Address, port or search", text: $address, onEditingChanged: { editing = $0 })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(ReviewColors.text)
                .focused($addressFocused)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(ReviewColors.surface))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                    addressFocused ? ReviewColors.accent.opacity(0.7) : ReviewColors.border, lineWidth: 1))
                .onSubmit {
                    page.load(address)
                    address = page.url
                    page.focus()
                }
                .onExitCommand {
                    address = page.url
                    page.focus()
                }
                .padding(.horizontal, 4)

            if page.agentActive {
                HStack(spacing: 3) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 9, weight: .semibold))
                    Text("Agent").font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(ReviewColors.accent))
                .help("An agent is using this page")
                .transition(.opacity)
            }

            if !page.consoleErrors.isEmpty {
                Button {
                    page.showDevTools()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                        Text("\(page.consoleErrors.count)").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(ReviewColors.removedText)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(Capsule().fill(ReviewColors.removedLine))
                }
                .buttonStyle(.plain)
                .help("Console errors: \(page.consoleErrors.last ?? "")\nClick for DevTools")
            }

            BrowserButton(
                symbol: page.picking ? "scope" : "cursorarrow.rays",
                help: page.picking
                    ? "Stop Picking (Esc)"
                    : "Pick Elements for the Agent: click one to send it to this tab's agent, ⇧-click to pick several",
                active: page.picking
            ) { page.togglePicker() }
            BrowserButton(
                symbol: page.devTools == nil ? "hammer" : "hammer.fill",
                help: page.devTools == nil ? "DevTools: Elements, Console, Network… (⌥⌘I)" : "Close DevTools (⌥⌘I)"
            ) { page.toggleDevTools() }
            BrowserButton(symbol: "safari", help: "Open in Your Default Browser") {
                if let url = URL(string: page.url) { NSWorkspace.shared.open(url) }
            }
            switch placement {
            case .panel:
                if let popOut {
                    BrowserButton(symbol: "macwindow.on.rectangle", help: "Open in Its Own Window", action: popOut)
                }
                BrowserButton(symbol: "xmark.circle", help: "Close Browser (⌘⇧B)", action: close)
            case .window:
                if let popOut {
                    BrowserButton(symbol: "sidebar.trailing", help: "Put Back Beside the Terminal", action: popOut)
                }
            case .tile:
                EmptyView()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(ReviewColors.surface)
    }

    private func problemView(_ problem: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(ReviewColors.secondary)
            Text(problem)
                .font(.system(size: 12))
                .foregroundColor(ReviewColors.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if BrowserEngine.isInstalled {
                Button("Try Again") { page.run(.reload) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReviewColors.background)
    }
}

/// While an agent drives the page: KinTerm blue glowing in from the edges,
/// breathing slowly. Only on screen (and animating) while the agent works.
private struct AgentGlow: View {
    @State private var bright = false

    var body: some View {
        ZStack {
            // A wide soft haze, a tighter glow, and a crisp edge.
            Rectangle().strokeBorder(KinTermBrand.blue.opacity(0.55), lineWidth: 26).blur(radius: 22)
            Rectangle().strokeBorder(KinTermBrand.blue.opacity(0.7), lineWidth: 8).blur(radius: 6)
            Rectangle().strokeBorder(KinTermBrand.blue, lineWidth: 1.5)
        }
        .clipped()
        .opacity(bright ? 1 : 0.55)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

/// A page's DevTools with a small header: docked under the page, or a grid
/// tile's body.
struct BrowserDevTools: View {
    @ObservedObject var page: BrowserPage

    /// The grid tile has its own header.
    var showsHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill").font(.system(size: 9)).foregroundColor(ReviewColors.secondary)
                    Text("DevTools").font(.system(size: 11, weight: .semibold)).foregroundColor(ReviewColors.text)
                    Spacer()
                    BrowserButton(symbol: "macwindow.on.rectangle", help: "Open DevTools in Their Own Window") {
                        page.showDevTools(docked: false)
                    }
                    BrowserButton(symbol: "xmark", help: "Close DevTools (⌥⌘I)") { page.closeDevTools() }
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(ReviewColors.surface)
            }
            BrowserContent(view: page.devToolsContainer)
        }
    }
}

/// The edge between the page and docked DevTools: drag to resize.
private struct DevToolsResizeHandle: View {
    @Binding var height: CGFloat

    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? ReviewColors.accent.opacity(0.6) : ReviewColors.border)
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? height
                        if start == nil { start = height }
                        height = min(1200, max(120, from - value.translation.height))
                    }
                    .onEnded { _ in start = nil })
    }
}

/// A Chromium view: the page, or its DevTools.
struct BrowserContent: NSViewRepresentable {
    let view: BrowserContainerView

    func makeNSView(context: Context) -> BrowserContainerView { view }

    func updateNSView(_ nsView: BrowserContainerView, context: Context) {}
}

struct BrowserButton: View {
    let symbol: String
    let help: String
    var enabled = true
    /// On, like a mode that's in use.
    var active = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? ReviewColors.accent
                    : enabled ? (hovering ? ReviewColors.text : ReviewColors.secondary) : ReviewColors.secondary.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(
                    active ? ReviewColors.accent.opacity(0.18) : hovering && enabled ? ReviewColors.hovered : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Notification.Name {
    /// Put the keyboard in a page's address field (⌘L). The object is the
    /// BrowserPage.
    static let browserFocusAddress = Notification.Name("KinTermBrowserFocusAddress")
}
