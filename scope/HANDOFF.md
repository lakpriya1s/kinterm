# Handoff

Everything needed to pick this work up cold. Read this, then
[README.md](README.md) (scope) and [tasks/README.md](tasks/README.md) (status).

_Last updated: 2026-10-24._

## What this is

**KinTerm**, a fork of Ghostty where each tab is an animated **face** showing what the
coding agent inside it is doing (idle, working, waiting on you, done, error).
Claude Code first; other agents later through the same protocol.

- Repo: https://github.com/lakpriya1s/kinterm, branch **`agent-tabs`**
  (upstream remote: `ghostty-org/ghostty`)
- Design canvas: https://claude.ai/artifact/GqsEQ9WZbmCBrk5RGNcBKX
  (copied into [designs/](designs/README.md); open `designs/canvas-export.html`
  in a browser)

## Where it stands

**P0, P1 and P2 are built for Claude Code on macOS.** P3 (other agents,
Linux, extras) is deliberately left for later. Everything is committed on
`agent-tabs`, in the commits from `f2d33a991` onward (`git log
main..agent-tabs`). Pushed to `lakpriya1s/kinterm` and open as PR #1
into `main` (2026-10-24). Ask the user before pushing again.
The hook is installed in all six `~/.claude*` folders (reinstalled 2026-10-23 with `StopFailure`).
**It must be reinstalled after the KinTerm rename** (`install.sh --all`
swaps `ghostty-agent-status` for `kinterm-agent-status`); the old hook
keeps working until then from `~/.config/ghostty/agents/`.

**Renamed to KinTerm (2026-10-24).** Product and config only; Ghostty's
internals keep their names so upstream merges still work:

- Renamed: app (`KinTerm.app`, display name, menus, About, AppleScript
  descriptions, alerts), bundle id `com.kinterm.app` (`.debug` for Debug),
  executable and CLI `kinterm` (help, version, shell-integration `ssh`
  wrappers), config `~/.config/kinterm/config.kinterm` and
  `~/Library/Application Support/com.kinterm.app/config.kinterm`, themes
  `~/.config/kinterm/themes`, the hook and installer.
- Fallbacks: with no KinTerm config file, Ghostty's config files are loaded
  (and Open Config edits them); Ghostty's themes folder is searched after
  KinTerm's. Agent settings and accounts are copied once from the old
  bundle id's defaults (`UserDefaults.migrateAgentSettingsFromGhostty`).
- Updates: only release builds update, from KinTerm's own Sparkle feed on
  GitHub Pages (`UpdateController.isEnabled` needs `KinTermFeedURL` and
  `SUPublicEDKey`, which `kinterm-release.yml` writes into Info.plist).
  Ghostty's feed and key are gone. Setup and releasing: [RELEASING.md](RELEASING.md).
- Kept: Xcode target and scheme `Ghostty`, Swift module `Ghostty`,
  libghostty and its C API, `TERM_PROGRAM=ghostty`, `xterm-ghostty`
  terminfo, `GHOSTTY_*` env vars, the gettext domain, Linux/GTK app id,
  docs and man pages generated from `src/`.
- Brand: `macos/Sources/Features/Branding/KinTermMark.swift` (mark, app
  icon, wordmark), `images/KinTerm.icon` (app icon), `images/kinterm/`
  (README images), `site/icon.png`; regenerate with
  `scripts/render-brand.swift`. The mark is one glossy face: silver with a blue `>` prompt for eyes. The site draws the same faces
  in `markInner` in `site/index.html`. The dock icon is a status light
  (`AgentSummary.updateDockIcon`): the face takes the state's color and its
  Square faces expression.
- Setup Assistant (`Features/Onboarding/`): a first-launch wizard for face
  set and size, tab bar position, the Claude Code hook (per `~/.claude*`
  folder, via `AgentHookInstaller`, which the app bundles the hook for, so
  no repo or `jq` is needed), account colors, notifications, dock badge and
  menu bar summary. KinTerm › Setup Assistant… reopens it; `OnboardingCompleted`
  in defaults marks it done. Debug builds open a page directly with
  `KINTERM_ONBOARDING_STEP=<welcome|faces|tabBar|claude|tools|stayInLoop|done>`.
  The `tools` page shows Grid View, Review Changes and the browser, and its
  Connect Agents button installs the KinTerm skill
  (`agents/skills/kinterm/SKILL.md`, into each account's `skills/`) and the
  browser's MCP server (`BrowserAgentInstaller`). People who finished the
  wizard before see that page alone, once, as "New in KinTerm"
  (`OnboardingFeaturesSeen`; bump `OnboardingController.features` for the
  next one; `KINTERM_WHATS_NEW=1` forces it in debug builds).
- Grid View (`Features/Terminal Grid/`, ⌘⇧E): every tab of a window as a
  live tile.
- Code Review (`Features/Code Review/`, ⌘⇧R): diffs of the focused tab's
  repository beside the terminal, in a window, or as a grid tile. Design:
  [designs/08-code-review.md](designs/08-code-review.md).
- Browser (`Features/Browser/`, `macos/Browser/`, ⌘⇧B): Chromium (CEF) in a
  module loaded with `dlopen` on first use, the `kinterm-browser` CLI and
  MCP server, agent cursor and glow. Built by `macos/Browser/build.sh`,
  signed for release by `macos/Browser/sign.sh`. Design:
  [designs/09-browser.md](designs/09-browser.md), build notes:
  [macos/Browser/README.md](../macos/Browser/README.md).

**Seen working on screen**

- Faces animate; tab bar at Top and Title Bar; window title back in the
  title bar for Top/Left (05).
- Real Claude sessions drive the faces; accounts tint the tabs (02, 08).
- Notifications match the design: tab name in the title, "took 4m 02s",
  Open tab / Dismiss, the agent's face as the image (04).
- `+` menu with accounts, folder picker, New account… (09).
- Subagent badge, with test reports (12).
- Menu bar summary in Compact style (10).
- CPU: faces only animate when visible; measurements in task 03.

**Built, not yet checked on screen:** Left, Bottom and Right positions and S/M/L vs. the design
(03, 05); hover card's context bar, last message and branch (06, 13);
Agents panel ⌘⇧A and ⌘J (11); dock badge (10); ⌥⌘1–9, worktree option,
Add existing account…, Rename, and New account…'s two fields (name and
folder extension) (09); the agent cards in the menu bar item's menu (10); the four other face sets (Orbs, Shapes,
Bots, Spark: Face Style in the bar's menu and View › Agent Face Style, `AgentFaceSets.swift`,
[designs/06-face-sets.md](designs/06-face-sets.md)).

**Not started (P3):** other agents (14), Linux (15), quiet mode and the
other extras in [README.md](README.md).

## Build and run

One-time setup on this Mac (already done):

```sh
brew install zig                              # needs Zig 0.17.0
xcodebuild -downloadComponent MetalToolchain  # Xcode's Metal compiler
```

Build and restart in one step (rebuilds the core only when `src/` or
`include/` changed):

```sh
scripts/dev-run.sh             # --core to force a core rebuild, --no-build to just restart
```

Or by hand. After changing anything in `src/` (Zig core) or `include/ghostty.h`:

```sh
zig build -Demit-macos-app=false   # rebuilds the library the app links
```

After any change (Swift or core):

```sh
cd macos && xcodebuild -target Ghostty -configuration Debug   # builds KinTerm.app
```

Run it (quit the running dev copy first, or the old one keeps running):

```sh
A=/Volumes/External/ghossty-new/macos/build/Debug/KinTerm.app
osascript -e "tell application \"$A\" to quit"
open "$A"
```

Tests: `zig build test -Dtest-filter=ProgramStatus`

See it work without Claude: run `agents/demo-states.sh` in a tab.

## Gotchas

- **Don't launch `zig-out/KinTerm.app` after a plain `zig build`.** That build
  copies the app over the old one in place, macOS keeps the old code signature
  cached, and the launch fails ("Launchd job spawn failed", code 162; the
  binary exits 137). Use `macos/build/Debug/KinTerm.app` (what
  `scripts/dev-run.sh` runs, and what `macos/AGENTS.md` says anyway).
- **Restarting the dev app closes the user's Claude sessions in it.** Check
  first (`ps -t <tty>` for each terminal's tty, from AppleScript) and ask, or
  let the user run `scripts/dev-run.sh --no-build`.
- **Launching the dev app from a Claude Code session** passes Claude's
  `CLAUDE_*` variables to every terminal in it: `claude` there turns off
  transcript saving ("inherited CLAUDE_CODE_CHILD_SESSION marker"), which
  also loses the context bar, and `CLAUDE_CONFIG_DIR` pins every tab to one
  account. `scripts/dev-run.sh` strips them; a bare `open` doesn't.
- **Don't launch a second copy** (`open -n`) to test: it restores the user's
  windows, and they may start working in it.
- **The agent can't edit `~/.claude*/settings.json`** (Claude Code's permission
  check blocks it as persistence). The user runs the installer:
  `sh /Volumes/External/ghossty-new/agents/claude-code/install.sh --all` on
  one line (a wrapped paste runs without `--all`).
- **Two builds at once collide** on the Sparkle package download. Run one.
- **`macos/build.nu`** (the official app build script) needs `nu`, which isn't
  installed; the `xcodebuild` command above is what it runs.
- **SwiftLint** is installed (Homebrew): `swiftlint lint --strict` in
  `macos/` passes. **Prettier isn't installed**, so Markdown isn't formatted.
- **The deployment target is below macOS 14**: e.g. `NSMenuItem.sectionHeader`
  doesn't build.
- **SourceKit errors in the editor** ("Cannot find type 'Ghostty' in scope")
  are the indexer lacking project context. The Xcode build is the real check.
- **Screenshots:** capture only the dev app's window, never the whole screen
  (it shows the user's other apps): get its window number with
  `CGWindowListCopyWindowInfo` for the app's pid, then
  `screencapture -x -o -l <number> out.png`. Drive it with AppleScript
  (`input text … to terminal id "<id>"`, then `send key "enter"`; pasted text
  waits for Enter). `log` is a zsh builtin; use `/usr/bin/log show`.
- **Debugging hooks:** `claude --debug-file <path>` logs every hook run and its
  exit status.
- **The dev build is its own app to macOS** (`com.kinterm.app.debug`),
  separate from the user's `/Applications/Ghostty.app`: its own
  notification permission (it was off; `log show` with
  `process == "NotificationCenter"` says `notificationsAllowed: false`), its
  own entry in System Settings › Menu Bar, and its own settings:
  `defaults read com.kinterm.app.debug` (keys `Agent*`). To change one
  the app can't reach, `defaults write` it, then restart the dev app.
- **Test in a terminal without Claude running.** Once Claude reports its own
  status, test reports only set the account, context and last message, not
  the state. Find a plain shell: `ps -o comm= -t <tty>` for each terminal.
  Writing to a tty only changes what's shown, never Claude's input, but
  don't use the user's Claude terminals anyway.
- **A notification only shows when the user isn't looking at that
  terminal**, so test with the dev app in the background
  (`osascript -e 'tell application "/Applications/Ghostty.app" to activate'`).
- **`System Events … frontmost` can be wrong**; grey traffic lights in a
  screenshot are the reliable sign the dev app isn't active.
- **A locked screen counts as not visible**: faces stop, CPU drops to ~0.
  Check with `CGSessionCopyCurrentDictionary()` (`CGSSessionScreenIsLocked`).
- **Measure CPU on the debug build** and say so. The Release build
  (`com.kinterm.app`) no longer shares the user's Ghostty bundle id, but
  it would take over their real config and accounts.
- **Menu bar items aren't windows the app owns** on this macOS (a system
  scene draws them), so `CGWindowList` can't find or capture them, and
  osascript has no accessibility permission. Ask the user to look.
- **Measuring CPU:** `top -l 8 -s 1 -pid <pid> -stats cpu`; `sample <pid> 3`
  shows what's drawing (look for `AgentFaceView` and `layoutIfNeeded`).

## How it fits together

```
Claude Code ──its own OSC 7501 (state, subagent child records)──┐
Claude Code hook ──OSC 7501 (state, account, context, last)─────┤
                                                                ▼
            core (Zig) ──program_status action──▶ macOS app (per terminal, per tab, summary)
```

| Layer | Files |
| --- | --- |
| Hook + installer | `agents/claude-code/kinterm-agent-status` (context % from the transcript, `last` on Stop, `StopFailure` → error), `agents/claude-code/install.sh` (`--all`), `agents/demo-states.sh` |
| Core: parse → app | `src/terminal/osc/parsers/program_status.zig` (extension keys `account`, `context`, `last`), `src/termio/stream_handler.zig` (forwards root and child reports, query reply), `src/apprt/surface.zig` (`Message.ProgramStatus` + test), `src/Surface.zig`, `src/apprt/action.zig` (C union 64 bytes on 64-bit), `include/ghostty.h`, `src/apprt/gtk/class/application.zig` (ignored on Linux) |
| Swift model | `Ghostty/Ghostty.Action.swift` (`ProgramStatus`), `Ghostty.App.swift` (action → surface; clears on command finished; notification actions), `Ghostty.Config.swift` (`desktopNotifications`), `GhosttyPackage.swift` (agent notification category), `Surface View/OSSurfaceView.swift` (`programStatus`, `programChildren`, `programWorkStartedAt`), `Surface View/SurfaceView_AppKit.swift` (merge rules, children, agent notifications, "seen") |
| Per tab | `Features/Terminal/BaseTerminalController.swift` (most urgent status, `subagentCount`, `createdAt`, `agentTabBar`) |
| UI (`Features/Agent Tabs/`) | `AgentFaceView.swift` (faces, `Motion`), `AgentTabBar.swift` (settings incl. menu bar style, model incl. `faceMotion` and `inTitlebar`, bar, placement, hover card, `AgentGitBranch`, window drag area), `AgentAccounts.swift` (account store), `AgentNewTabMenu.swift` (`+` menu, launcher, New account…, ⌥⌘1–9), `AgentSummary.swift` (dock badge, menu bar item and its agent cards, View menu items, notification icon), `AgentsPanel.swift` (⌘⇧A, ⌘J, `AgentTime`) |
| Window | `Features/Terminal/TerminalView.swift` (hosts the bar), `TerminalController.swift` (owns the model, installs shortcuts), `Window Styles/TerminalWindow.swift` (hides the native tab bar and its faces, Title Bar position), `TransparentTitlebarTerminalWindow.swift` (clears its title bar paint for it), `App/AppDelegate.swift` (dock badge count, notification categories, starts the summary) |
| Dev | `scripts/dev-run.sh` (strips `CLAUDE*` from the app's environment) |

Key decisions in the code:

- Tabs are still **native macOS window tabs**; the face bar only redraws them,
  so ⌘T / ⌘W / ⌘1–9 / restore all keep working.
- The native bar is hidden by setting its titlebar accessory's `isHidden`
  (in `TerminalWindow.addTitlebarAccessoryViewController` and
  `syncNativeTabBarVisibility`). `toggleTabBar` did not work. Its per-tab
  face is emptied while hidden, or it keeps animating unseen.
- `agentTabBar` must be declared on `BaseTerminalController` (where the
  `TerminalViewModel` conformance is) and overridden in `TerminalController`;
  declaring it only on the subclass silently used the protocol default (nil).
- **Two reporters.** Claude Code 2.1.309 sends its own OSC 7501 once KinTerm
  answers its `?` probe (no account; subagents as child records `id=<agent
  id>`). The hook adds the account, context and last message. A report
  without them keeps the previous values; once the program reports itself,
  the hook only sets those, not the state.
- **Context used** isn't given to hooks: the hook divides the last reply's
  input tokens (from the transcript) by the model's window (1M for Opus
  4.7+, Sonnet 5+, Haiku 5.5+, `[1m]`; otherwise 200k). Needs `jq`.
- **Hooks have no controlling terminal** in interactive sessions, so the hook
  writes to the tty of its nearest parent that has one (Claude Code).
- A terminal's status is cleared when shell integration reports the command
  finished, so a crashed or interrupted agent doesn't leave a stale face.
- **Every animation frame lays out the whole window** (~14% main thread in
  the debug build, per frame, not per face). So faces only move when
  someone can see them: all while KinTerm is active, working and waiting
  only while it's in the background, none when the window isn't visible.
  The Agents panel drops its rows when hidden for the same reason. A
  possible later fix: draw faces in their own layer.
- **Title Bar position:** the window gets `.fullSizeContentView` and a
  transparent title bar while it's on, undone when switching away; the
  `tabs` and `hidden` title bar styles and full screen fall back to Top.
- `AgentTabBarModel.setNeedsRefresh()` is the hub every change goes through;
  the summary listens to `changesPublisher`.
- Popovers (hover card, `+` menu, Agents panel) are borderless child panels;
  the menu and Agents panel can become key, the hover card can't.
- Settings (position, face size, account style, dock badge, menu bar and its
  style, last folder, worktree) live in `UserDefaults`, from the bar's
  right-click menu, and position and menu bar also in **View › Agent Tab
  Bar** and **View › Agents in Menu Bar** (always reachable, even with
  native tabs). Accounts too (`AgentAccounts`). Not Ghostty config keys yet.
- Departures from the design, asked for by the user: account color is a tab
  tint, not a ring (ring kept as an option); the `+` menu has a folder row;
  the Title Bar, Bottom and Right positions; the window title shown for Top/Left; the menu bar
  defaults to Compact and its menu shows agent cards.

## Next steps

1. The user checks the "Built, not yet checked" list above as they use it;
   fix what they report.
2. If working faces feel heavy in daily use, draw faces in their own layer
   so a frame doesn't lay out the window (task 03).
3. Optional, offered: show each account's email / organization from its
   `.claude.json` (`oauthAccount.emailAddress`, `organizationName`) under it
   in the `+` menu.
4. P3 when the user asks: other agents (14; Codex 0.147 and opencode 1.18.9
   are installed here, Gemini CLI isn't), Linux (15).
5. Push only when the user asks.

Testing without the user: AppleScript gives each dev-app terminal's tty
(`tell application "<path>/KinTerm.app" to get tty of every terminal`), and
writing an OSC 7501 report to that tty updates its tab, just like the hook.
Use a terminal without Claude in it (see Gotchas).

## Rules from the repo

- `AGENTS.md`: never create issues or PRs; format Zig with `zig fmt`, Swift
  with `swiftlint`.
- `macos/AGENTS.md`: build the app with `macos/build.nu` / xcodebuild, not
  `zig build`.
- Commit messages end with the co-author line used in this branch's commits.
