# SingBoxMenuBar

Minimal macOS menu-bar app that supervises a local `sing-box` process directly —
no Network Extension, no custom IPC. See `macOS_Proxy_Client_Menu_Bar_v2.md` for the
full requirements this implements.

This was authored in a Linux sandbox without a Swift toolchain, so **it has not been
compiled or run yet**. Treat this as a solid first draft to build and debug on your
Mac Mini, not verified-working code. See "Things to check on first build" below.

## Layout

```
Package.swift
Info.plist.template
Sources/SingBoxMenuBar/
  main.swift                  — entry point, menu-bar-only activation policy
  AppDelegate.swift           — NSStatusItem + NSMenu, wires everything together
  SingBoxProcessManager.swift — spawns/stops sing-box, validates config, detects crashes
  ClashAPIClient.swift        — HTTP calls to sing-box's Clash API for live mode switch
  SystemProxyManager.swift    — networksetup wrapper + admin-prompt via AppleScript
  ConfigManager.swift         — lists profile files for the Switch Profile submenu
  Preferences.swift           — UserDefaults-backed settings (mode, active profile)
  IconRenderer.swift          — draws the base symbol + R/G/D badge
  LaunchAtLogin.swift         — SMAppService wrapper
  Logger.swift                — flat-file logging to ~/Library/Logs/singbox-menubar/
```

## Quick run during development (no bundle)

```bash
cd singbox-menubar
swift build
swift run
```

This gets you a working menu-bar icon for iterating quickly. Two things won't fully
work in this mode:
- **Launch at Login** (`SMAppService.mainApp`) generally needs a real `.app` bundle.
- The Dock/activation policy is set in code (`main.swift`) rather than via `Info.plist`,
  which is fine for `swift run` but should move to the plist once bundled.

## Building a real .app bundle

Simplest path once you're happy with `swift run` behavior: create an Xcode project
(File → New → Project → macOS → App), add these Swift files to it instead of using
SwiftPM directly, paste `Info.plist.template` contents into the generated Info.plist,
and build/archive normally. Xcode also makes ad-hoc signing (needed for `SMAppService`
and for the app to persist an identity across launches) trivial via
"Signing & Capabilities" → your personal team.

Alternatively, SwiftPM can still produce a bundle manually (`swift build -c release`,
then hand-assemble `SingBoxMenuBar.app/Contents/{MacOS,Resources}` and `Info.plist`),
but Xcode is less fiddly for this step.

## Things to check on first build

1. **`sing-box` binary path** (`SingBoxProcessManager.singBoxBinaryPath`) — confirm
   `/opt/homebrew/bin/sing-box` is actually where `brew` put it:
   `which sing-box`.
2. **Clash API port/secret** (`ClashAPIClient.baseURL`, `.secret`) — must match what's
   in your actual sing-box config's `experimental.clash_api` block.
3. **Outbound selector group name** (`ClashAPIClient.setMode`'s `selectorGroup`
   parameter, default `"GLOBAL"`) — must match the selector-type outbound tag in your
   config, or mode-switch-while-running will silently 4xx. If your config doesn't
   define a Clash-API-compatible selector group, live-switching won't work and you'll
   want to fall back to "always restart on mode change" — that's a one-line change in
   `AppDelegate.selectMode`.
4. **Local proxy host/port** (`SystemProxyManager.proxyHost/proxyPort`, default
   `127.0.0.1:7890`) — must match your config's HTTP inbound.
5. **Profiles directory** (`Preferences.profilesDirectory`, default
   `~/.config/sing-box/`) — point this at wherever your `.yaml`/`.json` configs
   actually live.
6. **Icon rendering** (`IconRenderer`) is a placeholder circle+badge, not a designed
   asset — swap in a real icon whenever you want it to look nicer; the R/G/D badge and
   two-color-state logic are the only things the spec actually requires.
7. First "Enhanced Mode" or "Set as System Proxy" click will trigger a macOS admin
   password prompt (via AppleScript `do shell script ... with administrator
   privileges`) — that's expected, per the "prompt per action" v1 approach.

## One-time setup: passwordless sudo

Both System Proxy (`networksetup`) and Enhanced Mode/TUN (sing-box creating a utun
interface) genuinely need root on macOS — that part isn't avoidable. What *is*
avoidable is being asked for your password on every single toggle. A one-time
`sudoers.d` rule, scoped only to the exact commands this app runs, fixes that for good.

**1. Open a sudoers editor session** (always use `visudo` — it validates syntax before
saving, so a typo can't lock you out of sudo):

```bash
sudo visudo -f /etc/sudoers.d/singbox-menubar
```

**2. Paste this in** (replace `john` with your actual username if different — check
with `whoami`; adjust the sing-box path too if `which sing-box` shows something other
than `/opt/homebrew/bin/sing-box`):

```
john ALL=(root) NOPASSWD: /usr/sbin/networksetup -setwebproxy *, \
                          /usr/sbin/networksetup -setsecurewebproxy *, \
                          /usr/sbin/networksetup -setwebproxystate *, \
                          /usr/sbin/networksetup -setsecurewebproxystate *, \
                          /opt/homebrew/bin/sing-box *
```

**3. Save and exit** (`:wq` if visudo opens vi). If it reports a syntax error, it will
refuse to save and drop you back in the editor — fix the typo and try again; your
existing sudo config is untouched either way.

**4. Relaunch the app.** From then on, toggling System Proxy or Enhanced Mode should
happen instantly with no password dialog.

**Security note:** the sing-box line is scoped to that one binary but allows any
arguments, since the app needs to pass `-c <config path>` and that path varies. On a
personal, single-user Mac this is a reasonable tradeoff for the convenience; anyone
with a shell on this account could already run sing-box as themselves, so granting it
root doesn't meaningfully change your threat model here. If you'd rather lock it down
further, you can anchor the rule to a specific config path instead of leaving it open,
at the cost of needing to update the sudoers rule whenever you add a new profile.

If you skip this step, System Proxy will still work via an admin-password prompt each
time (the app falls back automatically), but Enhanced Mode/TUN will refuse to start and
point you back to this section — a long-running process doesn't fall back to a prompt
gracefully, so it requires the setup.

## Logs

- `~/Library/Logs/singbox-menubar/app.log` — app-level events (mode switches, errors,
  proxy toggles, crash detection)
- `~/Library/Logs/singbox-menubar/sing-box.log` — raw sing-box stdout/stderr,
  truncated fresh on each start

Menu → "Reveal Logs in Finder" opens the containing folder directly.
