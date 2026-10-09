import Foundation

/// A limit window as it should be shown at a given moment.
public struct LimitStatus: Equatable, Sendable {
    public var kind: LimitWindow.Kind
    /// 0 once the window has reset.
    public var usedPercent: Double
    /// `nil` once the window has reset: the next reset time is unknown until the tool reports again.
    public var resetsAt: Date?
    public var isReset: Bool
    public var observedAt: Date

    public init(kind: LimitWindow.Kind, usedPercent: Double, resetsAt: Date?, isReset: Bool, observedAt: Date) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.isReset = isReset
        self.observedAt = observedAt
    }

    public var remainingPercent: Double { 100 - usedPercent }
}

public struct UsageSummary: Equatable, Sendable {
    public var today: TokenUsage
    public var todayByModel: [String: TokenUsage]
    public var week: TokenUsage
    public var weekByModel: [String: TokenUsage]
    public var weekInterval: DateInterval
    public var limits: [LimitStatus]
}

/// Groups usage records into "today" and the current weekly window. Time and calendar are injected.
public struct UsageAggregator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The calendar day containing `now`.
    public func today(now: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 24 * 60 * 60)
    }

    /// The weekly limit window containing `now`: `resetsAt - 7d ..< resetsAt`. If the reported
    /// reset time has passed, the window is rolled forward in 7-day steps. Without a weekly limit,
    /// the trailing 7 days are used.
    public func weekInterval(weekly: LimitWindow?, now: Date) -> DateInterval {
        let length = LimitWindow.Kind.weekly.duration
        guard let weekly else {
            return DateInterval(start: now - length, end: now)
        }
        var end = weekly.resetsAt
        if end <= now {
            let windowsElapsed = (now.timeIntervalSince(end) / length).rounded(.down) + 1
            end += windowsElapsed * length
        }
        return DateInterval(start: end - length, end: end)
    }

    /// Sum of records with `start <= timestamp < end`.
    public func total(_ records: [UsageRecord], in interval: DateInterval) -> TokenUsage {
        records.lazy.filter { Self.contains(interval, $0.timestamp) }.reduce(.zero) { $0 + $1.usage }
    }

    public func byModel(_ records: [UsageRecord], in interval: DateInterval) -> [String: TokenUsage] {
        records.reduce(into: [:]) { result, record in
            guard Self.contains(interval, record.timestamp) else { return }
            result[record.model, default: .zero] += record.usage
        }
    }

    public func limitStatuses(_ limits: [LimitWindow], now: Date) -> [LimitStatus] {
        limits.map { window in
            let reset = window.isReset(at: now)
            return LimitStatus(
                kind: window.kind,
                usedPercent: window.usedPercent(at: now),
                resetsAt: reset ? nil : window.resetsAt,
                isReset: reset,
                observedAt: window.observedAt
            )
        }
    }

    public func summary(of snapshot: UsageSnapshot, now: Date) -> UsageSummary {
        let day = today(now: now)
        let week = weekInterval(weekly: snapshot.limit(.weekly), now: now)
        return UsageSummary(
            today: total(snapshot.records, in: day),
            todayByModel: byModel(snapshot.records, in: day),
            week: total(snapshot.records, in: week),
            weekByModel: byModel(snapshot.records, in: week),
            weekInterval: week,
            limits: limitStatuses(snapshot.limits, now: now)
        )
    }

    private static func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        interval.start <= date && date < interval.end
    }
}
