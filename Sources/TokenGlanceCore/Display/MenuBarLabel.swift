import Foundation

/// What the menu bar shows: one line per tool (one or two lines). The tooltip text is built by
/// TokenGlanceText from the same states.
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

    /// Lines show the session (5h) window. Every enabled tool gets a line; one without a session
    /// value shows "--".
    public static func make(states: [ToolState], mode: PercentMode) -> MenuBarLabel {
        let lines = states.filter(\.isEnabled).map {
            Line(tool: $0.tool, text: DisplayFormat.percentText($0.session, mode: mode), severity: DisplayFormat.severity($0.session))
        }
        return MenuBarLabel(lines: lines)
    }
}
