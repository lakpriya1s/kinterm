import AppKit
import SwiftUI

// The menu the tab bar's "+" opens: new tab, new split, a new Claude Code
// or Codex tab per account, and options. See
// scope/designs/03-new-tab-menu.md.

/// Opens agent tabs: a new tab running the account's agent (`claude` with
/// its `CLAUDE_CONFIG_DIR`, `codex` with its `CODEX_HOME`), optionally in a
/// new git worktree.
enum AgentLauncher {
    private static let worktreeKey = "AgentNewTabInWorktree"
    private static let lastFolderKey = "AgentNewTabLastFolder"

    /// The folder last chosen in the menu. Remembered.
    static var lastFolder: String? {
        get { UserDefaults.ghostty.string(forKey: lastFolderKey) }
        set { UserDefaults.ghostty.set(newValue, forKey: lastFolderKey) }
    }

    /// Whether new agent tabs start in a new git worktree. Remembered.
    static var startInWorktree: Bool {
        get { UserDefaults.ghostty.bool(forKey: worktreeKey) }
        set { UserDefaults.ghostty.set(newValue, forKey: worktreeKey) }
    }

    /// Open a new tab next to `controller` running the account's agent, in
    /// `folder` (by default, see `defaultFolder`).
    static func newAgentTab(
        account: AgentAccount,
        from controller: BaseTerminalController,
        in folder: String? = nil,
        worktree: Bool
    ) {
        guard let window = controller.window else { return }
        let ghostty = controller.ghostty
        let pwd = folder ?? defaultFolder(for: controller)
        let agent = account.agent

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pwd
        if let folder = account.folder {
            // The whole tab uses this account, so running the agent again
            // later in the same tab keeps it.
            config.environmentVariables[agent.configVariable] = folder
        }

        // Typed into the shell rather than run as the tab's command, so the
        // shell stays when the agent exits, and a failing `git worktree add`
        // shows its error.
        if worktree, let root = gitRoot(of: pwd) {
            let stamp = Self.stamp()
            let path = "\(root).worktrees/agent-\(stamp)"
            config.initialInput = "git worktree add -b \(quote("agent/\(stamp)")) \(quote(path)) && cd \(quote(path)) && \(agent.command)\n"
        } else {
            config.initialInput = "\(agent.command)\n"
        }

        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }

    /// Where a new agent tab starts: the focused terminal's folder, unless
    /// that's the home folder or `/` (agents would ask to trust all of it).
    /// Then the folder last chosen in the menu, or the most recent project.
    static func defaultFolder(for controller: BaseTerminalController) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let pwd = controller.focusedSurface?.pwd.map { ($0 as NSString).standardizingPath }
        if let pwd, pwd != home, pwd != "/" { return pwd }
        if let last = lastFolder, fm.fileExists(atPath: last) { return last }
        return recentProjects().first ?? pwd ?? home
    }

    /// Folders the agents have worked in, most recent first, from every
    /// account. Leaves out the home folder, config folders and folders that
    /// no longer exist.
    static func recentProjects(limit: Int = 8) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var latest: [String: Date] = [:]

        func record(_ path: String, _ used: Date) {
            guard path != home, path != "/",
                  !(path as NSString).lastPathComponent.hasPrefix("."),
                  !path.contains("/.claude"), !path.contains("/.codex"),
                  // Scratch folders of agents run by other tools.
                  !["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: path.hasPrefix),
                  fm.fileExists(atPath: path) else { return }
            latest[path] = max(latest[path] ?? .distantPast, used)
        }

        for account in AgentAccountStore.shared.accounts {
            guard let folder = account.folder else { continue }
            switch account.agent {
            case .claude: claudeProjects(in: folder, record)
            case .codex: codexProjects(in: folder, record)
            }
        }

        return latest
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Claude Code's: its `.claude.json` lists them, and the matching
    /// folder in `projects/` was touched when it was last used.
    private static func claudeProjects(in folder: String, _ record: (String, Date) -> Void) {
        let fm = FileManager.default
        let config = URL(fileURLWithPath: folder).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return }
        for path in projects.keys {
            // Claude names the folder by replacing everything but letters
            // and digits with "-".
            let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let entry = URL(fileURLWithPath: folder).appendingPathComponent("projects/\(name)")
            let used = (try? fm.attributesOfItem(atPath: entry.path)[.modificationDate] as? Date) ?? .distantPast
            record(path, used)
        }
    }

    /// Codex's: each session's file in `sessions/<year>/<month>/<day>/`
    /// starts with the folder it ran in. Only the latest sessions are read,
    /// and not `codex exec` runs.
    private static func codexProjects(in folder: String, _ record: (String, Date) -> Void) {
        let fm = FileManager.default
        let sessions = URL(fileURLWithPath: folder).appendingPathComponent("sessions")
        // Newest first: the folders are named by date.
        func newest(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [URL] = []
        outer: for year in newest(sessions) {
            for month in newest(year) {
                for day in newest(month) {
                    files += newest(day).filter { $0.pathExtension == "jsonl" }
                    if files.count >= 40 { break outer }
                }
            }
        }
        for file in files.prefix(40) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = handle.readData(ofLength: 4096)
            try? handle.close()
            guard let text = String(data: head, encoding: .utf8),
                  !text.contains("\"source\":\"exec\""),
                  let range = text.range(of: #""cwd":"((?:[^"\\]|\\.)*)""#, options: .regularExpression)
            else { continue }
            let quoted = String(text[range].dropFirst(6))
            let data = Data("[\(quoted)]".utf8)
            guard let path = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first else { continue }
            let used = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
            record(path, used)
        }
    }

    /// Ask for a folder to start in.
    static func chooseFolder(attachedTo window: NSWindow?, startingAt folder: String, done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folder)
        panel.message = "Choose the folder the agent starts in"
        panel.prompt = "Choose"
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            done(url.path)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// How many tabs, in every window, have an agent on this account.
    static func runningCount(for id: String) -> Int {
        NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .filter { $0.programStatus?.account == id }
            .count
    }

    /// The top folder of the git repository `path` is in, if any.
    static func gitRoot(of path: String?) -> String? {
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let root = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return root.isEmpty ? nil : root
    }

    /// Ask for an agent's config folder and add it as an account.
    static func addAccount(_ agent: AgentKind, attachedTo window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Choose a \(agent.displayName) config folder (\(agent.configVariable)), e.g. ~/\(agent.folderPrefix)-work"
        panel.prompt = "Add Account"

        let add = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            AgentAccountStore.shared.add(folder: url, agent: agent)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    /// Make a new account: ask for a name, create `~/.claude-<name>` (or
    /// `~/.codex-<name>`) with our status hook, and open a tab running the
    /// agent in it, where the user logs in.
    static func newAccount(_ agent: AgentKind, from controller: BaseTerminalController) {
        let alert = NSAlert()
        alert.messageText = "New \(agent.displayName) Account"
        alert.informativeText = "Creates a \(agent.displayName) config folder and opens a tab to log in."

        // The name shown in menus and cards, and the folder's extension:
        // "work" makes ~/.claude-work. Left empty, the extension comes from
        // the name, shown as the placeholder while typing.
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Work"
        let extField = NSTextField(string: "")
        extField.placeholderString = "work"
        let prefix = NSTextField(labelWithString: "~/\(agent.folderPrefix)-")
        prefix.textColor = .secondaryLabelColor
        let folderRow = NSStackView(views: [prefix, extField])
        folderRow.spacing = 2
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Folder"), folderRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        extField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField

        let typing = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: nameField, queue: .main
        ) { _ in
            let slug = Self.folderExtension(nameField.stringValue)
            extField.placeholderString = slug.isEmpty ? "work" : slug
        }

        let done = { (response: NSApplication.ModalResponse) in
            NotificationCenter.default.removeObserver(typing)
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = Self.folderExtension(extField.stringValue.isEmpty ? name : extField.stringValue)
            guard !ext.isEmpty else { return }

            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("\(agent.folderPrefix)-\(ext)")
            do {
                try createConfig(for: agent, at: folder)
            } catch {
                let failed = NSAlert(error: error)
                failed.messageText = "Couldn't create \((folder.path as NSString).abbreviatingWithTildeInPath)"
                failed.runModal()
                return
            }
            let account = AgentAccountStore.shared.add(folder: folder, agent: agent)
            if !name.isEmpty { AgentAccountStore.shared.rename(account.id, to: name) }
            newAgentTab(account: account, from: controller, worktree: false)
        }
        if let window = controller.window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    /// A folder extension from what the user typed: lower case ASCII
    /// letters, digits, "-" and "_", so `.claude-<ext>` (or `.codex-<ext>`) is also a valid OSC 7501
    /// account. At most 24 characters.
    static func folderExtension(_ text: String) -> String {
        let mapped = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "-" }
        let slug = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(24))
    }

    /// Create an agent's config folder that runs our status hook
    /// (`AgentHookInstaller`). An existing folder is kept as it is.
    private static func createConfig(for agent: AgentKind, at folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try AgentHookInstaller.install(into: folder, for: agent)
    }

    /// Ask for a new name for an account.
    static func rename(_ account: AgentAccount, attachedTo window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Rename Account"
        alert.informativeText = account.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? account.id
        let field = NSTextField(string: account.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let done = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            AgentAccountStore.shared.rename(account.id, to: field.stringValue)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    // MARK: Shortcuts

    private static var shortcutMonitor: Any?

    /// ⌥⌘1 … ⌥⌘9 open an agent tab with the first nine accounts, in the
    /// menu's order.
    static func installShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.command, .option],
                  let digit = Self.digit(for: event.keyCode),
                  let controller = NSApp.keyWindow?.windowController as? TerminalController else { return event }
            let accounts = AgentAccountStore.shared.orderedAccounts
            guard digit <= accounts.count else { return event }
            newAgentTab(account: accounts[digit - 1], from: controller, worktree: startInWorktree)
            return nil
        }
    }

    /// The digit on a number-row key, by key code so it works with any
    /// layout and with Option held.
    private static func digit(for keyCode: UInt16) -> Int? {
        let codes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        return codes[keyCode]
    }

    static func shortcut(forAccountAt index: Int) -> String? {
        index < 9 ? "⌥⌘\(index + 1)" : nil
    }

    // MARK: Helpers

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Quote a value for the shell.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The design's colors for the menu.
private enum MenuColors {
    static let background = Color(agentHex: 0x26282f)
    static let border = Color(agentHex: 0x3a3d47)
    static let text = Color(agentHex: 0xe4e6ea)
    static let muted = Color(agentHex: 0x8a8f99)
    static let secondary = Color(agentHex: 0xa8adb7)
    static let disabled = Color(agentHex: 0x6f747e)
    static let highlight = Color(agentHex: 0x3b6fd8)
    static let highlightMuted = Color(agentHex: 0xdfe7ff)
}

/// The contents of the "+" menu.
struct AgentNewTabMenu: View {
    @ObservedObject private var store = AgentAccountStore.shared
    let controller: BaseTerminalController

    /// Recent project folders (Claude Code and Codex), read once when the menu opens.
    let recents: [String]

    /// Reopen the menu starting in a folder, after "Choose Folder…".
    let reopen: (String) -> Void
    let dismiss: () -> Void

    @State private var worktree = AgentLauncher.startInWorktree

    /// Where new agent tabs start. Starts as `AgentLauncher.defaultFolder`.
    @State private var folder: String

    /// Whether `folder` is in a git repository, so a worktree can be made.
    @State private var inGitRepo: Bool

    init(
        controller: BaseTerminalController,
        recents: [String],
        folder: String? = nil,
        reopen: @escaping (String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.controller = controller
        self.recents = recents
        self.reopen = reopen
        self.dismiss = dismiss
        let folder = folder ?? AgentLauncher.defaultFolder(for: controller)
        _folder = State(initialValue: folder)
        _inGitRepo = State(initialValue: AgentLauncher.gitRoot(of: folder) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentMenuItem(shortcut: "⌘T", action: run { (controller as? TerminalController)?.newTab(nil) }) {
                Text("New Tab")
            }
            AgentMenuItem(shortcut: "⌘D", action: run { controller.splitRight(self) }) {
                Text("New Split")
            }

            AgentMenuDivider()

            folderPicker

            ForEach(AgentKind.allCases) { agent in
                agentSection(agent)
            }

            AgentMenuDivider()

            Toggle(isOn: $worktree) {
                Text("Start in a new git worktree")
                    .font(.system(size: 13))
                    .foregroundColor(inGitRepo ? MenuColors.text : MenuColors.disabled)
            }
            .toggleStyle(.checkbox)
            .tint(MenuColors.highlight)
            .disabled(!inGitRepo)
            .help(inGitRepo ? "Create a worktree and branch next to the repository" : "This folder isn't in a git repository")
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .onChange(of: worktree) { AgentLauncher.startInWorktree = $0 }

            AgentMenuDivider()

            AgentMenuItem(shortcut: "later", enabled: false, action: {}, label: { Text("Gemini CLI") })
        }
        .padding(6)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MenuColors.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MenuColors.border, lineWidth: 1))
    }

    /// An agent's accounts, and making or adding one.
    @ViewBuilder
    private func agentSection(_ agent: AgentKind) -> some View {
        Text(agent.displayName.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.46)
            .foregroundColor(MenuColors.muted)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 12))

        ForEach(store.accounts(of: agent)) { account in
            AgentAccountMenuItem(
                account: account,
                running: AgentLauncher.runningCount(for: account.id),
                shortcut: AgentLauncher.shortcut(
                    forAccountAt: store.orderedAccounts.firstIndex(of: account) ?? Int.max),
                action: run {
                    AgentLauncher.newAgentTab(
                        account: account, from: controller, in: folder, worktree: worktree && inGitRepo)
                },
                rename: run { AgentLauncher.rename(account, attachedTo: controller.window) })
        }

        AgentMenuItem(textColor: MenuColors.secondary, action: run {
            AgentLauncher.newAccount(agent, from: controller)
        }) {
            Text("New \(agent.displayName) account…")
        }
        AgentMenuItem(textColor: MenuColors.secondary, action: run {
            AgentLauncher.addAccount(agent, attachedTo: controller.window)
        }) {
            Text("Add existing account…")
        }
    }

    /// The folder new agent tabs start in, as a row like the others so it
    /// looks clickable: folder name, its parent below, "Change ⌄" on the
    /// right. Clicking lists recent project folders and Choose Folder….
    private var folderPicker: some View {
        AgentMenuItem(shortcut: "Change ⌄", action: showFolderMenu) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text((folder as NSString).lastPathComponent)
                    .lineLimit(1)
                Text(Self.display((folder as NSString).deletingLastPathComponent))
                    .font(.system(size: 11.5))
                    .opacity(0.75)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Start in \(Self.display(folder)). Change folder")
    }

    /// A native menu at the pointer with the folders to choose from.
    private func showFolderMenu() {
        let menu = NSMenu()
        let pick = { (path: String) in setFolder(path) }

        if let current = controller.focusedSurface?.pwd, !recents.contains(current) {
            menu.addItem(ClosureMenuItem(Self.display(current) + "  (this terminal)", checked: current == folder) {
                pick(current)
            })
        }
        if !recents.isEmpty {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for path in recents {
                menu.addItem(ClosureMenuItem(Self.display(path), checked: path == folder) { pick(path) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Choose Folder…") {
            // The open panel is a sheet, so close this menu and open it
            // again in the chosen folder to pick the account.
            let window = controller.window
            let start = folder
            let reopen = self.reopen
            dismiss()
            DispatchQueue.main.async {
                AgentLauncher.chooseFolder(attachedTo: window, startingAt: start) { path in
                    AgentLauncher.lastFolder = path
                    reopen(path)
                }
            }
        })
        // popUp returns once the menu closes. Meanwhile its clicks land in
        // another window, which must not close the "+" menu.
        AgentMenuPanel.shared.showingFolderMenu = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        AgentMenuPanel.shared.showingFolderMenu = false
    }

    private func setFolder(_ path: String) {
        folder = path
        inGitRepo = AgentLauncher.gitRoot(of: path) != nil
        AgentLauncher.lastFolder = path
    }

    private static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Close the menu, then do `action`.
    private func run(_ action: @escaping () -> Void) -> () -> Void {
        return {
            dismiss()
            DispatchQueue.main.async(execute: action)
        }
    }
}

private struct AgentMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(MenuColors.border)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// One row: highlighted in blue on hover, with a shortcut on the right.
private struct AgentMenuItem<Label: View>: View {
    var shortcut: String?
    var enabled = true
    var textColor = MenuColors.text
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundColor(highlighted ? MenuColors.highlightMuted : MenuColors.muted)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(enabled ? (highlighted ? .white : textColor) : MenuColors.disabled)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? MenuColors.highlight : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var highlighted: Bool { enabled && hovering }
}

/// An account row: color swatch, name, and "folder · N running".
private struct AgentAccountMenuItem: View {
    let account: AgentAccount
    let running: Int
    let shortcut: String?
    let action: () -> Void
    let rename: () -> Void

    var body: some View {
        AgentMenuItem(shortcut: shortcut, action: action) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(account.swiftUIColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                Text(detail)
                    .font(.system(size: 11.5))
                    .opacity(0.75)
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button("Rename…", action: rename)
            AgentAccountColorMenu(account: account, title: "Color")
            Divider()
            Button("Remove") { AgentAccountStore.shared.remove(account.id) }
        }
    }

    /// "~/.claude-work · 2 running", like the design.
    private var detail: String {
        let folder = account.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? account.id
        return running > 0 ? "\(folder) · \(running) running" : folder
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() { handler() }
}

/// A floating panel that shows the "+" menu under (or beside) the button.
/// Clicking outside it or pressing Escape closes it.
final class AgentMenuPanel {
    static let shared = AgentMenuPanel()

    /// A borderless panel can't become key by default, and it must, so its
    /// rows get hover and clicks like a menu.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private lazy var panel: NSPanel = {
        let panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        return panel
    }()

    private weak var parent: NSWindow?
    private var monitor: Any?
    private var hiddenAt: Date = .distantPast

    /// True while the folder list is open over the menu.
    var showingFolderMenu = false

    /// Open the menu, or close it if it's open. Clicking "+" while the menu
    /// is open first closes it (the click is outside it), so a click that
    /// comes right after closing doesn't open it again.
    func toggle(for controller: BaseTerminalController, barEdge: Edge, anchor: CGRect) {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(hiddenAt) > 0.25 {
            show(for: controller, barEdge: barEdge, anchor: anchor)
        }
    }

    func show(for controller: BaseTerminalController, barEdge: Edge, anchor: CGRect, folder: String? = nil) {
        guard let window = controller.window else { return }
        hide()

        let menu = AgentNewTabMenu(
            controller: controller,
            recents: AgentLauncher.recentProjects(),
            folder: folder,
            reopen: { [weak self, weak controller] path in
                guard let self, let controller else { return }
                self.show(for: controller, barEdge: barEdge, anchor: anchor, folder: path)
            },
            dismiss: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: menu.fixedSize())
        host.frame.size = host.fittingSize
        panel.contentView = host

        let size = host.fittingSize
        let origin = anchor.popupOrigin(size: size, awayFrom: barEdge, gap: 6, on: window.screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        window.addChildWindow(panel, ordered: .above)
        parent = window
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.hide()
                    return nil
                }
                return event
            }
            // A click outside the menu closes it. A right-click on a row
            // opens its context menu, which is a separate window.
            if event.window !== self.panel, !self.showingFolderMenu { self.hide() }
            return event
        }
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard panel.isVisible else { return }
        hiddenAt = Date()
        let parent = self.parent
        parent?.removeChildWindow(panel)
        self.parent = nil
        panel.orderOut(nil)
        parent?.makeKey()
    }
}

/// Where a SwiftUI view is on screen, read from a plain AppKit view behind
/// it (`AgentScreenAnchorView`). SwiftUI's global coordinates don't start at
/// the content view in every window style (the title bar can shift them), so
/// converting those put popups too far from the bar.
final class AgentScreenAnchor {
    fileprivate weak var view: NSView?

    var screenRect: NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct AgentScreenAnchorView: NSViewRepresentable {
    let anchor: AgentScreenAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    /// Only measures; clicks and hovers go to the SwiftUI view in front.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

extension NSRect {
    /// Where a popup of `size` goes next to this rect (in screen
    /// coordinates), on the side away from a tab bar at `barEdge`: below a
    /// bar at the top, above one at the bottom, beside one on the left or
    /// right. Kept on `screen`.
    func popupOrigin(size: NSSize, awayFrom barEdge: Edge, gap: CGFloat, on screen: NSScreen?) -> NSPoint {
        // Beside the bar, the gap is a little wider to clear its border.
        let sideGap = gap + 2
        var origin: NSPoint
        switch barEdge {
        case .top: origin = NSPoint(x: minX, y: minY - gap - size.height)
        case .bottom: origin = NSPoint(x: minX, y: maxY + gap)
        case .leading: origin = NSPoint(x: maxX + sideGap, y: maxY - size.height)
        case .trailing: origin = NSPoint(x: minX - sideGap - size.width, y: maxY - size.height)
        }

        if let screen = screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        return origin
    }
}

extension Edge {
    var opposite: Edge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    /// The alignment that puts a view against this edge.
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}
