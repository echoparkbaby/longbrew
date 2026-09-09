#!/usr/bin/env python3
"""Compile production method bodies with fake power/helper state; never register a service."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/longbrew/AppController.swift').read_text()
def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)

fixture = (root / 'Sources/longbrew/SessionDuration.swift').read_text() + '''
import Foundation
import AppKit
@MainActor enum Diagnostics { static func recordPowerRead(_ state: Bool?) {} }
@MainActor enum Caffeinated {
    static var isOn = false
    static var refuse = false
    @discardableResult static func set(_ on: Bool) -> Bool {
        if refuse { return false }
        isOn = on
        return true
    }
}
@MainActor enum Settings {
    static var autoOffMinutes = 0
    static var caffeinateWithLidClosed = false
    static var caffeinatedDuration = SessionDuration.untilQuit
}
@MainActor enum HelperClient {
    static var isEnabled = true
    static var calls = 0
    static var succeed = false
    static var live: Bool? = true
    static func setDisableSleep(_ on: Bool) async -> (ok: Bool, output: String) {
        calls += 1
        if succeed { live = on }
        return (succeed, "injected failure")
    }
}
@MainActor func readDisableSleep() async -> Bool? { HelperClient.live }
@MainActor final class FakeSettings {
    var refreshes = 0
    func refresh() { refreshes += 1 }
}
@MainActor final class Probe {
    var isEnabled = true
    var toggleInFlight = false
    var autoOffDeadline: Date? = .distantPast
    var lidDuration: SessionDuration?
    var caffeinatedDeadline: Date?
    var caffeinatedByLidClosed = false
    let diagnostics = FakeSettings()
    func refreshHelperStatus() {}
    func toggleCaffeinated() { Caffeinated.isOn = false }
    var errors = 0
    func presentError(title: String, body: String) { errors += 1 }
    var autoOffJustFired = false
    var startupRestorePending = false
    var startupRetryAfter = Date.distantPast
    let settings = FakeSettings()
    func postLidBanner() {}
    func updateIcon() {}
'''
fixture += '\n'.join(method(name) for name in ['armAutoOff', 'fireAutoOffIfDue', 'refreshState', 'restoreSleepAtStartupIfNeeded', 'confirmTermination',
                                   'followLidClosedWithCaffeinated'])
fixture += '''
}
@main struct SafetyTests {
    @MainActor static func settle(_ p: Probe) async {
        while p.toggleInFlight { await Task.yield() }
    }
    @MainActor static func main() async {
        let p = Probe()
        p.fireAutoOffIfDue()
        await settle(p)
        precondition(p.autoOffDeadline != nil && p.isEnabled)
        for _ in 0..<100 { await p.refreshState() }
        precondition(HelperClient.calls == 1, "Retry must back off")
        p.autoOffDeadline = .distantPast
        HelperClient.succeed = true
        p.fireAutoOffIfDue()
        await settle(p)
        precondition(HelperClient.calls == 2 && !p.isEnabled && p.autoOffDeadline == nil)
        precondition(p.settings.refreshes > 0)

        HelperClient.live = true
        HelperClient.succeed = false
        HelperClient.calls = 0
        let startup = Probe()
        startup.autoOffDeadline = nil
        startup.startupRestorePending = true
        startup.toggleInFlight = true // startup repair owns the helper
        await startup.refreshState()
        precondition(HelperClient.calls == 0)
        startup.toggleInFlight = false
        await startup.refreshState()
        await settle(startup)
        precondition(startup.startupRestorePending && HelperClient.calls == 1)
        startup.startupRetryAfter = .distantPast
        HelperClient.isEnabled = false // waiting for approval
        await startup.refreshState()
        precondition(startup.startupRestorePending && HelperClient.calls == 1)
        HelperClient.isEnabled = true
        HelperClient.succeed = true
        await startup.refreshState()
        await settle(startup)
        precondition(!startup.startupRestorePending && !startup.isEnabled)
        precondition(HelperClient.calls == 2 && startup.autoOffDeadline == nil)
        let end = Probe()
        end.lidDuration = .untilQuit
        end.autoOffDeadline = nil
        HelperClient.live = true
        HelperClient.succeed = false
        let refused = await end.confirmTermination()
        precondition(!refused && end.errors == 1)
        HelperClient.succeed = true
        let allowed = await end.confirmTermination()
        precondition(allowed && !end.isEnabled)
        let caffeinated = Probe()
        caffeinated.caffeinatedDeadline = .distantPast
        Caffeinated.isOn = true
        HelperClient.live = false
        await caffeinated.refreshState()
        precondition(!Caffeinated.isOn, "Expired Caffeinated must stop")
        let now = Date(timeIntervalSince1970: 100)
        precondition(SessionDuration.thirtyMinutes.deadline(from: now) == now.addingTimeInterval(1800))
        precondition(SessionDuration.oneHour.deadline(from: now) == now.addingTimeInterval(3600))
        precondition(SessionDuration.untilQuit.deadline(from: now) == nil)
        precondition(SessionDuration.untilTurnedOff.deadline(from: now) == nil)
        // Caffeinate-with-lid-closed: off by default, so lid-closed alone stays plain.
        Caffeinated.isOn = false
        Settings.caffeinateWithLidClosed = false
        let plain = Probe()
        plain.isEnabled = true
        plain.followLidClosedWithCaffeinated()
        precondition(!Caffeinated.isOn, "Pref off must not caffeinate")

        // On: follows lid-closed both ways, and takes the duration with it.
        Settings.caffeinateWithLidClosed = true
        Settings.caffeinatedDuration = .thirtyMinutes
        let paired = Probe()
        paired.isEnabled = true
        paired.followLidClosedWithCaffeinated()
        precondition(Caffeinated.isOn && paired.caffeinatedByLidClosed)
        precondition(paired.caffeinatedDeadline != nil, "Paired Caffeinated must inherit the duration")
        paired.isEnabled = false
        paired.followLidClosedWithCaffeinated()
        precondition(!Caffeinated.isOn && !paired.caffeinatedByLidClosed && paired.caffeinatedDeadline == nil)

        // A Caffeinated the user turned on themselves survives lid-closed going off.
        Caffeinated.isOn = true
        let owned = Probe()
        owned.isEnabled = false
        owned.caffeinatedByLidClosed = false
        owned.followLidClosedWithCaffeinated()
        precondition(Caffeinated.isOn, "Must not undo a Caffeinated the user owns")

        // IOKit refusing the assertion must not leave the flag claiming otherwise.
        Caffeinated.isOn = false
        Caffeinated.refuse = true
        let refusedCaffeine = Probe()
        refusedCaffeine.isEnabled = true
        refusedCaffeine.followLidClosedWithCaffeinated()
        precondition(!refusedCaffeine.caffeinatedByLidClosed, "Failed assertion must not set the flag")
        Caffeinated.refuse = false
        Settings.caffeinateWithLidClosed = false

        print("PASS: duration deadlines and until-quit success/failure; auto-off retries; startup repair; settings refresh; caffeinate-with-lid-closed pairing")
    }
}
'''
power = (root / 'Sources/longbrew/SleepState.swift').read_text().split('/// `--self-test`')[0]
power += '''
@main struct PowerTests {
    @MainActor static func main() async {
        let start = Date.now
        let hung = await Task.detached {
            runPowerCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1)
        }.value
        precondition(hung == nil && Date.now.timeIntervalSince(start) < 3)
        precondition(runPowerCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["SleepDisabled 1"]) == "SleepDisabled 1\\n")
        precondition(runPowerCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(10)); ticks += 1 }
        }
        let state = await readDisableSleep(using: {
            Thread.sleep(forTimeInterval: 0.2)
            return "SleepDisabled 1"
        })
        precondition(state == true && ticks == 5, "Power read must not block the main actor")
        await heartbeat.value
        print("PASS: stalled power command killed on timeout; failed reads stay unknown; UI actor remains responsive")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='longbrew-safety-') as directory:
    tmp = Path(directory)
    for name, text in [('Safety', fixture), ('Power', power)]:
        file = tmp / (name + '.swift')
        file.write_text(text)
        binary = tmp / name
        subprocess.run(['swiftc', '-module-cache-path', str(tmp / 'cache'), '-swift-version', '6', '-parse-as-library', str(file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)
