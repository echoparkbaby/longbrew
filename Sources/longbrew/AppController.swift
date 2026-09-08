import AppKit
import ServiceManagement
import UserNotifications
import LongbrewShared

// Longbrew — a menu-bar app that toggles clamshell (lid-closed) sleep on a Mac.
//
// ON  = `pmset -a disablesleep 1`  → Mac stays awake with the lid closed.
// OFF = `pmset -a disablesleep 0`  → normal behaviour restored.
//
// Reading state is unprivileged. WRITING goes through LongbrewHelper, a root
// LaunchDaemon registered with SMAppService and reached over XPC — macOS shows its
// own approval UI, so there's no sudoers file and no Terminal step. Both ends pin
// each other's Developer ID signature (see LongbrewShared/HelperProtocol.swift).

@MainActor
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Human-facing version. CFBundleShortVersionString must stay numeric for
    /// Apple, so the RC label rides along in a separate key.
    static var displayVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["LongbrewDisplayVersion"] as? String)
            ?? (info?["CFBundleShortVersionString"] as? String)
            ?? "?"
    }

    private var statusItem: NSStatusItem!
    private var pollTask: Task<Void, Never>?
    /// true → sleep is disabled (Mac stays awake when the lid closes).
    private var isEnabled = false
    /// The toggle is a round trip to a root daemon; a second click mid-flight would
    /// compute its target from a stale value and undo the first one.
    private var toggleInFlight = false
    /// When lid-closed mode should switch itself back off. nil = never.
    private var autoOffDeadline: Date?
    private var lidDuration: SessionDuration?
    private var espressoDeadline: Date?
    private let diagnostics = DiagnosticsWindowController()
    /// One-shot, so the banner can say *why* the Mac just changed on its own.
    private var autoOffJustFired = false
    private var relocating = false
    private var startupRestorePending = true
    private var startupRetryAfter = Date.distantPast
    private let settings = SettingsWindowController()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        Notify.start(delegate: self)
        settings.onChange = { [weak self] in self?.updateIcon() }
        settings.onAutoOffChanged = { [weak self] in
            self?.lidDuration = SessionDuration(rawValue: Settings.autoOffMinutes) ?? .untilTurnedOff
            self?.armAutoOff()
            self?.updateIcon()
        }
        settings.onToggleLoginItem = { [weak self] in self?.toggleLoginItem() }
        settings.onManageHelper = { [weak self] in self?.manageHelper() }
        settings.onRemoveHelper = { [weak self] in self?.presentHelperInstalled() }
        settings.onDiagnostics = { [weak self] in self?.openDiagnostics() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        // No `statusItem.menu` — that would swallow every click into the menu.
        // Left click toggles; right/control click pops the menu (see statusItemClicked).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
        // Offer installation before any helper checks or power reads can delay it.
        if !HelperClient.isInStableLocation {
            presentMoveToApplications(reason: "finish setup and enable lid-closed mode")
        }
        // An accepted move owns startup until it opens the installed copy or fails.
        if !toggleInFlight { startMonitoring() }
    }

    private func startMonitoring() {
        guard pollTask == nil else { return }
        // Repair first, then restore sleep. Keep retries pending through failures
        // and approval delays, even when the user has disabled the auto-off timer.
        toggleInFlight = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshState()
            await HelperClient.reregisterIfStale()
            self.toggleInFlight = false
            await self.refreshState()
            if CommandLine.arguments.contains("--complete-install"),
               HelperClient.isInStableLocation, !HelperClient.isEnabled {
                self.installHelper()
                self.settings.show()
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await self.refreshState()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings.refresh()
        refreshHelperStatus()
    }

    private func refreshHelperStatus() {
        guard !settings.helperBusy else { return }
        Task {
            await HelperClient.checkHealth()
            settings.refresh()
            diagnostics.refresh()
        }
    }

    @objc private func openDiagnostics() {
        diagnostics.show()
        refreshHelperStatus()
    }

    // MARK: - State

    private func refreshState() async {
        let was = isEnabled
        // Unknown state keeps the last known value rather than falsely showing "off".
        let liveState = await readDisableSleep()
        Diagnostics.recordPowerRead(liveState)
        if let state = liveState {
            isEnabled = state
            if !state { startupRestorePending = false }
        }
        // Arm on any off→on transition, including one made from a terminal, and on
        // finding it already on at launch — that's exactly the forgotten-overnight
        // case the timer exists for.
        if isEnabled && !was { armAutoOff() }
        if liveState == false { autoOffDeadline = nil; lidDuration = nil }
        // Every route in and out of lid-closed mode lands here — the icon click, the
        // menu, auto-off, someone running pmset in a terminal — so this is the one
        // place a banner covers all of them. Finding it already on at launch counts:
        // that's the state that survived a reboot and is worth being told about.
        if isEnabled != was { postLidBanner() }
        restoreSleepAtStartupIfNeeded()
        fireAutoOffIfDue()
        if let espressoDeadline, Date.now >= espressoDeadline, Espresso.isOn {
            toggleEspresso()
        }
        updateIcon()
        settings.refresh()
        diagnostics.refresh()
        refreshHelperStatus()
    }

    private func restoreSleepAtStartupIfNeeded() {
        guard startupRestorePending, isEnabled, !toggleInFlight,
              HelperClient.isEnabled, Date.now >= startupRetryAfter else { return }
        toggleInFlight = true
        startupRetryAfter = Date.now.addingTimeInterval(30)
        Task {
            let result = await HelperClient.setDisableSleep(false)
            if !result.ok { NSLog("Longbrew: startup sleep restoration will retry: \(result.output)") }
            // Only a confirmed read of normal sleep clears the pending restoration.
            await refreshState()
            toggleInFlight = false
        }
    }

    private func postLidBanner() {
        let wasAutomatic = autoOffJustFired
        autoOffJustFired = false
        let body: String
        if isEnabled {
            body = "Mac won’t sleep with lid closed."
        } else if wasAutomatic {
            body = "Longbrew’s timer switched it off. Mac sleeps normally again."
        } else {
            body = "Mac sleeps normally."
        }
        Notify.post("lid-closed", isEnabled ? "Lid-closed (ON)" : "Lid-closed (OFF)", body)
    }

    /// Banners are suppressed while we're the active app — which we are right after
    /// showing Settings or any alert — unless we ask for them explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(.banner)
    }

    // MARK: - Actions

    /// Click = Espresso, the light one: no helper, no approval, dies with the app.
    /// Option-click = lid-closed mode, the heavy one — a root-level system setting
    /// that outlives a quit, so it earns a deliberate modifier. Right (or control)
    /// click = the menu; control-click is the trackpad's right-click, so both land here.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent   // read once: two reads could disagree
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.option) {
            toggle()
        } else {
            toggleEspresso()
        }
    }

    @objc private func openSettings() {
        settings.show()
        refreshHelperStatus()
    }

    // MARK: - Auto-off

    /// Lid-closed mode is a system setting that survives a restart, so the failure
    /// mode is a laptop cooking itself in a bag overnight. This is the backstop.
    /// No Timer: the existing 5s poll already runs, and a deadline survives the
    /// clock changes and sleep/wake cycles a scheduled timer doesn't.
    private func armAutoOff() {
        let duration = lidDuration ?? SessionDuration(rawValue: Settings.autoOffMinutes) ?? .untilTurnedOff
        autoOffDeadline = isEnabled ? duration.deadline() : nil
    }

    private func fireAutoOffIfDue() {
        guard isEnabled, let deadline = autoOffDeadline, Date.now >= deadline else { return }
        // Preserve the deadline while unavailable or busy. Once attempted, back
        // off for 30 seconds; refreshState clears it only after confirming sleep
        // is restored, so a temporary helper failure cannot disarm the safety net.
        guard HelperClient.isEnabled, !toggleInFlight else { return }  // retry next tick
        autoOffDeadline = Date.now.addingTimeInterval(30) // bounded retry until confirmed off
        toggleInFlight = true
        Task {
            let result = await HelperClient.setDisableSleep(false)
            // Deliberately no *alert* on failure: this fires unattended, often with
            // the lid shut, so a modal nobody sees would just block the next attempt.
            if !result.ok { NSLog("Longbrew: auto-off failed: \(result.output)") }
            autoOffJustFired = result.ok   // read and cleared by the banner
            await refreshState()
            toggleInFlight = false
        }
    }

    /// Attach the menu just long enough to click it open. `performClick` runs the
    /// menu's own tracking loop and returns once it closes, so detaching afterwards
    /// is safe — and necessary, or the next left click would open the menu instead
    /// of toggling.
    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggle() {
        guard !toggleInFlight else { return }
        guard HelperClient.isEnabled else {
            presentHelperProblem(detail: "")
            return
        }
        let target = !isEnabled
        let selected: SessionDuration? = target
            ? (SessionDuration(rawValue: Settings.autoOffMinutes) ?? .untilTurnedOff) : nil
        startupRestorePending = false // only an accepted choice supersedes startup recovery
        toggleInFlight = true
        Task {
            let result = await HelperClient.setDisableSleep(target)
            if result.ok { lidDuration = selected }
            await refreshState()
            toggleInFlight = false
            if !result.ok { presentHelperProblem(detail: result.output) }
        }
    }

    @objc private func toggleEspresso() {
        let turningOn = !Espresso.isOn
        let selected = Settings.espressoDuration
        let ok = Espresso.set(turningOn)
        espressoDeadline = ok && turningOn ? selected.deadline() : nil
        // Always redraw, even on failure: a failed release still clears the assertion
        // ID, so bailing out early would leave a tinted icon over an inactive state.
        updateIcon()   // tooltip carries the state; the menu is rebuilt on next open
        guard ok else {
            presentError(title: "Couldn’t pour the Espresso",
                         body: "macOS refused the power assertion. Try again, or restart Longbrew.")
            return
        }
        // Not polled like lid-closed mode — this assertion is ours alone, so the
        // toggle is the only place it can change.
        Notify.post("espresso",
                    Espresso.isOn ? "Espresso" : "Decaf",
                    Espresso.isOn
                        ? "Screen stays awake. Lid has to stay open."
                        : "Mac sleeps when idle again.")
    }

    @objc private func selectEspressoDuration(_ item: NSMenuItem) {
        guard let duration = SessionDuration(rawValue: item.tag) else { return }
        Settings.espressoDuration = duration
        if Espresso.isOn { espressoDeadline = duration.deadline() }
    }

    @objc private func selectLidDuration(_ item: NSMenuItem) {
        guard !toggleInFlight, let duration = SessionDuration(rawValue: item.tag) else { return }
        Settings.autoOffMinutes = duration.rawValue
        lidDuration = duration
        armAutoOff()
        settings.refresh()
    }

    private func durationMenu(title: String, selected: SessionDuration,
                              action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(selected.title)", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for duration in SessionDuration.allCases {
            let choice = NSMenuItem(title: duration.title, action: action, keyEquivalent: "")
            choice.target = self
            choice.tag = duration.rawValue
            choice.state = duration == selected ? .on : .off
            choice.isEnabled = enabled
            choice.toolTip = "Applies to the next session, or restarts an active session’s duration from now."
            choices.addItem(choice)
        }
        item.submenu = choices
        return item
    }

    @objc private func toggleLoginItem() {
        // Launch at Login can't work from a mounted DMG or a translocated copy —
        // macOS randomizes the path, so there's nothing stable to register.
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") || path.contains("AppTranslocation") {
            presentMoveToApplications(reason: "start automatically at login")
            return
        }
        // macOS may accept the registration but park it behind a user approval —
        // clicking again just errors, so send them where the switch actually is.
        if SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Approve Longbrew in Login Items"
            alert.informativeText = """
            macOS needs your OK before Longbrew can start automatically.

            Turn on “Longbrew” under Login Items in System Settings.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Longbrew: login-item change failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nIf Longbrew isn’t in your Applications folder, move it there and try again."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Longbrew \(Self.displayVersion)"
        alert.informativeText = """
        Keeps your Mac awake while the lid is closed — no external display or \
        charger required.

        Click the mug for Espresso: your Mac stops idling to sleep while Longbrew \
        is running. The lid has to stay open, and it ends when you quit.

        Option-click the mug for lid-closed mode: your Mac stays awake with the lid \
        shut. Right-click for this menu.

        An empty mug means your Mac sleeps normally. A steaming mug is Espresso. A \
        charge bolt in the mug means the lid can close.

        Heads up: while lid-closed mode is on, your Mac won’t sleep at all — not on \
        idle, and not from the Apple menu. That uses more battery and the machine can get warm in \
        a bag, so switch it off when you’re done.

        This is a laptop feature — a desktop Mac has no lid to close.

        By Brandon Walter · github.com/EchoParkBaby
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/EchoParkBaby") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil) // policy lives in applicationShouldTerminate
    }

    // MARK: - Termination guard

    /// `pmset disablesleep` is a SYSTEM setting that outlives this app AND survives
    /// reboot. Quitting while it's on would leave the Mac permanently awake with no
    /// indicator and no obvious way back — so make the user choose. Implemented here
    /// (not in the menu action) so Cmd-Q, logout and shutdown all get the same guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if relocating { return .terminateNow } // the installed copy now owns recovery
        guard !toggleInFlight else { return .terminateCancel }
        toggleInFlight = true
        Task {
            let shouldQuit = await confirmTermination()
            toggleInFlight = false
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    private func confirmTermination() async -> Bool {
        // Re-read live: the cached value can be up to 5s stale, and "unknown" must
        // not be treated as "off" — when in doubt, ask.
        let live = await readDisableSleep()
        guard live ?? true else { return true }  // definitely off → just quit

        if lidDuration == .untilQuit {
            let result = await HelperClient.setDisableSleep(false)
            let confirmed = await readDisableSleep()
            await refreshState()
            if result.ok && confirmed == false { return true }
            presentError(title: "Couldn’t end the lid-closed session",
                         body: "Longbrew stayed open because normal sleep could not be confirmed. Check the helper in Settings and try again.")
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Restore normal sleep before quitting?"
        alert.informativeText = """
        Your Mac is currently set never to sleep. That’s a system setting — it stays \
        in effect after Longbrew quits (and after a restart), and there will be no \
        menu-bar icon to turn it off.
        """
        alert.addButton(withTitle: "Restore Normal Sleep")   // default
        alert.addButton(withTitle: "Keep Mac Awake")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Restoring goes over XPC, which must not block the main thread — a hung
            // helper would otherwise make the app unquittable and stall logout.
            let result = await HelperClient.setDisableSleep(false)
            if !result.ok {
                // Don't vanish leaving the Mac awake — that's the exact hazard.
                let fail = NSAlert()
                fail.messageText = "Couldn’t restore normal sleep"
                fail.informativeText = """
                Longbrew stayed open so your Mac doesn’t get stuck awake.

                \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                """
                fail.addButton(withTitle: "OK")
                fail.runModal()
            }
            await refreshState()
            let confirmed = await readDisableSleep()
            return result.ok && confirmed == false
        case .alertThirdButtonReturn:
            return false
        default:
            return true // deliberately leaving it awake
        }
    }

    // MARK: - Helper management

    @objc private func manageHelper() {
        guard !toggleInFlight, !settings.helperBusy else { return }
        switch HelperClient.health {
        case .approvalNeeded:
            SMAppService.openSystemSettingsLoginItems()
        case .notInstalled:
            installHelper()
        case .failed, .updateNeeded:
            guard HelperClient.isInStableLocation else {
                presentMoveToApplications(reason: "repair the privileged helper")
                return
            }
            settings.helperBusy = true
            toggleInFlight = true
            settings.refresh()
            Task {
                defer { settings.helperBusy = false; toggleInFlight = false; settings.refresh(); diagnostics.refresh() }
                do {
                    try await HelperClient.reinstall()
                    await HelperClient.checkHealth(force: true)
                } catch {
                    Diagnostics.recordError("Helper repair failed: " + error.localizedDescription)
                }
            }
        case .unchecked, .ready:
            settings.helperBusy = true
            settings.refresh()
            Task {
                await HelperClient.checkHealth(force: true)
                settings.helperBusy = false
                settings.refresh()
                diagnostics.refresh()
            }
        case .checking: break
        }
    }

    private func installHelper() {
        if HelperClient.status == .requiresApproval {
            settings.show()
            return
        }
        // A daemon's BundleProgram resolves inside this bundle. Registering from a
        // DMG or a folder that can move leaves a root job pointing at a path that
        // may vanish or be replaced.
        guard HelperClient.isInStableLocation else {
            presentMoveToApplications(reason: "change your Mac’s sleep settings")
            return
        }
        do {
            try HelperClient.register()
        } catch {
            presentHelperProblem(detail: error.localizedDescription)
            return
        }
        settings.refresh()
        refreshHelperStatus()
    }

    private func presentHelperInstalled() {
        let alert = NSAlert()
        alert.messageText = "Helper is installed"
        alert.informativeText = "Longbrew’s privileged helper is registered and ready."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Remove Helper")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removeHelper()
    }

    /// Removing the helper throws away the ONLY way to restore sleep, so normal
    /// sleep has to be restored (and confirmed) first — otherwise the Mac is
    /// stranded awake with no mechanism left to fix it.
    private func removeHelper() {
        guard !toggleInFlight else { return }
        toggleInFlight = true
        Task {
            settings.helperBusy = true
            settings.refresh()
            defer { toggleInFlight = false; settings.helperBusy = false; settings.refresh() }
            if await readDisableSleep() ?? true {
                let warn = NSAlert()
                warn.messageText = "Restore normal sleep first?"
                warn.informativeText = """
                Your Mac is currently set never to sleep. Removing the helper takes \
                away the only way Longbrew can undo that.
                """
                warn.addButton(withTitle: "Restore Sleep, Then Remove")
                warn.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard warn.runModal() == .alertFirstButtonReturn else { return }

                let restore = await HelperClient.setDisableSleep(false)
                let live = await readDisableSleep()
                let confirmed = restore.ok && live == false
                guard confirmed else {
                    presentError(title: "Couldn’t restore normal sleep",
                                 body: """
                                 The helper was left installed so your Mac doesn’t get \
                                 stuck awake.

                                 \(restore.output.trimmingCharacters(in: .whitespacesAndNewlines))
                                 """)
                    return
                }
            }
            do {
                try await HelperClient.unregister()
            } catch {
                // Never silently swallow this — the user thinks it's gone.
                presentError(title: "Couldn’t remove the helper",
                             body: error.localizedDescription)
            }
            await refreshState()
        }
    }

    // MARK: - Alerts

    private func presentMoveToApplications(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Move Longbrew to Applications?"
        alert.informativeText = """
        Longbrew needs to be in Applications to \(reason).

        Longbrew will copy and verify the app, open the installed copy, and finish \
        setting up its helper. macOS may ask you to approve the helper. The current \
        copy stays open if installation fails.
        """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !toggleInFlight else { return }
        toggleInFlight = true
        Task {
            do {
                try await AppInstaller.installAndOpen()
                relocating = true
                NSApp.terminate(nil)
            } catch {
                toggleInFlight = false
                Diagnostics.recordError("Move to Applications failed: " + error.localizedDescription)
                startMonitoring() // a failed launch-time move leaves a usable app
                let failure = NSAlert()
                failure.messageText = "Couldn’t move Longbrew"
                failure.informativeText = error.localizedDescription
                    + "\n\nYou can also drag Longbrew into Applications using Finder, then open it there."
                failure.addButton(withTitle: "Show in Finder")
                failure.addButton(withTitle: "OK")
                if failure.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
        }
    }

    private func presentError(title: String, body: String) {
        Diagnostics.recordError(title + ": " + body)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Keep recovery in one persistent panel instead of chaining modal alerts.
    private func presentHelperProblem(detail: String) {
        if !detail.isEmpty { Diagnostics.recordError("Helper: " + detail) }
        settings.show()
        refreshHelperStatus()
    }

    // MARK: - UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // One mug, three fills — empty, brewing, brewing on a charge. Lid-closed
        // mode outranks Espresso in the art because it's the stronger state: it
        // already covers everything Espresso does, and then some.
        let asset: String
        var label: String
        if isEnabled {
            asset = "mug-charge-template-36"
            label = "Longbrew: staying awake, lid can close"
        } else if Espresso.isOn {
            asset = "mug-steam-template-36"
            label = "Longbrew: Espresso on, lid must stay open"
        } else {
            asset = "mug-empty-template-36"
            label = "Longbrew: Mac sleeps normally"
        }
        if isEnabled && Espresso.isOn { label += ", Espresso also on" }
        // Colour marks the strong state only. Steam and a bolt are the same shade of
        // template black at 18pt; orange is what makes "lid can close" read from
        // across the room. Never the only cue — the label and menu say it too.
        let onDarkBar = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint: IconTint = (isEnabled && Settings.tintWhenLidClosed)
            ? (onDarkBar ? .darkBar : .lightBar)
            : .template
        button.image = Self.menuBarImage(named: asset, label: label, tint: tint)
            ?? NSImage(systemSymbolName: isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer",
                       accessibilityDescription: label)
        // Never let a missing asset leave a blank, zero-width, unclickable item —
        // a title guarantees the menulet stays visible and reachable.
        button.title = (button.image == nil) ? (isEnabled ? "AWAKE" : "Clam") : ""
        button.imagePosition = (button.image == nil) ? .noImage : .imageOnly
        // An image-only status item is invisible to VoiceOver without this.
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp("Click to turn Espresso on or off. Option-click for lid-closed mode. Right-click for the menu.")
        // Option-click and right-click are mouse-only gestures, and statusItem.menu
        // is nil except while the menu is open — so without these, everything but
        // Espresso is unreachable with VoiceOver.
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show Menu") { [weak self] in
                MainActor.assumeIsolated { self?.showMenu() }
                return true
            },
            NSAccessibilityCustomAction(name: isEnabled ? "Turn Off Lid-Closed Mode"
                                                        : "Turn On Lid-Closed Mode") { [weak self] in
                MainActor.assumeIsolated { self?.toggle() }
                return true
            },
        ])
        var tip = isEnabled
            ? "Staying awake — this Mac won’t sleep, even with the lid closed"
            : "Normal — this Mac sleeps when idle or when the lid is closed"
        if Espresso.isOn { tip += "\nEspresso is on (lid must stay open)" }
        tip += "\nClick for Espresso · option-click for lid-closed mode · right-click for the menu"
        button.toolTip = tip
    }

    /// Lid-closed tint. The menu bar is dark in Dark Mode and light in Light
    /// Mode, and one light orange can't read on both — so go pale on a dark bar and
    /// a shade deeper on a light one, where a pale orange washes out.
    private enum IconTint: String {
        case template, darkBar, lightBar

        var color: NSColor? {
            switch self {
            case .template: nil
            case .darkBar:  NSColor(srgbRed: 1.00, green: 0.76, blue: 0.45, alpha: 1)
            case .lightBar: NSColor(srgbRed: 0.95, green: 0.58, blue: 0.18, alpha: 1)
            }
        }
    }

    /// There are only a handful of possible icons, and updateIcon() runs on every 5s poll —
    /// without this it re-read the PNG from disk and re-composited it 12×/minute.
    private static var iconCache: [String: NSImage] = [:]

    private static func menuBarImage(named name: String, label: String, tint: IconTint) -> NSImage? {
        let key = "\(name)|\(tint.rawValue)"
        if let cached = iconCache[key] {
            cached.accessibilityDescription = label   // varies independently of the art
            return cached
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let base = NSImage(contentsOf: url) else {
            NSLog("Longbrew: missing menu-bar asset \(name).png — using fallback")
            return nil
        }
        base.size = NSSize(width: 18, height: 18)

        let image: NSImage
        if let color = tint.color {
            // A template image is recoloured by the system, so a tinted one can't be
            // one. sourceAtop paints only where the glyph is, keeping the alpha shape.
            let tinted = NSImage(size: base.size)
            tinted.lockFocus()
            let rect = NSRect(origin: .zero, size: base.size)
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            tinted.unlockFocus()
            image = tinted
        } else {
            base.isTemplate = true       // macOS recolours it for light/dark menu bars
            image = base
        }
        image.accessibilityDescription = label
        iconCache[key] = image
        return image
    }

    /// Built fresh each time it's opened, so it never shows stale state.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Be honest: `disablesleep 1` stops ALL sleep, not just the lid-closed kind.
        var headerTitle: String
        if isEnabled            { headerTitle = "Never sleeps — lid can stay closed" }
        else if Espresso.isOn   { headerTitle = "Staying awake — but only with the lid open" }
        else                    { headerTitle = "Sleeps normally" }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if isEnabled || Espresso.isOn {
            let warn = NSMenuItem(title: "Uses more battery — turn off when done",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let espressoItem = NSMenuItem(title: "Espresso (\(Espresso.isOn ? "On" : "Off"))",
                                      action: #selector(toggleEspresso), keyEquivalent: "e")
        espressoItem.target = self
        espressoItem.state = Espresso.isOn ? .on : .off
        espressoItem.toolTip = "Same as clicking the mug. Stops idle sleep while Longbrew runs; ends when you quit, and the lid still has to stay open."
        menu.addItem(espressoItem)
        menu.addItem(durationMenu(title: "Espresso duration", selected: Settings.espressoDuration,
                                  action: #selector(selectEspressoDuration)))

        let toggleItem = NSMenuItem(title: "Keep Awake With Lid Closed (\(isEnabled ? "On" : "Off"))",
                                    action: #selector(toggle), keyEquivalent: "k")
        toggleItem.target = self
        toggleItem.state = isEnabled ? .on : .off
        toggleItem.toolTip = "Same as option-clicking the mug. Needs the privileged helper."
        menu.addItem(toggleItem)
        menu.addItem(durationMenu(title: "Lid-closed duration",
                                  selected: SessionDuration(rawValue: Settings.autoOffMinutes) ?? .untilTurnedOff,
                                  action: #selector(selectLidDuration), enabled: !toggleInFlight))

        menu.addItem(.separator())

        // Version, author, GitHub, Launch at Login and the helper all live in
        // Settings now — the menu is for the two things you actually click.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics…", action: #selector(openDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let aboutItem = NSMenuItem(title: "About Longbrew",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Longbrew",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }
}
