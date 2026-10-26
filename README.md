# SysWatch

Menu bar monitor for macOS 14+. Native Swift/SwiftUI, no dependencies, ~25 MB idle.

## Install

**Download:** [rishavkr08.github.io/SysWatch](https://rishavkr08.github.io/SysWatch/). Or paste this into Terminal, which installs it with no security prompt:

```sh
curl -fsSL https://github.com/rishavkr08/SysWatch/releases/latest/download/install.sh | sh
```

### Build from source

You need macOS 14 Sonoma or later, on Apple silicon or Intel. You also need Apple's Command Line Tools. Xcode is not required.

1. Install the Command Line Tools, once per Mac. Skip this if `swift --version` already works.

   ```sh
   xcode-select --install
   ```

2. Clone, build and install. This builds for your Mac and copies the app to /Applications. It takes about a minute.

   ```sh
   git clone https://github.com/rishavkr08/SysWatch.git
   cd SysWatch
   ./build.sh --install
   ```

3. When macOS asks whether SysWatch may send notifications, click **Allow**. Without it, alerts stay silent.
4. Click the dot in the menu bar to open the panel. Tick **Launch at login** in its footer to keep it running.

To check that alerts work, post one sample notification of each kind:

```sh
/Applications/SysWatch.app/Contents/MacOS/SysWatch --demo-alerts
```

**Update:** `git pull && ./build.sh --install`

**Uninstall:** quit it from the panel footer, then delete `/Applications/SysWatch.app`.

The app builds on your own Mac, so macOS trusts it and shows no "unidentified developer" warning. Do not pass the built `SysWatch.app` around instead: it is not notarized, so macOS blocks it on other Macs.

**Ask Claude** copies a prompt and brings the Claude desktop app to the front. Without Claude installed, the prompt is still copied to the clipboard.

## What it does

- Menu bar shows a green/orange/red dot plus `CPU% · memory%`. Orange = within 80% of a limit, red = over it.
- Overview tab: ring gauges for CPU, memory and disk with 10-minute sparklines; a memory breakdown bar (App, Wired, Compressed, Free) and swap with its growth rate; processes grouped by app as a share-of-RAM bar chart; recent alerts.
- Processes tab: every app group, sortable by memory or CPU, expandable to its processes. Row menu: Ask Claude / Quit all / Force quit.
- Alerts tab: history of what fired and why.
- Notifications for memory (incl. swap and kernel memory pressure), sustained CPU, thread count and low disk,
  each at most once per cooldown. Notification buttons: Quit process, and Ask Claude when a Claude Code session started it.
- Rows started by a Claude Code session get an "Ask Claude" button: it copies a prompt describing the process
  (command, footprint, machine state, project folder, session id) to the clipboard and brings Claude to the front. Paste it.
- Root-owned processes ask for an admin password through the normal macOS dialog.

## Releasing a download

```sh
./release.sh   # universal app, dist/SysWatch.dmg, dist/SysWatch.zip, dist/SHA256SUMS, dist/install.sh
gh release create v1.0 dist/SysWatch.dmg dist/SysWatch.zip dist/SHA256SUMS dist/install.sh --title "SysWatch 1.0"
```

The landing page is `docs/index.html`; GitHub Pages serves it from the `docs` folder. Its download button and one-line install both use the
`releases/latest/download/…` URLs, so a new release updates them with no page change. Bump `CFBundleShortVersionString` in `Info.plist` and
the version line in `docs/index.html` before each release.

Without a Developer ID the app is ad-hoc signed: the DMG download asks users to click Open Anyway once, and the one-line install
(`curl … | sh`) skips that because curl downloads are not quarantined. With an Apple Developer ID certificate in the keychain and
`NOTARY_PROFILE` set (see the top of `release.sh`), the same script signs, notarizes and staples, and the DMG opens with no prompt.

## Development

```sh
swift tools/icon.swift icns A AppIcon.icns   # (only if the icon drawing changed) concepts A–E live in tools/icon.swift
./build.sh            # builds ./SysWatch.app
open SysWatch.app     # first launch asks for notification permission
./build.sh --install  # or: copy to /Applications and launch
swift build && .build/debug/SysWatch --check   # self-check of the parsing / detection / alert logic
/Applications/SysWatch.app/Contents/MacOS/SysWatch --demo-alerts   # post one sample notification of each kind
```
