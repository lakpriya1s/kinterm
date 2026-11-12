# Codex status for KinTerm

Shows what Codex is doing as a face on the KinTerm tab, and sends a
notification when it finishes or needs you while you're in another tab.

| Codex event         | Tab face                          |
| ------------------- | --------------------------------- |
| `SessionStart`      | Idle (gray, sleeping)             |
| `UserPromptSubmit`  | Working (blue, spinner)           |
| `PreToolUse`        | Working, with the tool in hover   |
| `PostToolUse`       | Working                           |
| `PermissionRequest` | Waiting on you (amber, bouncing)  |
| `PostModelRequest`  | Error (red), if the request failed |
| `Stop`              | Done (green, until you look)      |
| `Interrupt`         | Idle                              |
| `SessionEnd`        | No face                           |

Codex has no event for "it's asking you a question", so only approvals show
as waiting.

## Install

KinTerm installs it: Setup Assistant › Connect Your Agents, or
"+" › Codex › New Codex account…. For each Codex home (`~/.codex`, or the
folder an account's `CODEX_HOME` names), it:

- copies `kinterm-codex-status` to `~/.config/kinterm/agents/codex/`;
- adds it to the home's `hooks.json` for the events above (the file is first
  copied to `hooks.json.before-kinterm`);
- records in the home's `config.toml` that these hooks are trusted, under
  `[hooks.state."<hooks.json>:<event>:<group>:<handler>"]`, the way Codex's
  `/hooks` does (first copying it to `config.toml.before-kinterm`). The
  trusted hash is Codex's: SHA-256 of the hook entry as JSON with sorted
  keys. Without it, Codex skips the hook until you trust it in `/hooks`.

Restart running Codex sessions to pick it up.

## How it works

The hook writes an [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status)
report to the terminal, like the Claude Code hook (see
`../claude-code/README.md`), with `app=codex` and `account` set to the Codex
home's folder name (`CODEX_HOME`, or `.codex`). KinTerm colors the ring
around the face by account. It does nothing outside KinTerm (`TERM_PROGRAM`
must be `ghostty`) and never prints, since Codex adds a hook's output to the
conversation for some events.
