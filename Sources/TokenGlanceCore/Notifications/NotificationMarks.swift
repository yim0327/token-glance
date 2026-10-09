import Foundation

/// Identifies one sent alert: tool, window kind, level and the window (reset time rounded to 10
/// minutes, which absorbs small jitter in reported reset times). Nothing else is stored.
public struct NotificationMark: Hashable, Sendable {
    public var tool: Tool
    public var window: LimitWindow.Kind
    public var level: LimitNotification.Kind
    public var windowID: Int

    public init(tool: Tool, window: LimitWindow.Kind, level: LimitNotification.Kind, resetsAt: Date) {
        self.tool = tool
        self.window = window
        self.level = level
        windowID = Int((resetsAt.timeIntervalSince1970 / 600).rounded())
    }

    var encoded: String { "\(tool.rawValue).\(window.rawValue).\(level.rawValue).\(windowID)" }
}

public protocol NotificationMarkStore {
    func contains(_ mark: NotificationMark) -> Bool
    mutating func insert(_ mark: NotificationMark)
}

public struct InMemoryNotificationMarks: NotificationMarkStore, Sendable {
    private var marks: Set<String> = []
    public init() {}
    public func contains(_ mark: NotificationMark) -> Bool { marks.contains(mark.encoded) }
    public mutating func insert(_ mark: NotificationMark) { marks.insert(mark.encoded) }
}

/// Persists marks as short identifier strings so restarts do not repeat alerts.
public struct UserDefaultsNotificationMarks: NotificationMarkStore {
    public static let key = "notificationMarks"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var stored: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    public func contains(_ mark: NotificationMark) -> Bool { stored.contains(mark.encoded) }

    public mutating func insert(_ mark: NotificationMark) {
        var all = stored
        guard !all.contains(mark.encoded) else { return }
        all.append(mark.encoded)
        defaults.set(all, forKey: Self.key)
    }

    /// Drops marks for windows that reset before `cutoff`.
    public mutating func prune(before cutoff: Date) {
        let kept = stored.filter { entry in
            guard let id = entry.split(separator: ".").last.flatMap({ Int($0) }) else { return false }
            return TimeInterval(id) * 600 >= cutoff.timeIntervalSince1970
        }
        defaults.set(kept, forKey: Self.key)
    }
}
