#!/bin/bash
# All copy/failure tests use temporary folders, never /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
sed '/^import LongbrewShared$/d' Sources/longbrew/AppInstaller.swift > "$TEST_DIR/AppInstaller.swift"
cat > "$TEST_DIR/InstallerTests.swift" <<'SWIFT'
import Foundation

@main struct InstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let target = root.appendingPathComponent("Installed.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("marker"))
        enum Rejected: Error { case signature }
        do {
            try AppInstaller.copyVerifiedBundle(from: source, to: target) { _ in throw Rejected.signature }
            preconditionFailure("Bad signatures must prevent publication")
        } catch Rejected.signature {}
        precondition(!fm.fileExists(atPath: target.path))
        precondition(tryContents(root) == ["Source.app"])
        try AppInstaller.copyVerifiedBundle(from: source, to: target) { staged in
            precondition(staged != source && staged != target)
            precondition(fm.fileExists(atPath: staged.appendingPathComponent("marker").path))
        }
        precondition(fm.fileExists(atPath: source.path))
        precondition(fm.fileExists(atPath: target.appendingPathComponent("marker").path))
        do {
            try AppInstaller.copyVerifiedBundle(from: source, to: target) { _ in
                preconditionFailure("Existing app must be refused before staging")
            }
            preconditionFailure("Existing app must not be overwritten")
        } catch is AppInstaller.InstallError {}
        let race = root.appendingPathComponent("Race.app")
        do {
            try AppInstaller.copyVerifiedBundle(from: source, to: race) { _ in
                try fm.createDirectory(at: race, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: race.appendingPathComponent("other"))
            }
            preconditionFailure("Destination race must not overwrite an app")
        } catch {}
        precondition(fm.fileExists(atPath: race.appendingPathComponent("other").path))
        precondition(!tryContents(root).contains { $0.hasPrefix(".Longbrew-install-") })
        do {
            try AppInstaller.copyVerifiedBundle(from: source, to: root.appendingPathComponent("missing/App.app")) { _ in }
            preconditionFailure("Copy to missing parent must fail")
        } catch {}
        precondition(fm.fileExists(atPath: source.path))
        try AppInstaller.verify(URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: stage, verify, publish; preserve source/existing app; clean up failures; verify real signed app")
    }
    static func tryContents(_ url: URL) -> [String] {
        try! FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
SWIFT
swiftc -module-cache-path "$TEST_DIR/cache" -swift-version 6 -parse-as-library \
    Sources/LongbrewShared/HelperProtocol.swift "$TEST_DIR/AppInstaller.swift" \
    "$TEST_DIR/InstallerTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$PWD/Longbrew.app"
