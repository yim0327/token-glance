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

/// Text formatting for the menu bar and popover. Pure functions of their inputs (time is passed in).
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

    /// Coarse countdown: "3d 4h", "2h 10m", "45m", "<1m", or "now" once reached.
    public static func countdown(to target: Date, now: Date) -> String {
        let seconds = Int(target.timeIntervalSince(now).rounded(.down))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Ticking countdown for the popover: "2:05:09" or "3d 0:01:01".
    public static func clockCountdown(to target: Date, now: Date) -> String {
        let seconds = max(Int(target.timeIntervalSince(now).rounded(.down)), 0)
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60, secs = seconds % 60
        let clock = String(format: "%d:%02d:%02d", hours, minutes, secs)
        return days > 0 ? "\(days)d \(clock)" : clock
    }

    /// "just now", "3m ago", "2h ago", "3d ago".
    public static func relativeAge(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// "950", "34.6K", "1.2M", "2.1B".
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch abs(value) {
        case 1e9...: return String(format: "%.1fB", value / 1e9)
        case 1e6...: return String(format: "%.1fM", value / 1e6)
        case 1e3...: return String(format: "%.1fK", value / 1e3)
        default: return "\(count)"
        }
    }
}
