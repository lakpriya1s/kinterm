import SwiftUI
import GhosttyKit

extension Ghostty {
    struct Action {}
}

extension Ghostty.Action {
    struct ColorChange {
        let kind: Kind
        let color: Color

        enum Kind {
            case foreground
            case background
            case cursor
            case palette(index: UInt8)
        }

        init(c: ghostty_action_color_change_s) {
            switch c.kind {
            case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
                self.kind = .foreground
            case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
                self.kind = .background
            case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
                self.kind = .cursor
            default:
                self.kind = .palette(index: UInt8(c.kind.rawValue))
            }

            self.color = Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
    }

    struct MoveTab {
        let amount: Int

        init(c: ghostty_action_move_tab_s) {
            self.amount = c.amount
        }
    }

    struct OpenURL {
        /// Where the URL came from. `unknown` and `osc8` may come from
        /// terminal output and must be opened through ``UntrustedURL``.
        enum Kind {
            /// May be a plain path, such as `~/notes.txt`, instead of a URL.
            case unknown
            case text
            case html
            case osc8

            init(_ c: ghostty_action_open_url_kind_e) {
                switch c {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
                    self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
                    self = .html
                case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8:
                    self = .osc8
                default:
                    self = .unknown
                }
            }
        }

        let kind: Kind
        let url: String

        init(c: ghostty_action_open_url_s) {
            self.kind = Kind(c.kind)

            if let urlCString = c.url {
                let data = Data(bytes: urlCString, count: Int(c.len))
                self.url = String(data: data, encoding: .utf8) ?? ""
            } else {
                self.url = ""
            }
        }
    }

    struct ProgressReport {
        enum State {
            case remove
            case set
            case error
            case indeterminate
            case pause

            init(_ c: ghostty_action_progress_report_state_e) {
                switch c {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    self = .remove
                case GHOSTTY_PROGRESS_STATE_SET:
                    self = .set
                case GHOSTTY_PROGRESS_STATE_ERROR:
                    self = .error
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
                    self = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:
                    self = .pause
                default:
                    self = .remove
                }
            }
        }

        let state: State
        let progress: UInt8?
    }

    /// A status report from a program using OSC 7501, for example a coding
    /// agent that is working or waiting on the user.
    struct ProgramStatus: Equatable {
        enum State {
            case idle
            case working
            case done
            case blocked
            case error
            case clear

            init(_ c: ghostty_action_program_status_state_e) {
                switch c {
                case GHOSTTY_PROGRAM_STATE_IDLE:
                    self = .idle
                case GHOSTTY_PROGRAM_STATE_WORKING:
                    self = .working
                case GHOSTTY_PROGRAM_STATE_DONE:
                    self = .done
                case GHOSTTY_PROGRAM_STATE_BLOCKED:
                    self = .blocked
                case GHOSTTY_PROGRAM_STATE_ERROR:
                    self = .error
                default:
                    self = .clear
                }
            }

            /// How urgently this state needs the user's attention. When a tab
            /// has several surfaces, the tab shows the most urgent one.
            var urgency: Int {
                switch self {
                case .clear: return 0
                case .idle: return 1
                case .working: return 2
                case .done: return 3
                case .error: return 4
                case .blocked: return 5
                }
            }
        }

        /// What a blocked program needs from the user.
        enum Kind {
            case permission
            case question
            case auth

            init?(_ c: ghostty_action_program_status_kind_e) {
                switch c {
                case GHOSTTY_PROGRAM_KIND_PERMISSION:
                    self = .permission
                case GHOSTTY_PROGRAM_KIND_QUESTION:
                    self = .question
                case GHOSTTY_PROGRAM_KIND_AUTH:
                    self = .auth
                default:
                    return nil
                }
            }
        }

        var state: State
        let kind: Kind?
        let progress: UInt8?

        /// Machine-readable program name, e.g. "claude-code".
        let app: String?

        /// Short human-readable label.
        let title: String?

        /// One line of human-readable text about what the program is doing.
        let msg: String?

        /// Which account or profile of the program, e.g. ".claude-work".
        var account: String?

        /// How much of the program's context window is used, 0-100.
        var context: UInt8?

        /// How many shells the program has left running in the background,
        /// such as a dev server.
        var shells: UInt8?

        /// The last thing the program said to the user, e.g. the agent's
        /// last reply.
        var last: String?

        /// The child record this is about, e.g. "sub/a1b2", or nil for the
        /// program itself.
        var id: String?

        /// When the program entered its current state.
        var since: Date = Date()

        /// A name for the program to show to people.
        var appDisplayName: String {
            switch app {
            case "claude-code": return "Claude Code"
            case "codex": return "Codex"
            case let app?: return app
            case nil: return "Agent"
            }
        }
    }

    struct Scrollbar {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            total = c.total
            offset = c.offset
            len = c.len
        }
    }

    struct StartSearch {
        let needle: String?

        init(c: ghostty_action_start_search_s) {
            if let needleCString = c.needle {
                self.needle = String(cString: needleCString)
            } else {
                self.needle = nil
            }
        }
    }

    enum PromptTitle {
        case surface
        case tab

        init(_ c: ghostty_action_prompt_title_e) {
            switch c {
            case GHOSTTY_PROMPT_TITLE_TAB:
                self = .tab
            default:
                self = .surface
            }
        }
    }

    enum KeyTable {
        case activate(name: String)
        case deactivate
        case deactivateAll

        init?(c: ghostty_action_key_table_s) {
            switch c.tag {
            case GHOSTTY_KEY_TABLE_ACTIVATE:
                let data = Data(bytes: c.value.activate.name, count: c.value.activate.len)
                let name = String(data: data, encoding: .utf8) ?? ""
                self = .activate(name: name)
            case GHOSTTY_KEY_TABLE_DEACTIVATE:
                self = .deactivate
            case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
                self = .deactivateAll
            default:
                return nil
            }
        }
    }
}

// Putting the initializer in an extension preserves the automatic one.
extension Ghostty.Action.ProgramStatus {
    init(c: ghostty_action_program_status_s) {
        func string(_ ptr: UnsafePointer<CChar>?) -> String? {
            guard let ptr else { return nil }
            let value = String(cString: ptr)
            return value.isEmpty ? nil : value
        }

        self.state = State(c.state)
        self.kind = Kind(c.kind)
        self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
        self.app = string(c.app)
        self.title = string(c.title)
        self.msg = string(c.msg)
        self.account = string(c.account)
        self.context = c.context >= 0 ? UInt8(c.context) : nil
        self.shells = c.shells >= 0 ? UInt8(c.shells) : nil
        self.last = string(c.last)
        self.id = string(c.id)
    }
}

extension Ghostty.Action.ProgressReport {
    init(c: ghostty_action_progress_report_s) {
        self.state = State(c.state)
        self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
    }
}
