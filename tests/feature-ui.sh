#!/bin/bash
# Render real panels against fake helper state. No registration or power changes.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
for source in SettingsWindow DiagnosticsWindow; do
    sed -e 's/private var window/var window/' \
        -e '/NSApp.activate(ignoringOtherApps: true)/d' \
        -e '/window?.makeKeyAndOrderFront(nil)/d' \
        "Sources/longbrew/$source.swift" > "$TEST_DIR/$source.swift"
done
cat > "$TEST_DIR/Preview.swift" <<'SWIFT'
import AppKit
import ServiceManagement

@MainActor enum AppController { static let displayVersion = "1.0.0" }
@MainActor enum HelperClient {
    static var health: HelperHealth = .failed
    static var status: SMAppService.Status = .enabled
    static let isInStableLocation = true
    static let registrationDescription = "Enabled"
}
@MainActor enum Caffeinated { static let isOn = false }

@main struct Preview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        Settings.registerDefaults()
        for i in 0..<25 { Diagnostics.recordError("Test error \(i) at " + NSHomeDirectory()) }
        precondition(Diagnostics.recentErrors.count == 20)
        Diagnostics.recordPowerRead(true)
        let last = Diagnostics.lastPowerCheck
        Diagnostics.recordPowerRead(nil)
        precondition(Diagnostics.lastPowerCheck == last && Diagnostics.sleepDisabled == true && Diagnostics.powerReadFailed)
        let report = Diagnostics.report()
        precondition(report.contains("Connection failed") && report.contains("Latest power read: Failed"))
        precondition(!report.contains(NSHomeDirectory()))
        let settings = SettingsWindowController()
        settings.show()
        let view = settings.window!.contentView!
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let controls = buttons(view)
        precondition(controls.contains { $0.title == "Repair Helper" })
        HelperClient.status = .requiresApproval
        HelperClient.health = .approvalNeeded
        settings.refresh()
        precondition(controls.contains { $0.title == "Open System Settings" })
        HelperClient.status = .enabled
        HelperClient.health = .ready
        settings.refresh()
        precondition(controls.contains { $0.title == "Check Connection" })
        settings.helperBusy = true
        settings.refresh()
        precondition(controls.contains { $0.title == "Working…" && !$0.isEnabled })
        settings.helperBusy = false
        HelperClient.health = .failed
        settings.refresh()
        let diagnosticWindow = DiagnosticsWindowController()
        diagnosticWindow.show()
        let diagnosticView = diagnosticWindow.window!.contentView!
        precondition(buttons(diagnosticView).contains { $0.title == "Copy diagnostics" })
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, panel) in [("settings", view), ("diagnostics", diagnosticView)] {
            panel.window?.orderFront(nil)
            panel.window?.display()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
            panel.layoutSubtreeIfNeeded()
            guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { fatalError("No bitmap") }
            panel.cacheDisplay(in: panel.bounds, to: rep)
            let image = NSImage(size: panel.bounds.size)
            image.lockFocus()
            NSColor.white.setFill()
            panel.bounds.fill()
            rep.draw(in: panel.bounds)
            image.unlockFocus()
            let composite = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try composite.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            panel.window?.orderOut(nil)
        }
        print("PASS: helper actions and busy state; diagnostic history bounds, last-good state and privacy; both panels rendered")
    }
}
SWIFT
swiftc -module-cache-path "$TEST_DIR/cache" -swift-version 6 -parse-as-library \
    Sources/longbrew/SessionDuration.swift Sources/longbrew/Settings.swift Sources/longbrew/HelperHealth.swift Sources/longbrew/Diagnostics.swift \
    "$TEST_DIR/SettingsWindow.swift" "$TEST_DIR/DiagnosticsWindow.swift" "$TEST_DIR/Preview.swift" -o "$TEST_DIR/preview"
"$TEST_DIR/preview" /tmp/longbrew-feature-previews
