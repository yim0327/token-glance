import Foundation

enum JSONLines {
    /// Splits newline-delimited data into non-empty lines (CRLF tolerated).
    static func lines(in data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            return trimmed.isEmpty ? nil : Data(trimmed)
        }
    }
}

/// Parses the ISO 8601 timestamps used in both tools' logs (with or without fractional seconds).
struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
