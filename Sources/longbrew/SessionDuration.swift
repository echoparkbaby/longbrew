import Foundation

/// Positive values are minutes; the two indefinite choices have distinct quit behavior.
enum SessionDuration: Int, CaseIterable, Sendable {
    case thirtyMinutes = 30, oneHour = 60, twoHours = 120, fourHours = 240, eightHours = 480
    case untilQuit = -1, untilTurnedOff = 0

    var title: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fourHours: "4 hours"
        case .eightHours: "8 hours"
        case .untilQuit: "Until I quit"
        case .untilTurnedOff: "Until turned off"
        }
    }

    func deadline(from now: Date = .now) -> Date? {
        rawValue > 0 ? now.addingTimeInterval(Double(rawValue) * 60) : nil
    }
}
