# 8 · Code Review (⌘⇧R)

Check what an agent changed before you trust it: the changed files with
GitHub-style diffs, the repository's files, and line comments you send back
to the agent.

- **Open:** View › Review Changes or `⌘⇧R`. It reviews the git repository of
  the focused tab's folder. `⌘⇧R` again hides it.
- **Where:** beside the terminal (a side panel, drag its edge to resize) or
  in its own window. The header button moves it between the two, and `⌘⇧R`
  opens it wherever you used it last.
- **In Grid View:** `⌘⇧R` adds a **Review tile** to the grid, next to the
  agent tiles, and the grid lays out again with one more tile (3 tabs +
  review → 2×2). Every agent stays on screen. The tile reviews the agent tile
  you were last in, so click into another agent to review its changes. Its
  header shows the face and title of the tab under review, a button to move
  the review to its own window, and close (`⌘⇧R` again does the same). In a
  narrow tile the file list sits above the diff; in a wide one, beside it.
- **Changes tab:** changed files with a status badge (`M` `A` `D` `R`) and
  `+added −removed`, a summary line, and `N/M viewed` progress.
  - **Scope:** _Uncommitted_ (working tree vs HEAD, new files included),
    _This Session_ (since the agent's first prompt in this tab) or _Last
    Turn_ (since your latest prompt). The tree is snapshotted with
    `git stash create` when the agent starts working, which touches nothing.
  - **Diff:** old and new line numbers, red/green lines, hunk headers,
    syntax colors, long lines wrap.
  - **Viewed:** checkbox per file. Checking it opens the next unviewed file.
    It clears if the file changes again.
  - **Revert:** hover a hunk header for _Revert Change_ (just that part);
    the file header's revert button puts back the whole file (new files go to
    the Trash). Only the working tree changes, never the index.
- **Files tab:** the repository's files (tracked and untracked, ignored ones
  left out) as a tree, changed files and folders marked, with a filter.
  Click a file to read it with line numbers and syntax colors.
- **Comments:** hover a line, click `+`, write, `↵`. Add an optional note in
  the footer, then **Send**. The comments are typed into the agent's prompt
  as `path:line`, the quoted code and your text, without pressing Return, and
  the tab comes forward (in Grid View: the keyboard goes to that agent's
  tile) so you can read it over and send it.
- Refreshes when opened, when the agent stops working, when its window
  becomes key, and with the refresh button. There's no file watching, so it
  costs nothing while you aren't looking at it.

Colors follow the shared tokens; diff colors are GitHub's dark ones.

Implementation: `macos/Sources/Features/Code Review/`.
