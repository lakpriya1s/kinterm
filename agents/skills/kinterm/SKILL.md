---
name: kinterm
description: Load first whenever you run inside KinTerm (KINTERM_BROWSER_SOCKET is set) and are about to show the user anything - a web page, dev server or local HTML file, a Markdown plan or doc you wrote, a long-running command's output, or changes to review - or to split a big task across agents. Inside KinTerm these go to its own browser, Markdown Viewer, panes, notifications and review, never `open`, Playwright, another browser, or text pasted into the chat.
---

# Working inside KinTerm

KinTerm is the terminal you're running in. It has tools for showing the user
your work, and the user is watching it, not another app.

**Rules.** When you would otherwise:

| Reach for | Use instead |
| --- | --- |
| `open URL`, Playwright, a separate Chrome, to show or check a page | `kinterm-browser open URL`, or the `kinterm-browser` MCP tools |
| Pasting a long plan, notes or a report into the chat | `kinterm-ctl markdown FILE` (`markdown`) |
| Backgrounding a dev server or watcher with `&` | `kinterm-ctl run --name N -- CMD` (`run`) |
| "Done" in the chat after a long task | `kinterm-ctl notify "…"` (`notify`) |
| Listing the files you changed | `kinterm-ctl review FILE` (`review`) |

The user is looking at KinTerm. Something opened anywhere else is out of
their sight.

## Show web work in KinTerm's browser

When you start or change a dev server, open it beside the user's terminal:

```sh
kinterm-browser open 3000            # or localhost:5173, or a full URL
kinterm-browser reload               # after a change
kinterm-browser status               # what's open
```

`kinterm-browser` is on the PATH of every KinTerm terminal. Opening the
browser doesn't take the keyboard from the user. The browser is your tab's:
it opens beside the terminal you run in, and the MCP tools only see that
page, never another tab's.

If the `kinterm-browser` MCP server is connected, use its tools to check
your change works instead of assuming it does: navigate, take a snapshot,
click and fill like a user, then read the console messages and network
requests for errors. The user sees a blue glow and your cursor while you
do. Prefer the snapshot (it's text) over screenshots.

The user can pick elements on the page and send them to you; they arrive
as a message starting "Selected element in the browser", with a CSS
selector, the element's HTML and text, and for React development builds
the component and its source file. Find that code and act on what they
ask about it.

After a UI change, check at least: the page loads, there are no new console
errors, and the thing you changed works when clicked.

## Run long-lived things where the user can see them

Start dev servers, watchers and long test runs in a pane beside your
terminal instead of in the background, then read their output:

```sh
kinterm-ctl run --name web -- 'npm run dev'   # a pane to the right (--down, --left, --up)
kinterm-ctl logs web --lines 50               # what it printed
kinterm-ctl agent kill web                    # stop it and close the pane
```

With the `kinterm` MCP server connected, the same is `run`, `logs` and
`agent_kill`. Use `scrollback` to read your own terminal's earlier output.

## Tell the user how it's going

- `kinterm-ctl notify "Migration done, 3 tests need a look"` (`notify`)
  when you finish something long or need the user and they may not be
  looking. Don't notify for every small step.
- `kinterm-ctl status working "Refactoring auth"` (`set_status`) shows on
  your tab. Claude Code and Codex with KinTerm's hooks already report
  this, so only use it if yours doesn't.

## Hand changes over for review

The user reviews your changes in KinTerm with ⌘⇧R (Review Changes): diffs
of the repository, revert per hunk, and comments that come back to you as
a message. When you finish a task, open it at the file to look at first:
`kinterm-ctl review src/auth.ts` (`review`, with `files`). Comments
arrive as a list of `file:line` notes; address each one.

## Show Markdown you wrote

When you write a plan, a design note, a report or docs the user should
read, show it rendered in KinTerm's Markdown Viewer instead of pasting it
into the chat: `kinterm-ctl markdown docs/plan.md` (`markdown`, with
`path`). It opens in a window of its own with the folder's other Markdown
files beside it, and reloads as you edit the file, so open it once and keep
writing. Give a folder (`kinterm-ctl markdown docs`) to open the viewer on
its Markdown files. The user can also open it with ⌘⇧M, or by ⌘-clicking a
`.md` path you print.

## Split big work across agents

For a task with independent parts, you can start other agents in tabs of
their own and coordinate them. Each one is a normal tab the user can
watch and type into.

```sh
kinterm-ctl agent spawn --name api --worktree -- claude "Add rate limiting to server/api.ts. Run its tests."
kinterm-ctl agent spawn --name docs -- claude "Document the rate limits in docs/api.md."
kinterm-ctl agent wait api docs          # until each finishes its turn or needs someone
kinterm-ctl agent read api --lines 80    # what it did, or what it's asking
kinterm-ctl agent send api "Use the redis store, not in-memory."
kinterm-ctl agent kill docs
```

The MCP tools are `agent_spawn`, `agent_list`, `agent_wait`, `agent_read`,
`agent_send`, `agent_kill` and `agent_release`.

- Give each worker a complete, self-contained task: it doesn't see your
  conversation.
- Use `--worktree` (`worktree: true`) when workers change the same
  repository, so they don't overwrite each other's files. Each gets a
  branch `kinterm/<name>`. Merge or report the branches when they're done.
- `wait` returns when a worker is done, blocked (it asked a question or
  needs a permission: read it, then answer with `send` or tell the user),
  errored, or its command exited. Check what each one did before you
  report success.
- Spawn a handful at most, and only when the parts really are
  independent. A worker can't start workers of its own unless you pass
  `--allow-spawn`.
- `agent release` hands a worker over to the user if they want to take it.

You can only control the terminals you started, never the user's other
tabs. Don't try to work around that.

## Don't

- Don't open the user's own browser (`open http://…`) for local dev
  servers; use `kinterm-browser open`.
- Don't run `kinterm-browser` outside KinTerm (no `KINTERM_BROWSER_SOCKET`);
  it can't do anything there.
