# KinTerm's browser

Chromium (CEF), loaded only when a browser is opened. See
`scope/designs/09-browser.md` for what it does.

## Build

```sh
macos/Browser/build.sh     # downloads CEF (checked against its SHA-256), builds the module and helpers
macos/build.nu             # the "Embed Browser" phase copies them into KinTerm.app and signs them
```

Without `build.sh`, KinTerm builds as before, without the browser.
`build.sh --clean` starts over. `CEF_ROOT=/path/to/cef_binary_…` uses a CEF
you already have.

## Pieces

| Path                         | What                                                                 |
| ---------------------------- | -------------------------------------------------------------------- |
| `src/kinterm_browser.mm`     | The module KinTerm `dlopen`s: CEF behind a small C API (`kt_browser_*`) |
| `src/helper_main.mm`         | Chromium's helper processes (`KinTerm Helper (…).app`), sandboxed     |
| `bin/kinterm-browser`        | The CLI, in `Contents/MacOS` so terminals have it on their PATH       |
| `bin/kinterm-browser-mcp.mjs`| MCP server: Chrome DevTools MCP on this browser, started on first use |
| `embed.sh`                   | Xcode build phase: copy into the app and sign                         |

The Swift side is `macos/Sources/Features/Browser`.

## Updating Chromium

Set `CEF_VERSION` and `CEF_SHA256_ARM64` in `build.sh` from
<https://cef-builds.spotifycdn.com/index.html> (macOS ARM64, the "minimal"
distribution), then run `build.sh`. Security fixes in Chrome reach KinTerm
this way, so keep it current.

## Signing

`embed.sh` signs with the build's identity (ad hoc in Debug). For release,
`sign.sh <app> <identity>` signs Chromium's libraries, its framework, the
module and the helpers with the hardened runtime and a timestamp, the
helpers with `helper.entitlements` (JIT for V8). The release workflow and
`scripts/release-mac.sh` run it before signing the app. Everything must be
signed by the same team, since the main app keeps library validation on;
the main app itself needs no extra entitlements (checked with the hardened
runtime and `Ghostty.entitlements`).
