import Foundation

/// Remaining-percent thresholds for alerts (defaults 30% and 10%).
public struct NotificationThresholds: Equatable, Sendable {
    public enum ValidationError: Equatable, Sendable {
        case outOfRange
        case warningNotAboveCritical
    }

    public var warning: Int
    public var critical: Int

    public init(warning: Int = 30, critical: Int = 10) {
        self.warning = warning
        self.critical = critical
    }

    public var validationError: ValidationError? {
        guard (0...100).contains(warning), (0...100).contains(critical) else { return .outOfRange }
        guard warning > critical else { return .warningNotAboveCritical }
        return nil
    }
}

/// An alert to deliver. Text is produced by the app (localized); this carries values only.
public struct LimitNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case warning, critical
        /// A new window was observed after the previous one had run low.
        case reset
    }

    public var tool: Tool
    public var window: LimitWindow.Kind
    public var kind: Kind
    public var leftPercent: Int
    public var resetsAt: Date
}

/// Decides which limit alerts to send.
///
/// - Only a **new and fresh observation** (a newer `observedAt`, at most `freshness` old) can raise an
///   alert. The first observation of a window after launch, wake or re-enabling only sets the
///   baseline, so nothing that happened while the app was not watching is sent later.
/// - Remaining percent is the rounded value the UI shows (`DisplayFormat.reading`), independent of the
///   used/remaining display mode. A drop that crosses both thresholds sends only the critical alert.
/// - A reset alert needs a newer observation whose `resetsAt` moved forward; the reset time passing
///   alone never counts as recovered.
/// - Sent (tool, window, level, window id) marks are persisted so restarts do not repeat alerts.
public struct NotificationPlanner: Sendable {
    public var thresholds: NotificationThresholds
    /// Observations older than this when processed only update the baseline.
    public static let freshness: TimeInterval = 10 * 60
    /// `resetsAt` moving forward by more than this means a new window (Codex reports small jitter).
    static let newWindowGap: TimeInterval = 30 * 60

    private struct Key: Hashable {
        let tool: Tool
        let window: LimitWindow.Kind
    }

    private var baseline: [Key: LimitWindow] = [:]

    public init(thresholds: NotificationThresholds = NotificationThresholds()) {
        self.thresholds = thresholds
    }

    /// Forget all baselines (after wake, or when notifications are turned on).
    public mutating func rebaseline() {
        baseline.removeAll()
    }

    /// Forget one tool's baselines (tool disabled or its log folder changed).
    public mutating func forget(tool: Tool) {
        baseline = baseline.filter { $0.key.tool != tool }
    }

    /// `windows` is `nil` or empty when the tool has no usable limits (missing, corrupt or stale data).
    public mutating func evaluate<Marks: NotificationMarkStore>(tool: Tool, windows: [LimitWindow]?, now: Date,
                                                                marks: inout Marks) -> [LimitNotification] {
        guard thresholds.validationError == nil, let windows else { return [] }
        var events: [LimitNotification] = []
        for window in windows {
            let key = Key(tool: tool, window: window.kind)
            guard let previous = baseline[key] else {
                baseline[key] = window
                continue
            }
            guard window.observedAt > previous.observedAt else { continue }  // nothing new observed
            baseline[key] = window
            guard now.timeIntervalSince(window.observedAt) <= Self.freshness, !window.isReset(at: now) else { continue }

            let left = Self.left(window)
            if window.resetsAt.timeIntervalSince(previous.resetsAt) > Self.newWindowGap {
                if Self.left(previous) <= thresholds.warning,
                   let event = record(.reset, tool: tool, window: window, left: left, marks: &marks) {
                    events.append(event)
                }
                continue
            }

            let previousLeft = Self.left(previous)
            if previousLeft > thresholds.critical, left <= thresholds.critical {
                // Also mark the warning so a later recovery and drop within this window stays quiet.
                _ = record(.warning, tool: tool, window: window, left: left, marks: &marks)
                if let event = record(.critical, tool: tool, window: window, left: left, marks: &marks) { events.append(event) }
            } else if previousLeft > thresholds.warning, left <= thresholds.warning,
                      let event = record(.warning, tool: tool, window: window, left: left, marks: &marks) {
                events.append(event)
            }
        }
        return events
    }

    /// Records the mark; returns the notification unless it was already sent for this window.
    private func record<Marks: NotificationMarkStore>(_ kind: LimitNotification.Kind, tool: Tool, window: LimitWindow,
                                                      left: Int, marks: inout Marks) -> LimitNotification? {
        let mark = NotificationMark(tool: tool, window: window.kind, level: kind, resetsAt: window.resetsAt)
        guard !marks.contains(mark) else { return nil }
        marks.insert(mark)
        return LimitNotification(tool: tool, window: window.kind, kind: kind, leftPercent: left, resetsAt: window.resetsAt)
    }

    static func left(_ window: LimitWindow) -> Int {
        100 - Int(min(max(window.usedPercent, 0), 100).rounded())
    }
}
