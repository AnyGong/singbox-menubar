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
  AppNotifier.swift           — posts macOS notifications for key state changes
  ConfigFileWatcher.swift     — kqueue-based watcher for external edits to the active profile
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
   in your actual sing-box config's `experimental.clash_api` block. The default is
   `http://127.0.0.1:9090` and no secret. If your config uses a different port or has
   `secret`, update these accordingly.

3. **Clash API mode switch** — The app switches Direct/Global/Rule by calling
   `PATCH /configs` with a top-level `{"mode": "..."}` body. There is no selector
   group involved. For this to work, your sing-box config must expose all three modes
   in `mode-list`. A minimal `route` section to achieve this is:

   ```json
   "route": {
     "rules": [
       { "clash_mode": "Direct", "outbound": "direct" },
       { "clash_mode": "Global", "outbound": "direct" }
     ],
     "final": "direct"
   }
   ```

   If `mode-list` only contains `["Rule"]`, API calls to change mode will return
   success but the mode will not change. Ensure the above rules are present before
   testing live mode switching.

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
   privileges`) — that's expected, per the "prompt per action" v1 approach. See the
   next section for a one-time setup that eliminates the prompts.

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

## Notifications

The app posts macOS notifications (via `UNUserNotificationCenter`, see
`AppNotifier.swift`) for:

- Outbound mode changed (Direct / Global / Rule), whether switched from the menu or
  detected as changed externally via the Clash API
- System Proxy enabled / disabled, from the menu, dangling-cleanup, or detected
  externally via `networksetup`
- Enhanced Mode (TUN) enabled / disabled
- sing-box started / stopped, including unexpected exits (crashes) — shown as a
  distinct "Stopped Unexpectedly" notification with the exit status
- The active configuration file changing on disk outside the app (see below)

These are local notifications only — no network calls, no third-party service — and
are entirely best-effort: if you haven't granted the app notification permission (or
have it disabled in System Settings → Notifications, or Focus/DND is on), they
silently don't show, and nothing else about the app's behavior changes. The first
launch will prompt for permission once; **on `swift run` (no bundle), macOS will
likely refuse to authorize a bare binary, or the request may silently fail** — this
is a `swift run`-only limitation, and is expected to resolve once you package the app
per "Building a real .app bundle" above.

Notifications for a given category (e.g. all "System Proxy" ones) replace each other
rather than piling up, so rapid toggling won't spam Notification Center — you'll
always just see the latest state.

### Auto Reload on Config Change

The app watches the active profile file for changes made outside it (hand-editing,
a sync tool, a generator script, etc.) using a `DispatchSourceFileSystemObject`
(no polling). Whenever it detects a change:

- It always posts a "Configuration Changed" notification.
- If the new **Auto Reload on Config Change** menu item (under the profile section,
  next to "Reload Configuration") is **on**, it also reloads automatically — the
  same restart-with-active-profile path as clicking "Reload Configuration" by hand.
- If it's **off** (the default), it only notifies; you reload manually whenever
  you're ready.

This only does anything while sing-box is actually running that profile — if it's
stopped, you just get the notification, since there's nothing to reload.

## Logs

- `~/Library/Logs/singbox-menubar/app.log` — app-level events (mode switches, errors,
  proxy toggles, crash detection)
- `~/Library/Logs/singbox-menubar/sing-box.log` — raw sing-box stdout/stderr,
  truncated fresh on each start

Menu → "Reveal Logs in Finder" opens the containing folder directly.