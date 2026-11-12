import Combine
import Foundation
import SwiftUI

/// A coding agent KinTerm opens tabs for and shows the status of.
enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The command that starts it.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// The environment variable naming an account's config folder.
    var configVariable: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    /// Config folders are `~/<prefix>` and `~/<prefix>-<name>`.
    var folderPrefix: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        }
    }

    /// What its status hook reports as `app` in OSC 7501.
    var appID: String {
        switch self {
        case .claude: return "claude-code"
        case .codex: return "codex"
        }
    }

    /// Files that show a folder holds this agent's config.
    fileprivate var markers: [String] {
        switch self {
        case .claude: return ["settings.json", ".claude.json", "projects"]
        case .codex: return ["config.toml", "auth.json", "sessions"]
        }
    }

    /// The agent whose config folder this is, from its name.
    static func forFolder(named name: String) -> AgentKind? {
        allCases.first { name == $0.folderPrefix || name.hasPrefix($0.folderPrefix + "-") }
    }

    /// The agent that reports this `app` in OSC 7501.
    static func forApp(_ app: String?) -> AgentKind? {
        allCases.first { $0.appID == app }
    }
}

/// One account of a coding agent, such as a Claude Code or Codex config
/// folder. Its color is the ring around the face of every tab that uses it.
struct AgentAccount: Codable, Identifiable, Equatable {
    /// What the agent reports as `account` in OSC 7501: the config folder's
    /// name, e.g. ".claude-work" or ".codex".
    let id: String

    /// The name shown in the hover card and menus, e.g. "work".
    var name: String

    /// The ring color, 0xRRGGBB.
    var color: UInt32

    /// The config folder, if known, e.g. "~/.claude-work".
    var folder: String?

    /// Which agent it's an account of. Accounts saved before Codex was
    /// supported are Claude Code's.
    var agent: AgentKind

    var swiftUIColor: Color { Color(agentHex: color) }

    /// The agent and the account, for cards and lists where agents mix:
    /// "Claude Code · work", or just "Codex" for a default account.
    var label: String {
        name == "default" ? agent.displayName : "\(agent.displayName) · \(name)"
    }

    init(id: String, name: String, color: UInt32, folder: String?, agent: AgentKind) {
        self.id = id
        self.name = name
        self.color = color
        self.folder = folder
        self.agent = agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(UInt32.self, forKey: .color)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
            ?? AgentKind.forFolder(named: id) ?? .claude
    }
}

/// The accounts the app knows about. Shared by all windows and kept across
/// launches.
///
/// It works without any setup: on first use it adds every `~/.claude*`
/// folder that holds a Claude config and every `~/.codex*` folder that
/// holds a Codex config, and an account the app hasn't seen yet is added
/// the first time an agent reports it. Each new account gets the next
/// color from `palette`.
final class AgentAccountStore: ObservableObject {
    static let shared = AgentAccountStore()

    /// Ring colors for new accounts, in order. The first two are the design's
    /// Work and Personal colors. None of them is a face's state color.
    static let palette: [UInt32] = colorNames.map(\.color)

    /// The colors an account can be given by name. Any other color can be
    /// picked from the color panel.
    static let colorNames: [(name: String, color: UInt32)] = [
        ("Violet", 0x8b7cf6), ("Teal", 0x2dd4bf), ("Pink", 0xf472b6),
        ("Sand", 0xd4a373), ("Lavender", 0xa5b4fc), ("White", 0xe2e8f0),
        ("Indigo", 0x6366f1), ("Fuchsia", 0xd946ef), ("Cyan", 0x22d3ee),
        ("Lime", 0xa3e635), ("Mint", 0x6ee7b7), ("Peach", 0xfdba74),
        ("Copper", 0xb87333), ("Plum", 0x9d4edd), ("Slate", 0x94a3b8),
        ("Olive", 0x9ca35c),
    ]

    private static let key = "AgentAccounts"

    /// Set once Codex's folders have been added to accounts saved before
    /// KinTerm knew Codex, so a Codex account you remove stays removed.
    private static let codexAddedKey = "AgentAccountsCodexAdded"

    @Published private(set) var accounts: [AgentAccount] {
        didSet {
            if let data = try? JSONEncoder().encode(accounts) {
                UserDefaults.ghostty.set(data, forKey: Self.key)
            }
            AgentTabBarModel.setNeedsRefresh()
        }
    }

    private init() {
        if let data = UserDefaults.ghostty.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([AgentAccount].self, from: data) {
            accounts = saved
        } else {
            accounts = []
            for folder in Self.configFolders(for: .claude) {
                add(id: folder.lastPathComponent, folder: folder.path, agent: .claude)
            }
        }
        if !UserDefaults.ghostty.bool(forKey: Self.codexAddedKey) {
            for folder in Self.configFolders(for: .codex) where !accounts.contains(where: { $0.id == folder.lastPathComponent }) {
                add(id: folder.lastPathComponent, folder: folder.path, agent: .codex)
            }
            UserDefaults.ghostty.set(true, forKey: Self.codexAddedKey)
        }
    }

    /// One agent's accounts, in order.
    func accounts(of agent: AgentKind) -> [AgentAccount] {
        accounts.filter { $0.agent == agent }
    }

    /// Every account, grouped by agent in the menu's order: what ⌥⌘1–9 open.
    var orderedAccounts: [AgentAccount] {
        AgentKind.allCases.flatMap { accounts(of: $0) }
    }

    /// The account with this id, added if it's new.
    func account(for id: String, app: String? = nil) -> AgentAccount {
        if let account = accounts.first(where: { $0.id == id }) { return account }
        let agent = AgentKind.forFolder(named: id) ?? AgentKind.forApp(app) ?? .claude
        return add(id: id, folder: Self.configFolder(named: id, for: agent)?.path, agent: agent)
    }

    func setColor(_ color: UInt32, for id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].color = color
    }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
    }

    /// Add a config folder the user picked. Its id is the folder's name,
    /// which is what the hook reports. Returns the existing account if the
    /// folder is already known.
    @discardableResult
    func add(folder: URL, agent: AgentKind) -> AgentAccount {
        let id = folder.lastPathComponent
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].folder = folder.path
            accounts[index].agent = agent
            return accounts[index]
        }
        return add(id: id, folder: folder.path, agent: agent)
    }

    @discardableResult
    private func add(id: String, folder: String?, agent: AgentKind) -> AgentAccount {
        let used = Set(accounts.map(\.color))
        let color = Self.palette.first { !used.contains($0) }
            ?? Self.palette[accounts.count % Self.palette.count]
        let account = AgentAccount(id: id, name: Self.name(for: id), color: color, folder: folder, agent: agent)
        accounts.append(account)
        return account
    }

    /// A short name from a folder name: ".claude" and ".codex" are
    /// "default", ".claude-work" and ".codex-work" are "work".
    static func name(for id: String) -> String {
        guard let agent = AgentKind.forFolder(named: id) else { return id }
        if id == agent.folderPrefix { return "default" }
        return String(id.dropFirst(agent.folderPrefix.count + 1))
    }

    /// `~/.claude` and every `~/.claude-*` folder that holds a Claude
    /// config, or the same for Codex's `~/.codex*`.
    static func configFolders(for agent: AgentKind) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let prefix = agent.folderPrefix
        return names
            .filter { AgentKind.forFolder(named: $0) == agent }
            .sorted { ($0 == prefix ? "" : $0) < ($1 == prefix ? "" : $1) }
            .compactMap { configFolder(named: $0, for: agent) }
    }

    /// `~/<name>` if it is a folder that holds the agent's config.
    private static func configFolder(named name: String, for agent: AgentKind) -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard agent.markers.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) else { return nil }
        return url
    }
}
