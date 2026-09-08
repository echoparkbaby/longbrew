import Foundation

/// Registration alone does not prove the helper is reachable.
enum HelperHealth: Equatable {
    case notInstalled, approvalNeeded, unchecked, checking, ready, failed, updateNeeded

    var title: String {
        switch self {
        case .notInstalled: "Not installed"
        case .approvalNeeded: "Approval needed"
        case .unchecked: "Connection not checked"
        case .checking: "Checking connection…"
        case .ready: "Ready"
        case .failed: "Connection failed"
        case .updateNeeded: "Helper update needed"
        }
    }
    var detail: String {
        switch self {
        case .notInstalled: "Install the helper to use lid-closed mode."
        case .approvalNeeded: "Allow Longbrew in System Settings → General → Login Items & Extensions."
        case .unchecked, .checking: "Checking that the installed helper responds."
        case .ready: "The helper is responding and up to date."
        case .failed: "Repair the helper to reconnect. Diagnostics contains recent errors."
        case .updateNeeded: "This app includes a newer helper. Repair it to install the update."
        }
    }
    var actionTitle: String {
        switch self {
        case .notInstalled: "Install Helper"
        case .approvalNeeded: "Open System Settings"
        case .unchecked, .ready: "Check Connection"
        case .checking: "Checking…"
        case .failed, .updateNeeded: "Repair Helper"
        }
    }
}
