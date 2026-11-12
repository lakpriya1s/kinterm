---
name: kinterm
description: Use when running inside KinTerm (KINTERM_BROWSER_SOCKET is set) and working on anything with a web UI, a dev server, or changes the user will review. Shows the app in KinTerm's built-in browser, checks it with DevTools, and hands changes over for review.
---

# Working inside KinTerm

KinTerm is the terminal you're running in. It has tools for showing the user
your work. Use them when they help; they cost nothing when you don't.

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

## Hand changes over for review

The user reviews your changes in KinTerm with ⌘⇧R (Review Changes): diffs
of the repository, revert per hunk, and comments that come back to you as
a message. When you finish a task, say which files to look at first.
Comments arrive as a list of `file:line` notes; address each one.

## Don't

- Don't open the user's own browser (`open http://…`) for local dev
  servers; use `kinterm-browser open`.
- Don't run `kinterm-browser` outside KinTerm (no `KINTERM_BROWSER_SOCKET`);
  it can't do anything there.
