<div align="center">

<img src="images/kinterm/icon.png" alt="KinTerm app icon: a glossy silver face with a blue prompt for eyes" width="128">

# KinTerm

**The terminal for AI coding agents**<br>
Every tab is a face that shows what its agent is doing, so you know who's working,
who's done and who needs you, without opening a single tab.

[![Release](https://img.shields.io/github/v/release/lakpriya1s/kinterm?color=5ca0ff&label=release)](https://github.com/lakpriya1s/kinterm/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/lakpriya1s/kinterm/total?color=3fb950)](https://github.com/lakpriya1s/kinterm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000.svg?logo=apple&logoColor=white)](#install)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-ready-d97757.svg)](#claude-code)
[![Built on Ghostty](https://img.shields.io/badge/built%20on-Ghostty-3551f3.svg)](#credits)

[Website](https://lakpriya.com/kinterm/) · [Download](https://github.com/lakpriya1s/kinterm/releases/latest) · [Features](#features) · [Work alongside](#work-alongside-your-agents) · [Claude Code](#claude-code) · [Any agent](#any-agent-osc-7501) · [Build](#build-from-source) · [Credits](#credits)

</div>

---

<p align="center">
  <img src="images/kinterm/tabs.gif" alt="A KinTerm tab bar where each tab is a face: they sleep, turn blue while working, amber with a question mark when one needs you, green and happy when done, and red with X eyes on an error" width="600">
</p>

You run Claude Code in one tab, then another, then five. One is waiting for a yes,
one finished ten minutes ago, one hit a rate limit, and the only way to find out is to
click through every tab.

**KinTerm turns each tab into a face.** Gray and asleep when idle, blue with darting
eyes while it works, amber and surprised when it needs you, green and happy when it's
done, red with X eyes when something breaks. One glance at the tab bar tells you where
to go next. When you're in another app, a notification, the dock icon and the menu bar
tell you instead.

It's a full, fast, native macOS terminal underneath: KinTerm is built on
[Ghostty](https://ghostty.org), so you keep GPU rendering, native tabs and splits, and
your Ghostty config and themes.

## The faces

| Face | State | When | What you see |
| :--: | --- | --- | --- |
| <img src="images/kinterm/faces/idle.png" width="48" alt="Idle face"> | **Idle** | The session has started and is ready for a prompt | Gray, eyes shut, a drifting "z" |
| <img src="images/kinterm/faces/working.png" width="48" alt="Working face"> | **Working** | You sent a prompt; it's reading, editing, running tools | Blue, eyes looking left and right |
| <img src="images/kinterm/faces/waiting.png" width="48" alt="Waiting face"> | **Waiting on you** | It asks for permission or a question | Amber, surprised, bouncing, "?" |
| <img src="images/kinterm/faces/done.png" width="48" alt="Done face"> | **Done** | It finished its turn | Green, happy, a white dot until you look |
| <img src="images/kinterm/faces/error.png" width="48" alt="Error face"> | **Error** | The turn ended on an API error: rate limited, overloaded | Red, X eyes, a little shake |

A tab with splits shows its most urgent agent: waiting, then error, done, working, idle.

## Features

| | |
| --- | --- |
| 🙂 | **A face on every tab.** The tab bar goes at the top, in the title bar, at the bottom, left or right, in S, M or L |
| 🎭 | **Six face sets.** Faces (the default), Square faces, Orbs, Shapes, Bots and Spark, all with the same five states |
| 🔎 | **Hover card.** Hover a face for the agent's last message, how much of its context is used, the git branch and the account |
| 🔔 | **Notifications** when an agent finishes, needs you or fails while you're somewhere else |
| 🚦 | **The app icon is a status light.** The dock icon takes the colour and expression of the agent that needs you most, with a badge for how many are waiting |
| 📊 | **Menu bar summary.** A live count of your agents from anywhere, in Compact, Full or Icon only style |
| 🧭 | **Agents panel.** <kbd>⌘</kbd><kbd>⇧</kbd><kbd>A</kbd> lists every agent in every window, most urgent first. <kbd>⌘</kbd><kbd>J</kbd> jumps straight to the next one waiting on you, in Grid View too |
| 👥 | **Several Claude accounts.** Each account gets a colour, as a tint or a ring on its tabs. The `+` menu and <kbd>⌥</kbd><kbd>⌘</kbd><kbd>1</kbd>–<kbd>9</kbd> open a Claude Code tab with a given account, optionally in a new git worktree |
| 🧩 | **Subagents.** A small badge counts the subagents a session is running |
| 🪄 | **Setup Assistant.** On first launch, pick your faces, size and tab bar by looking at them, and it installs the Claude Code hook for you. After an update it shows what's new, once |
| ▦ | **Grid View.** <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd> shows every tab of a window as a live tile, so all your agents are on screen at once. When one needs you, the keyboard moves to it, once you've sent what you were typing or saying. [More below](#work-alongside-your-agents) |
| ✅ | **Review Changes.** <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> shows what an agent changed as GitHub-style diffs, in a folder tree, across every repo of a VS Code workspace. [More below](#work-alongside-your-agents) |
| 🌐 | **A browser agents can use.** <kbd>⌘</kbd><kbd>⇧</kbd><kbd>B</kbd> opens your dev server beside the terminal, with Chrome's DevTools. [More below](#work-alongside-your-agents) |
| 🔘 | **Buttons for the tools.** Grid View, Review Changes and the browser sit at the end of the tab bar, lit while open, with a count of changed files on Review |
| 🎨 | **Tab colours.** Right-click a tab, or an account, to give it a colour |
| 📡 | **An open protocol.** Any agent or script can report its state with [OSC 7501](#any-agent-osc-7501) |
| 🔄 | **Updates itself.** New versions arrive in the app, no reinstalling |

## Work alongside your agents

Seeing that an agent is done is half of it. Then you check what it did.

**Review Changes** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd>) shows the changes in the focused
tab's git repository like a pull request: a file list and GitHub-style diffs, for
everything uncommitted, everything this session, or just the agent's last turn. Revert a
hunk or a file, mark files as viewed, and leave comments on lines; **Send** types them
into the agent's prompt for you to send. It opens beside the terminal, in its own window,
or as one more tile in Grid View.

- **List or tree.** Right-click the file list (or use its button) for **View as Tree**,
  the default: folders you can collapse, each with its +/− and how many files you've
  viewed. **Mark Folder as Viewed** ticks a whole folder and puts it away, like the build
  output an agent left behind. Folders that only hold one folder share a row, as in VS Code.
- **Workspaces with several repos.** If the folder has a VS Code `.code-workspace` file,
  Review Changes covers every repository in its `folders`, each a group with its name and
  branch, and the header becomes a menu to show just one. Without a workspace file it
  finds repositories cloned inside the one you're in, like VS Code's
  `git.autoRepositoryDetection`. `files.exclude` (from the workspace and each folder's
  `.vscode/settings.json`) hides files in both tabs; **N excluded** shows them again.
- **Images and other files.** Files that aren't text show with Quick Look: images,
  PDFs, video, fonts. A changed one shows **Before** and **After** side by side.

**Grid View** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd>) moves the keyboard to a tile whose
agent is waiting on you, and the tile pulses to say why. It never takes the keyboard while
you're mid-prompt: it waits until you send, whether you press Return or send by voice, and
while any app has the microphone open. It won't leave a tile whose own agent is waiting on
you. Right-click the tab bar › **Grid View** › **Focus Tiles Automatically** to turn it
off, or to include agents that finish. <kbd>⌘</kbd><kbd>J</kbd> does it by hand.

**The browser** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>B</kbd>) shows your dev server beside the
terminal: type `3000` or `localhost:5173` in its address bar, run
`kinterm-browser open 3000`, or ⌘-click a localhost link. It's Chromium, with Chrome's
DevTools docked under the page (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>I</kbd>), and it can move into a
window of its own. Agents can use it too: they open pages, click, type and read the
console and network requests through an MCP server (Chrome DevTools MCP, pointed at this
browser). While they do, the page glows blue and shows their cursor and clicks. The
browser loads nothing until you open it. It needs Apple silicon.

**Connect Agents**, in the Setup Assistant, installs the **KinTerm skill** for Claude Code
(so agents know to show their work in the browser and hand changes over for review) and
gives Claude Code and Codex the browser's tools. Or from a terminal:

```sh
kinterm-browser open 3000      # open or show a page
kinterm-browser status         # what's open
kinterm-browser mcp            # the MCP server, for any agent
```

## Install

1. Download **KinTerm.dmg** from the [latest release](https://github.com/lakpriya1s/kinterm/releases/latest).
2. Open it and drag **KinTerm** to Applications.
3. Open KinTerm. The **Setup Assistant** walks you through the faces, the tab bar,
   the Claude Code hook and connecting your agents to the browser. You can open it
   again any time from **KinTerm › Setup Assistant…**

Requirements: macOS 13 Ventura or later, on Apple silicon or Intel. The built-in
browser needs Apple silicon. KinTerm checks for
updates on its own, or use **KinTerm › Check for Updates…**

## Claude Code

The faces come from a small [Claude Code hook](agents/claude-code) that tells KinTerm
what each session is doing. The Setup Assistant installs it. To install it yourself
from a clone of this repo:

```sh
agents/claude-code/install.sh          # ~/.claude, or $CLAUDE_CONFIG_DIR
agents/claude-code/install.sh --all    # every ~/.claude* folder, one per account
```

It backs up each `settings.json` first, then adds the hook. Restart running Claude Code
sessions to pick it up. Remove it with `install.sh --uninstall`.

| Claude Code event | Face |
| --- | --- |
| `SessionStart` | Idle |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | Working |
| `Notification` | Waiting on you |
| `Stop` | Done |
| `StopFailure` | Error |

## Any agent: OSC 7501

KinTerm listens for [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status),
the Program Status Protocol. Anything that runs in a tab can set its face by printing one
escape sequence:

```sh
printf '\e]7501;state=working:app=my-agent\e\\'   # blue, working
printf '\e]7501;state=blocked:app=my-agent\e\\'   # amber, waiting on you
printf '\e]7501;state=done:app=my-agent\e\\'      # green, done
```

`state` is one of `idle`, `working`, `blocked`, `done`, `error` or `clear`. Add
`msg=<base64 text>` to show a message in the hover card and the notification. See
[agents/claude-code](agents/claude-code/README.md) for every field the Claude Code hook
sends.

## Configuration

KinTerm reads `~/.config/kinterm/config.kinterm`, or on macOS
`~/Library/Application Support/com.kinterm.app/config.kinterm`. Until you create one, it
uses your Ghostty config if you have one. Themes go in `~/.config/kinterm/themes`, and
every [Ghostty option](https://ghostty.org/docs/config) works.

The faces, the tab bar, notifications and the menu bar summary are in the **View** menu
and the Setup Assistant. The `kinterm` command line tool is in
`KinTerm.app/Contents/MacOS`; run `kinterm +help` for its actions.

## Build from source

You need [Zig](https://ziglang.org) and Xcode.

```sh
git clone https://github.com/lakpriya1s/kinterm.git && cd kinterm
zig build -Demit-macos-app=false                      # the core library
macos/Browser/build.sh                                # optional: the browser (Chromium)
cd macos && xcodebuild -target Ghostty -configuration Debug
open build/Debug/KinTerm.app
```

Or `scripts/dev-run.sh` to build and restart in one step.
[scope/HANDOFF.md](scope/HANDOFF.md) explains how the agent tabs fit into the codebase,
and [HACKING.md](HACKING.md) covers the Ghostty core.

## FAQ

**Is this Ghostty?** KinTerm is a fork of Ghostty with agent faces on top. The terminal
itself (emulation, rendering, fonts, config) is Ghostty's, and KinTerm keeps up with
Ghostty's changes.

**Will my Ghostty config work?** Yes. KinTerm uses it until you create a KinTerm config.

**Does it only work with Claude Code?** Claude Code works out of the box. Any other agent
or script can show a face with [OSC 7501](#any-agent-osc-7501).

**Why is the app so big?** The built-in browser is Chromium, about 330 MB. It doesn't
load or run until you open it.

**Linux?** Not yet. KinTerm is macOS only for now.

**Is it free?** Yes, free and open source under the MIT license.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first. For security issues, see [SECURITY.md](SECURITY.md).

If KinTerm saves you some tab-hunting, a ⭐ helps other people find it.

## Credits

KinTerm is built on **[Ghostty](https://github.com/ghostty-org/ghostty)** by
[Mitchell Hashimoto](https://github.com/mitchellh) and the Ghostty contributors. Almost
everything that makes it a great terminal comes from their work: thank you. KinTerm is an
independent project and isn't affiliated with or endorsed by Ghostty.

Updates are delivered with [Sparkle](https://sparkle-project.org). The browser is
[Chromium Embedded Framework](https://github.com/chromiumembedded/cef), and agents drive
it with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp). The status protocol is
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).

## License

[MIT](LICENSE), the same as Ghostty.
