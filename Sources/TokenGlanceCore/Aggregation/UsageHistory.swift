import Foundation

/// One calendar day of token usage. `usage == nil` means no local logs covered that day;
/// `.zero` means logs existed and recorded no usage.
public struct DailyUsage: Equatable, Sendable {
    public var day: Date
    public var usage: TokenUsage?

    public init(day: Date, usage: TokenUsage?) {
        self.day = day
        self.usage = usage
    }
}

/// Per-day totals for the history chart, computed from the in-memory usage records (no re-parse,
/// no stored history).
public enum UsageHistory {
    public static let dayCount = 14
    /// How long records are kept in memory. Must cover the chart range plus one day for time zones.
    public static let retention: TimeInterval = 15 * 24 * 60 * 60

    /// The last `dayCount` days ending with the day of `now`, in `calendar`'s time zone.
    /// Days before `coverageStart` (the oldest log's creation) are reported as having no logs.
    public static func daily(records: [UsageRecord], coverageStart: Date?, now: Date, calendar: Calendar) -> [DailyUsage] {
        let today = calendar.startOfDay(for: now)
        let days = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = days.first else { return [] }
        var totals: [Date: TokenUsage] = [:]
        for record in records where record.timestamp >= first && record.timestamp < now.addingTimeInterval(86_400) {
            totals[calendar.startOfDay(for: record.timestamp), default: .zero] += record.usage
        }
        let coverageDay = coverageStart.map { calendar.startOfDay(for: $0) }
        return days.map { day in
            if let usage = totals[day] { return DailyUsage(day: day, usage: usage) }
            guard let coverageDay, day >= coverageDay else { return DailyUsage(day: day, usage: nil) }
            return DailyUsage(day: day, usage: .zero)
        }
    }
}
