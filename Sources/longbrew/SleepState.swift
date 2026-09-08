import Foundation

/// Parses `pmset -g` output for the SleepDisabled flag.
/// Returns true/false for an exact `SleepDisabled 0|1` line, or nil when the key
/// is absent or the value isn't recognised. Matching whole tokens matters: the
/// same output also contains an unrelated `sleep 1 (...)` line.
func parseSleepDisabled(_ output: String) -> Bool? {
    for line in output.split(separator: "\n") {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2, tokens[0] == "SleepDisabled" else { continue }
        switch tokens[1] {
        case "1": return true
        case "0": return false
        default:  return nil   // unrecognised value — don't guess
        }
    }
    return nil // key absent — caller decides (macOS omits it when unset)
}

/// Runs pmset and returns its output. nil = couldn't launch or exited non-zero.
func runPmset(_ arguments: [String]) -> String? {
    runPowerCommand(executable: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: arguments)
}

// Internal seam for timeout tests; production callers always use the fixed pmset path.
func runPowerCommand(executable: URL, arguments: [String], timeout: TimeInterval = 5) -> String? {
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    // A file avoids blocking on a full pipe or a child that never closes stdout.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
          let output = try? FileHandle(forWritingTo: url) else { return nil }
    defer {
        try? output.close()
        try? FileManager.default.removeItem(at: url)
    }
    p.standardOutput = output
    p.standardError = output
    let finished = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in finished.signal() }
    do { try p.run() } catch { return nil }
    guard finished.wait(timeout: .now() + timeout) == .success else {
        // SIGKILL also bounds commands that ignore graceful termination.
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        _ = finished.wait(timeout: .now() + 1)
        return nil
    }
    guard p.terminationStatus == 0, let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// Reads the live SleepDisabled value. Unprivileged — no helper needed.
/// nil = couldn't determine (pmset failed / unrecognised output) — NOT "off".
func readDisableSleep(
    using read: @escaping @Sendable () -> String? = { runPmset(["-g"]) }
) async -> Bool? {
    let output = await Task.detached(priority: .utility) { read() }.value
    guard let output else { return nil }
    return parseSleepDisabled(output)
}

/// `--self-test`: runnable checks for the parser and the Espresso assertion.
/// Run with:
///   Longbrew.app/Contents/MacOS/longbrew --self-test
/// Uses `precondition`, not `assert` — assertions are compiled out in release, so
/// an assert-based check would pass vacuously in the shipped binary.
@MainActor
func runSelfTest() -> Never {
    let real = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standbydelayhigh     86400
     sleep                1 (sleep prevented by coreaudiod)
     hibernatemode        3
    """
    precondition(parseSleepDisabled(real) == false, "must not be fooled by the later 'sleep 1' line")
    precondition(parseSleepDisabled(" SleepDisabled\t\t1") == true)
    precondition(parseSleepDisabled(" SleepDisabled 0") == false)
    precondition(parseSleepDisabled("Currently in use:\n sleep 1") == nil, "key absent → unknown")
    precondition(parseSleepDisabled("") == nil, "empty (pmset failed) → unknown, never 'off'")
    precondition(parseSleepDisabled(" SleepDisabled banana") == nil, "unparseable → unknown")
    precondition(parseSleepDisabled("SleepDisabledExtra 1") == nil, "prefix must not match")
    print("✓ parseSleepDisabled: all checks passed")

    // Real round trip against IOKit — catches bad assertion arguments.
    precondition(Espresso.isOn == false, "starts off")
    precondition(Espresso.set(true), "IOKit refused the assertion")
    precondition(Espresso.isOn, "should report on")

    // Ask the system what it thinks we asserted. This is the check that matters:
    // "create succeeded" says nothing about WHICH sleep got prevented, and
    // PreventUserIdleSystemSleep keeps the machine awake while letting the screen
    // go dark — which shipped once and is not what Espresso means.
    // Match on our own pid as well as the name: pmset lists the WHOLE system, and an
    // installed Longbrew.app with Espresso on holds an assertion by exactly
    // this name — without the pid, the test grades another process's work and the
    // release check fails on a perfectly good build.
    let mine = "pid \(ProcessInfo.processInfo.processIdentifier)("
    func ourAssertions() -> [Substring] {
        (runPmset(["-g", "assertions"]) ?? "")
            .split(separator: "\n")
            .filter { $0.contains(mine) && $0.contains(Espresso.assertionName) }
    }

    let ours = ourAssertions()
    precondition(!ours.isEmpty,
                 "system doesn't list our assertion at all:\n\(runPmset(["-g", "assertions"]) ?? "")")
    precondition(ours.contains { $0.contains("PreventUserIdleDisplaySleep") },
                 "assertion does not prevent DISPLAY sleep — the screen will still go dark:\n\(ours.joined(separator: "\n"))")

    precondition(Espresso.set(true), "re-enabling is a no-op, not an error")
    precondition(Espresso.set(false), "release failed")
    precondition(Espresso.isOn == false, "should report off")
    precondition(ourAssertions().isEmpty, "assertion outlived its release")
    print("✓ Espresso: holds a display-sleep assertion, and releases it")

    // The bundle check is the only real logic in Notify, and it can't be caught at
    // runtime: UNUserNotificationCenter raises an ObjC exception when the process
    // has no bundle — which is exactly how this binary runs under `swift build`.
    // If that guard is ever wrong, this line takes the whole self-test down with it.
    Notify.post("self-test", "Longbrew self-test", "Banner plumbing is alive.")
    print("✓ Notify: safe to post from a bundle and from a bare binary")
    exit(0)
}
