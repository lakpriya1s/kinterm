# 9 · Browser (⌘⇧B)

A browser for development inside KinTerm: see your dev server next to the
agent working on it, inspect it with Chrome's DevTools, and let agents drive
it. It's Chromium (CEF), so pages behave like they do in Chrome.

- **Open:** View › Browser or `⌘⇧B`, or `kinterm-browser open 3000` in any
  KinTerm terminal. `⌘`-clicking a `localhost` link in a terminal opens it
  here too (View › Browser Options › Open Localhost Links Here).
- **Where:** beside the terminal, one browser per tab (drag its edge to
  resize). **In Grid View** it's one more tile in the grid, like the review
  tile; every agent stays on screen.
- **Own window:** the window button in the toolbar (or the grid tile's
  header, or `kinterm-browser window`) moves the browser into a window of
  its own that you can resize and put anywhere; the same button there puts
  it back beside the terminal. The page reloads at the same address on the
  move (Chromium doesn't draw a view moved to another window), and docked
  DevTools come along.
- **Address bar:** a port (`3000`) or `localhost:5173` opens the local dev
  server, a domain gets https, anything else is a search.
- **DevTools** (🔨 or `⌥⌘I`): docked under the page in the panel, with a
  draggable divider, and a **tile of its own** in a grid. The header button
  moves them into a window. All of Chrome's DevTools: Elements, Console,
  Sources, Network, Performance, Memory, Application.
- **Console errors** show as a red count in the toolbar; click it for
  DevTools.

## Agents

- **MCP:** View › Browser Options › Let Agents Use the Browser… adds a
  `kinterm-browser` MCP server to Claude Code (each account) and Codex with
  their own `mcp add` commands. It's Chrome DevTools MCP pointed at this
  browser: pages, clicks, typing, forms, screenshots, accessibility
  snapshots, console, network requests, performance traces, Lighthouse.
  Needs Node.js. Usage statistics and CrUX lookups are turned off.
- **CLI:** `kinterm-browser open|reload|back|forward|devtools|window|close|status|port`
  is on every KinTerm terminal's PATH.
- **Seeing what an agent does:** while an agent's tool call runs, the
  toolbar shows an **Agent** badge, KinTerm blue (`#5CA0FF`) glows in from
  the page's edges, breathing slowly, and a
  blue cursor glides to where the agent moves, ripples where it clicks and
  rings the field it types into. It's drawn only while an agent is active,
  so your own mouse never gets a second cursor, and it's removed from the
  page when the agent finishes.

## Cost

- **Nothing until it's used.** KinTerm doesn't link Chromium; it loads the
  browser module with `dlopen` the first time a browser opens. Before that
  KinTerm only listens on a Unix socket (no CPU).
- **While open:** one page process plus Chromium's GPU and service
  processes; idle pages use no measurable CPU. Closing a browser ends its
  page process. Chromium's GPU and service processes stay until KinTerm
  quits.
- **App size:** about 330 MB more (Chromium). Builds without
  `macos/Browser/build.sh` don't include it and say how to get it.

## Safety

- The profile (cookies, storage) is KinTerm's own, in
  `~/Library/Application Support/<bundle id>/Browser`, not a browser you use
  day to day. Cookies aren't encrypted with a Keychain item.
- Chromium's sandbox is on for every page process.
- The DevTools Protocol port listens on 127.0.0.1 only, on a port picked at
  launch. Any program you run can reach it while the browser is open, as
  with Chrome's remote debugging.
- The control socket can only be used by you (0600).
- Links that would open new windows open in the same browser.

## Limits

- Apple silicon only for now.
- One page per browser; agents see every open KinTerm browser as a page.
- Chromium updates come with KinTerm updates: bump `CEF_VERSION` in
  `macos/Browser/build.sh`.
