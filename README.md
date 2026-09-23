# Longbrew

**[Download](https://github.com/echoparkbaby/longbrew/releases/latest)** ·
**[longbrew website](https://echoparkbaby.github.io/longbrew/)**

A macOS menu-bar app (menulet) that toggles **clamshell / lid-closed sleep** on
and off, with a state indicator in the menu bar.

- **ON**  → `pmset -a disablesleep 1` — the Mac stays awake with the lid
  closed (no external display/power required).
- **OFF** → `pmset -a disablesleep 0` — normal behaviour restored.

The privileged call runs through a small root helper (see below), not `sudo`.

## Clicking it

| Click | Does |
|-------|------|
| Click | Toggle **Caffeinated** (⌘C) |
| Option-click | Toggle **lid-closed mode** |
| Right-click / control-click | The menu |

Choose a duration directly from each mode’s duration submenu: 30 minutes,
1 / 2 / 4 / 8 hours, until you quit, or until turned off. The menu shows the selected
duration, not a countdown. Clicking the mug toggles immediately with no duration dialog.
Choices are remembered; changing one during a session restarts its duration from now. Caffeinated always ends on quit. An explicit
until-quit lid-closed session restores normal sleep before exiting; if restoration
fails, the app stays open. Timed shutoff requires Longbrew to remain running.
Both modes are in the menu too (⌘E / ⌘K). No remaining-time counter is displayed.

Longbrew always starts with everything off and the mug empty. If it finds
lid-closed mode still on from last time (it's a system setting, so it survives a
quit or a restart), it turns it back off — with a banner saying so.

**Caffeinated** is a plain power assertion — the same mechanism `caffeinate` uses.
It stops idle sleep while Longbrew is running, needs no helper and no
approval, and the kernel drops it the moment the app quits. The lid still has to stay open; only lid-closed mode covers a shut
lid.

Either mode flipping posts a banner, so you're told when the auto-off timer
switches lid-closed mode back off hours later. Turn them off in System Settings →
Notifications like any other app.

## Settings

**Settings…** (⌘,) from the menu, or the menu-bar icon → right-click → Settings.

- **Launch at login**
- **Also go Caffeinated when lid-closed mode turns on** — off by default. Lid-closed
  alone keeps the Mac running but lets the screen go dark; tick this to keep the
  screen lit too. Longbrew switches it back off with lid-closed mode, unless you
  toggled Caffeinated yourself.
- **Tint the mug orange while lid-closed mode is on** — steam and a bolt are both
  plain black at menu-bar size; the colour is what tells them apart at a glance.
- **Turn off lid-closed mode automatically** — never / 1 / 2 / 4 / 8 hours. Lid-closed
  mode is a system setting that survives a restart, so this is the backstop against a
  laptop staying awake in a bag all night. The timer re-arms whenever the mode is switched on (including from a terminal), and
  fires silently — there's usually nobody looking at the screen when it does.
- Install/remove the **privileged helper**, plus version, author and links.

> **What ON really does.** `disablesleep 1` disables *all* sleep, not just the
> lid-closed kind: no idle sleep, and the Apple menu's Sleep item greys out.
> That's what makes clamshell mode work, but it also means more battery use and
> a warm machine in a bag. Turn it off when you're done. The setting is
> **system-wide and survives a reboot**, so Longbrew asks before quitting
> while it's on.

The menu-bar icon is one square coffee mug that fills up as the Mac wakes up:

| Icon | State | Meaning |
|------|-------|---------|
| empty mug | off | Sleeps normally |
| steaming mug | Caffeinated | Stays awake, lid must stay open |
| orange mug + bolt, no steam | lid-closed mode | Stays awake with the lid shut; screen may sleep |
| orange mug + bolt + steam | lid-closed + Caffeinated | Lid can shut, screen stays on |

The first two are template images, so they adapt to a light or dark menu bar;
the orange picks a lighter or deeper shade for the same reason. It polls
every 5 s, so changes made elsewhere (e.g. `pmset` in a terminal) are reflected
too.

> **This is a laptop feature.** Clamshell sleep only exists on a MacBook — run
> Longbrew there, not on a desktop Mac (a Studio/mini has no lid).

## Build

```bash
cd "/path/to/your/checkout"
bash scripts/package.sh      # → Longbrew.app
```

Then drag `Longbrew.app` to `/Applications`. Enable **Launch at Login** from
its menu (or add it in System Settings → General → Login Items).

For a quick dev run without bundling: `swift run`.

## One-time setup: approve the privileged helper

Changing `disablesleep` needs root. Longbrew ships a tiny **privileged helper**
(a LaunchDaemon registered with `SMAppService`) instead of a sudoers rule — so
there is no Terminal step and nothing written to `/etc`.

1. Drag **Longbrew.app** to **/Applications**. This is required: a LaunchDaemon
   resolves its program *inside* the app bundle, so registering from a disk image
   or a movable folder leaves a root job pointing at a path that can vanish. The
   app refuses to register from anywhere else.
2. Open it and click **Install Privileged Helper…** (or just use the toggle — it
   offers).
3. macOS parks the helper pending approval. Turn on **Longbrew** under
   **System Settings → General → Login Items & Extensions → Allow in the Background**.

Both sides pin each other's Developer ID code signature, so no other process can
drive the root helper, and the app won't talk to an impostor helper.

**Removing it:** menu → *Privileged Helper (Installed)* → **Remove Helper**. If
sleep is currently disabled, Longbrew restores normal sleep *first* and
confirms it — removing the helper while the Mac is set never to sleep would strand
it awake with nothing left to undo it.

**Scripted / MDM deployment:**

```bash
/Applications/Longbrew.app/Contents/MacOS/longbrew --install-helper
/Applications/Longbrew.app/Contents/MacOS/longbrew --helper-status
/Applications/Longbrew.app/Contents/MacOS/longbrew --uninstall-helper
```

These exit non-zero on failure. Approval is still a user action.

**Upgrading:** a running helper is not replaced automatically by launchd, so the
app checks the running helper's generation at launch and re-registers if it is
stale. The helper also exits after two minutes idle.

## Layout

- `Sources/longbrew/` — the menu-bar app.
  - `main.swift` — entry point + CLI flags (`--self-test`, `--*-helper`).
  - `AppController.swift` — `NSStatusItem`, click routing, menu, alerts, auto-off,
    termination guard.
  - `HelperClient.swift` — XPC to the root helper; registration + update logic.
  - `SleepState.swift` — unprivileged `pmset -g` read and its parser.
  - `Caffeinated.swift` — the `IOPMAssertion` behind Caffeinated.
  - `Notify.swift` — banner notifications for both toggles.
  - `Settings.swift` / `SettingsWindow.swift` — preferences and the window.
- `Sources/LongbrewHelper/` — the root LaunchDaemon (one privileged method).
- `Sources/LongbrewShared/` — the XPC contract + code-signing requirements.
- `helper/…​.plist` — LaunchDaemon plist, embedded at `Contents/Library/LaunchDaemons/`.
- `scripts/make-mug-icons.swift` — draws the four menu-bar mugs. Run it after
  editing the art; the PNGs it writes are committed.
- `scripts/package.sh` — builds universal, embeds + signs helper inner-to-outer,
  and **asserts both XPC code-signing requirements**.
- `scripts/release.sh` — package → DMG → notarize → staple.

## Tests

```bash
Longbrew.app/Contents/MacOS/longbrew --self-test   # pmset parser checks
```

Uses `precondition`, so the checks are live in the release binary too.

## Support

Longbrew is free. If it saves you some hassle, a tip is always appreciated. I got kids!

[<img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="48" />](https://buymeacoffee.com/echoparkbaby)

## License

MIT — see [LICENSE](LICENSE).

## Renaming and upgrades

Longbrew was previously called Clamshelled. The macOS bundle identifiers,
helper service identifier, and XPC protocol runtime name intentionally keep
their original values so existing preferences and helper communication remain
compatible. The GitHub repository moved to echoparkbaby/longbrew.

To replace an installed Clamshelled copy, turn off both awake modes and uninstall
its privileged helper from its menu before quitting it. Move the old app out of
Applications, install Longbrew.app there, and register its helper from the menu.
Check Launch at Login in Longbrew if you previously enabled it.

Run `bash tests/helper-callbacks.sh` to verify that a missing helper returns errors
without crashing on the background XPC queue. The test uses an absent test service
and does not change power settings or helper registration.

Run `python3 tests/safety-regressions.py` for auto-off retry, startup recovery,
and power-read timeout checks. It exercises the production controller methods
with simulated helper/power state and never changes system power settings.

Failed auto-off attempts retry after 30 seconds. Startup repairs a stale helper
before restoring sleep, and retains restoration retries through helper failures
or pending approval, even when the optional auto-off timer is set to Never.
Power-state reads run away from the UI thread and time out after five seconds.

### Move to Applications from inside the app

When Longbrew launches outside Applications, it immediately shows a setup prompt with a real
**Move to Applications** button. It stages and verifies a signed copy, opens it
from Applications, and continues helper setup there. The source copy is retained,
and the running copy exits only after the installed app opens. An existing app
is never silently overwritten. Copy or launch errors keep the current app open
and offer **Show in Finder** for manual installation.

Run `bash tests/app-installer.sh` after packaging to test staging, signature
failure cleanup, existing-destination protection, and the built app signature.
These tests use temporary folders and never install into Applications.

### Helper status and diagnostics

Settings shows whether the helper is ready, awaiting approval, unreachable, or
needs an update. Its primary action changes to Install Helper, Open System
Settings, Check Connection, or Repair Helper. Readiness requires an actual helper
reply, not just a registered service. Connection checks are limited to once every
30 seconds unless explicitly requested.

Open **Diagnostics…** from Settings or the right-click menu to see the app version,
helper status, last successful power check, and the last 20 errors from the current
session. **Copy diagnostics** copies the current report. No report is sent automatically.

Run `bash tests/feature-ui.sh` to check helper actions and diagnostic behavior and
render the panels with simulated helper state. It does not register services or
change power settings.
