#!/bin/bash
# Exercise the production XPC callbacks against a guaranteed absent service.
# No root helper is contacted and no power settings or registrations are changed.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
sed 's/com.brandon.clamshelled.helper/com.brandon.longbrew.test.absent.'"$$"'/g' \
    Sources/LongbrewShared/HelperProtocol.swift > "$TEST_DIR/HelperProtocol.swift"
sed '/^import LongbrewShared$/d' Sources/longbrew/HelperClient.swift > "$TEST_DIR/HelperClient.swift"
cat > "$TEST_DIR/CallbackTest.swift" <<'SWIFT'
import Foundation

@main
struct CallbackTest {
    @MainActor static func main() async {
        precondition(!HelperClient.isInStableLocation)
        do {
            try HelperClient.register()
            preconditionFailure("Registration outside Applications must be refused")
        } catch { precondition(error.localizedDescription.contains("Applications")) }
        do {
            try await HelperClient.reinstall()
            preconditionFailure("Reinstallation must be refused before unregistering")
        } catch { precondition(error.localizedDescription.contains("Applications")) }
        print("PASS: install and reinstall reject unstable locations")
        for _ in 0..<3 {
            let generation = await HelperClient.runningGeneration()
            precondition(generation == nil, "Absent helper must return nil")
            let result = await HelperClient.setDisableSleep(false)
            precondition(!result.ok && !result.output.isEmpty, "Absent helper must return an error")
        }
        print("PASS: background XPC errors return safely for launch and lid-closed toggle")
    }
}
SWIFT
swiftc -module-cache-path "$TEST_DIR/ModuleCache" -swift-version 6 -parse-as-library "$TEST_DIR/HelperProtocol.swift" \
    Sources/longbrew/HelperHealth.swift Sources/longbrew/Diagnostics.swift Sources/longbrew/Espresso.swift \
    "$TEST_DIR/HelperClient.swift" "$TEST_DIR/CallbackTest.swift" -o "$TEST_DIR/callback-test"
"$TEST_DIR/callback-test"
