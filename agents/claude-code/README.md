# Claude Code status for KinTerm

Shows what Claude Code is doing as a face on the KinTerm tab, and sends a
notification when it finishes or needs you while you're in another tab.

| Claude Code event  | Tab face                         |
| ------------------ | -------------------------------- |
| `SessionStart`     | Idle (gray, sleeping)            |
| `UserPromptSubmit` | Working (blue, spinner)          |
| `PreToolUse`       | Working, with the tool in hover  |
| `PostToolUse`      | Working                          |
| `Notification`     | Waiting on you (amber, bouncing) |
| `Stop`             | Done (green, until you look)     |
| `StopFailure`      | Error (red), e.g. rate limited   |
| `SessionEnd`       | No face                          |

## Install

```sh
./install.sh                       # ~/.claude, or $CLAUDE_CONFIG_DIR
./install.sh --all                 # every ~/.claude* config folder (all accounts)
./install.sh ~/.claude-account1 ~/.claude-account2   # just these
```

This copies `kinterm-agent-status` to `~/.config/kinterm/agents/claude-code/`
and adds it to each folder's `settings.json`. Before the first change the file
is copied to `settings.json.before-kinterm`, which is never overwritten.
It also replaces the hook from before the rename (`ghostty-agent-status`).
Restart running Claude Code sessions to pick it up.

Remove it with `./install.sh --uninstall [folders...]`.

## How it works

The hook writes an [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status)
(Program Status Protocol) report to the terminal, for example:

```
ESC ] 7501 ; state=blocked:app=claude-code:account=.claude-work:kind=permission:title=<base64>:msg=<base64> ESC \
```

`account` is the name of the Claude config folder (`CLAUDE_CONFIG_DIR`, or
`.claude`). KinTerm gives each account a color and draws it as the ring
around the face. It's an extension to OSC 7501; terminals that don't know it
ignore it.

Two more extension keys fill in the hover card:

- `context`: how much of the context window is used, 0-100. Hooks aren't told
  this, so the hook reads the token counts of the last reply from the
  transcript and divides by the model's window (1M for Opus 4.7+, Sonnet 5+,
  Haiku 5.5+ and `[1m]` models, otherwise 200k;
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` overrides it). Needs `jq`.
- `last`: Claude's last reply (`last_assistant_message` from `Stop`),
  base64 like `msg`, cut to 180 bytes.

KinTerm keeps both until a report brings new ones.

Any program can send these, so other agents can be supported by writing a
similar hook. It does nothing outside KinTerm (`TERM_PROGRAM` must be
`ghostty`, which KinTerm keeps setting for compatibility). Requires `jq` for installing; the hook itself uses `jq` when
present to read tool details.

## Resuming after a restart

The hook also records the session for KinTerm's tab, in
`~/.config/kinterm/sessions/<KINTERM_SURFACE_ID>`: the agent, session id,
`CLAUDE_CONFIG_DIR` and the folder the session started in. When KinTerm
reopens its windows after you quit it or it crashes, the tab keeps its id and
runs `claude --resume <id>` there. When the session ends while its terminal is
still open (you ended it), the record is deleted, so it isn't resumed.
