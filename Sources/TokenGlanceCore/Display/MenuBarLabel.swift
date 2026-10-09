import Foundation

/// What the menu bar shows: one line per tool (one or two lines) plus a tooltip.
public struct MenuBarLabel: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var tool: Tool
        public var text: String
        public var severity: Severity

        public init(tool: Tool, text: String, severity: Severity) {
            self.tool = tool
            self.text = text
            self.severity = severity
        }
    }

    public var lines: [Line]
    public var tooltip: String

    /// Lines show the session (5h) window. Enabled tools with data get a line; if none has data,
    /// every enabled tool shows "--" and the tooltip explains why.
    public static func make(states: [ToolState], mode: PercentMode, now: Date) -> MenuBarLabel {
        let enabled = states.filter(\.isEnabled)
        let withData = enabled.filter { $0.session != nil }
        let shown = withData.isEmpty ? enabled : withData
        let lines = shown.map {
            Line(tool: $0.tool, text: DisplayFormat.percentText($0.session, mode: mode), severity: DisplayFormat.severity($0.session))
        }
        let tooltip = enabled.map { tooltipLine($0, mode: mode, now: now) }.joined(separator: "\n")
        return MenuBarLabel(lines: lines, tooltip: tooltip)
    }

    /// "Claude session 62% left, resets in 2h 10m · weekly 76% left"
    static func tooltipLine(_ state: ToolState, mode: PercentMode, now: Date) -> String {
        guard let session = state.session else {
            return "\(state.displayName): \((state.unavailableReason ?? .noData).message)"
        }
        var text = "\(state.displayName) session \(phrase(session, mode))"
        if let resetsAt = session.resetsAt {
            text += ", resets in \(DisplayFormat.countdown(to: resetsAt, now: now))"
        } else if session.isReset {
            text += " (window reset)"
        }
        if let weekly = state.weekly {
            text += " · weekly \(phrase(weekly, mode))"
        }
        return text
    }

    private static func phrase(_ status: LimitStatus, _ mode: PercentMode) -> String {
        let reading = DisplayFormat.reading(status)
        return mode == .remaining ? "\(reading.left)% left" : "\(reading.used)% used"
    }
}
