# Releasing KinTerm

Pushing a `kinterm-vX.Y.Z` tag runs `.github/workflows/kinterm-release.yml`.
It builds KinTerm, signs and notarizes it, publishes a GitHub release with
`KinTerm.dmg`, and adds it to the update feed at
`https://lakpriya.com/kinterm/appcast.xml`. Installed copies find
the update there through Sparkle.

Dev builds have no feed or update key, so they never update. Only builds
from this workflow do (`UpdateController.isEnabled`).

Both release paths include the browser: they run `macos/Browser/build.sh`
(Chromium, cached in CI by its version) and sign it with
`macos/Browser/sign.sh` before the app. It adds about 330 MB to the app and
runs on Apple silicon only; on Intel Macs the browser says so.

## A DMG from this Mac (no CI)

```sh
scripts/release-mac.sh 0.1.0
```

Builds, signs with the CodeScale Developer ID, notarizes with the
`burnarc-notary` keychain profile and staples `macos/build/dmg/KinTerm-0.1.0.dmg`.
No App Store Connect login or GitHub secrets needed. The app carries the
update feed and key, so it takes later updates once they're published.
It leaves a ReleaseFast core behind: `scripts/dev-run.sh --core` after.

### Publishing it (how 0.1.2 went out)

The CI secrets aren't set yet, so 0.1.2 was published by hand:

```sh
V=0.1.2
B=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" macos/build/Release/KinTerm.app/Contents/Info.plist)
C=$(/usr/libexec/PlistBuddy -c "Print :GhosttyCommit" macos/build/Release/KinTerm.app/Contents/Info.plist)
cp macos/build/dmg/KinTerm-$V.dmg /tmp/rel/KinTerm.dmg      # the feed expects this name
cd /tmp/rel
# Sparkle's tool, from Xcode's package cache (DerivedData/Ghostty-*/SourcePackages/artifacts/sparkle/Sparkle/bin)
sign_update --account kinterm KinTerm.dmg > sign_update.txt
curl -sfO https://lakpriya.com/kinterm/appcast.xml || true  # keep earlier releases
KINTERM_VERSION=$V KINTERM_BUILD=$B KINTERM_COMMIT=$C KINTERM_COMMIT_LONG=$(git rev-parse $C) \
  KINTERM_TAG=kinterm-v$V GITHUB_REPOSITORY=lakpriya1s/kinterm \
  python3 path/to/dist/macos/kinterm_appcast.py && mv appcast_new.xml appcast.xml
gh release create kinterm-v$V KinTerm.dmg --target $(git rev-parse $C) --title "KinTerm $V" --notes-file notes.md
```

Then commit `appcast.xml` to the `gh-pages` branch, next to the site. Tag
the commit the app was built from (`GhosttyCommit` in its Info.plist).

## One-time setup (CI releases)

### 1. Developer ID certificate

An existing **Developer ID Application** certificate works; one team's
certificate can sign any number of apps. (Apple Development and Mac App
Distribution certificates don't.) The developer name macOS shows for
KinTerm is the certificate's team. Skip to 2 if you have one.

1. Xcode › Settings › Accounts › your team › Manage Certificates… › `+` ›
   **Developer ID Application**.
2. In Keychain Access, find "Developer ID Application: …", right-click ›
   Export… as `kinterm.p12` with a password.
3. Its exact name, for `MACOS_CERTIFICATE_NAME`:
   `security find-identity -v -p codesigning` (e.g.
   `Developer ID Application: Your Name (TEAMID1234)`).

### 2. Notarization key

App Store Connect › Users and Access › Integrations › **Team Keys** ›
generate a key with the Developer role. Note the **Issuer ID** and **Key
ID**, and download the `.p8` (it can only be downloaded once). An existing
key of the same team works if you still have its `.p8`.

### 3. Sparkle update keys

```sh
curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip -o sparkle.zip
unzip sparkle.zip -d sparkle
sparkle/bin/generate_keys --account kinterm                         # prints the public key
sparkle/bin/generate_keys --account kinterm -x sparkle_private.key  # exports the private key
```

`--account kinterm` keeps these separate from any other app's Sparkle keys
in the keychain; without it, `generate_keys` reuses an existing key pair.

**Back up the private key** (a password manager). Without it no update
can ever be signed, and installed copies stop updating for good.

### 4. GitHub secrets

```sh
gh secret set MACOS_CERTIFICATE --body "$(base64 -i kinterm.p12)"
gh secret set MACOS_CERTIFICATE_PWD             # the .p12 password
gh secret set MACOS_CERTIFICATE_NAME            # from step 1.3
gh secret set MACOS_CI_KEYCHAIN_PWD --body "$(openssl rand -base64 24)"
gh secret set APPLE_NOTARIZATION_ISSUER         # Issuer ID
gh secret set APPLE_NOTARIZATION_KEY_ID         # Key ID
gh secret set APPLE_NOTARIZATION_KEY < AuthKey_XXXXXXXXXX.p8
gh secret set SPARKLE_PUBLIC_KEY                # from generate_keys
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private.key
```

Then delete the local `.p12`, `.p8` and `sparkle_private.key` copies.

### 5. GitHub Actions

Actions are off in a new fork; turn them on (Actions tab). Ghostty's own
workflows run on runners this repo doesn't have, so disable them and keep
only `KinTerm Release`:

```sh
for w in test.yml nix.yml flatpak.yml snap.yml milestone.yml \
  release-tip.yml release-tag.yml publish-tag.yml clean-artifacts.yml \
  update-colorschemes.yml vouch-check-issue.yml vouch-check-pr.yml \
  vouch-manage-by-discussion.yml vouch-manage-by-issue.yml \
  vouch-sync-codeowners.yml; do
  gh workflow disable "$w" --repo lakpriya1s/kinterm
done
```

### 6. GitHub Pages

The first release creates the `gh-pages` branch. Then: Settings › Pages ›
Deploy from a branch › `gh-pages`, `/ (root)`. Check that
`https://lakpriya.com/kinterm/appcast.xml` loads.

**Don't rename the repo after the first release.** The feed URL is built
into every copy, and Pages URLs don't redirect after a rename. The pages are
served on the owner's custom domain, lakpriya.com (set on the
lakpriya1s.github.io repo, behind Cloudflare). Keep it: the plain
`lakpriya1s.github.io/kinterm/` address redirects through http, which
macOS blocks for the update check.

## Each release

```sh
git tag kinterm-v0.1.0
git push origin agent-tabs kinterm-v0.1.0
```

Versions are `X.Y.Z`, set by the tag; the build number is a UTC timestamp
(`YYYYMMDDHHMM`), so it always goes up, here and in `scripts/release-mac.sh`. Watch the run under Actions. When it's done the
release is on GitHub and running copies offer it on their next check (or
from KinTerm › Check for Updates…). How eagerly is the `auto-update`
config key: `check` (the default prompt), `download`, or `off`.

## The web page

`site/` is the KinTerm page: one `index.html`, no build step. Open it
locally with `python3 -m http.server -d site`. To publish it:

```sh
scripts/publish-site.sh
```

It copies `site/` to the `gh-pages` branch next to `appcast.xml` (which it
leaves alone). The first time, turn Pages on: Settings › Pages › Deploy
from a branch › `gh-pages`, `/ (root)`. The page is then at
`https://lakpriya.com/kinterm/`. Its Download buttons open
`releases/latest`, so they work once a release is on GitHub.

## Bringing in Ghostty's changes

```sh
git fetch upstream
git merge upstream/main     # conflicts stay in the files KinTerm changed
zig build -Demit-macos-app=false && scripts/dev-run.sh
```

Check the app, then release it as the next KinTerm version.
