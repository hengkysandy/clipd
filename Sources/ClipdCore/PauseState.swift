import Foundation

public enum PauseDuration: String, CaseIterable, Equatable, Sendable {
    case fifteenMinutes
    case oneHour
    case untilResumed

    public var label: String {
        switch self {
        case .fifteenMinutes: return "For 15 minutes"
        case .oneHour: return "For 1 hour"
        case .untilResumed: return "Until I resume"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .untilResumed: return nil
        }
    }
}

/// Whether capture is currently suspended.
///
/// A timed pause expires on its own. Rejected: a boolean plus a timer that
/// flips it back, because a missed or delayed timer would leave the app
/// silently paused forever, and "Clipd stopped recording" is a failure the user
/// would not connect to a timer. Deriving from a deadline and a clock cannot
/// get stuck.
public struct PauseState: Equatable, Sendable {
    public private(set) var until: Date?
    public private(set) var indefinite: Bool

    public init(until: Date? = nil, indefinite: Bool = false) {
        self.until = until
        self.indefinite = indefinite
    }

    public static let running = PauseState()

    public func isPaused(now: Date) -> Bool {
        if indefinite { return true }
        guard let until else { return false }
        return now < until
    }

    public static func paused(_ duration: PauseDuration, from now: Date) -> PauseState {
        guard let seconds = duration.seconds else {
            return PauseState(until: nil, indefinite: true)
        }
        return PauseState(until: now.addingTimeInterval(seconds), indefinite: false)
    }

    /// What the menu should say. Nil when not paused.
    public func remainingLabel(now: Date) -> String? {
        guard isPaused(now: now) else { return nil }
        if indefinite { return "Paused" }
        guard let until else { return nil }
        let remaining = Int(until.timeIntervalSince(now).rounded(.up))
        if remaining >= 60 {
            return "Paused, \(remaining / 60) min left"
        }
        return "Paused, \(max(remaining, 0))s left"
    }
}
