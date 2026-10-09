import Foundation

public enum PercentMode: String, Sendable, CaseIterable {
    /// "62%" meaning 62% of the window is still available (default).
    case remaining
    /// "38%" meaning 38% of the window has been used.
    case used
}

/// How urgently a value should be presented.
public enum Severity: Sendable, Equatable {
    case normal
    /// 30% or less remaining.
    case warning
    /// 10% or less remaining.
    case critical
    /// No value to show.
    case unavailable
}

/// Whole-number percentages shown to the user. `used + left == 100` always holds.
public struct PercentReading: Equatable, Sendable {
    public var used: Int
    public var left: Int
}

/// Numeric presentation rules for the menu bar and popover (rounding, thresholds, durations).
/// User-facing text is produced by TokenGlanceText.
public enum DisplayFormat {
    public static let warningThreshold = 30
    public static let criticalThreshold = 10

    /// `used` is rounded to the nearest whole percent (half away from zero) and clamped to 0...100.
    public static func reading(_ status: LimitStatus) -> PercentReading {
        let used = Int(min(max(status.usedPercent, 0), 100).rounded())
        return PercentReading(used: used, left: 100 - used)
    }

    public static func percentText(_ status: LimitStatus?, mode: PercentMode) -> String {
        guard let status else { return "--" }
        let reading = reading(status)
        return "\(mode == .remaining ? reading.left : reading.used)%"
    }

    public static func severity(_ status: LimitStatus?) -> Severity {
        guard let status else { return .unavailable }
        let left = reading(status).left
        if left <= criticalThreshold { return .critical }
        if left <= warningThreshold { return .warning }
        return .normal
    }

    /// Whole days/hours/minutes/seconds until `target` (zero once reached). Text is built by the app.
    public static func durationParts(until target: Date, now: Date) -> DurationParts {
        let seconds = max(Int(target.timeIntervalSince(now).rounded(.down)), 0)
        return DurationParts(days: seconds / 86_400, hours: seconds % 86_400 / 3600, minutes: seconds % 3600 / 60, seconds: seconds % 60)
    }
}

public struct DurationParts: Equatable, Sendable {
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int

    public var isZero: Bool { days == 0 && hours == 0 && minutes == 0 && seconds == 0 }
}
