import Foundation

/// Minimal in-place edits of a JSON object's text: replace a value, add or remove a top-level member.
///
/// Re-serializing settings.json with a JSON library would reorder keys and reformat the file.
/// This editor changes only the bytes of the edited member, so everything else stays as written.
/// The input must be valid JSON whose top level is an object.
struct JSONTextEditor {
    enum Error: Swift.Error, Equatable {
        case invalidJSON
        case notAnObject
    }

    struct Member: Equatable {
        /// The key including its quotes.
        let key: Range<Int>
        let value: Range<Int>
    }

    private(set) var bytes: [UInt8]

    init(_ text: String) throws {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Error.invalidJSON }
        guard object is [String: Any] else { throw Error.notAnObject }
        bytes = Array(text.utf8)
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    /// The last top-level member named `name` (JSON parsers keep the last duplicate).
    func topLevelMember(_ name: String) -> Member? {
        member(name, inObjectAt: topLevelObject)
    }

    /// The last member named `name` of the object whose text spans `object` (`{` ... `}`).
    func member(_ name: String, inObjectAt object: Range<Int>) -> Member? {
        guard bytes[object.lowerBound] == UInt8(ascii: "{") else { return nil }
        let quoted = Array(Self.encode(string: name).utf8)
        return members(of: object).last { Array(bytes[$0.key]) == quoted }
    }

    mutating func replace(_ range: Range<Int>, with text: String) {
        bytes.replaceSubrange(range, with: Array(text.utf8))
    }

    /// Appends `"name": valueJSON` as the last top-level member, matching the existing indentation.
    mutating func insertTopLevelMember(_ name: String, valueJSON: String) {
        let object = topLevelObject
        let existing = members(of: object)
        let entry = Self.encode(string: name) + ": " + valueJSON
        if let last = existing.last {
            let indent = indentation(before: existing[0].key.lowerBound)
            replace(last.value.upperBound..<last.value.upperBound, with: ",\n" + indent + entry)
        } else {
            replace(object, with: "{\n  " + entry + "\n}")
        }
    }

    /// Removes the top-level member `name` with its separating comma and line.
    mutating func removeTopLevelMember(_ name: String) {
        let object = topLevelObject
        let all = members(of: object)
        guard let index = all.lastIndex(where: { Array(bytes[$0.key]) == Array(Self.encode(string: name).utf8) }) else { return }
        if all.count == 1 {
            replace(object, with: "{}")
        } else if index > 0 {
            replace(all[index - 1].value.upperBound..<all[index].value.upperBound, with: "")
        } else {
            replace(all[0].key.lowerBound..<all[1].key.lowerBound, with: "")
        }
    }

    static func encode(string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: - Scanning (input is known to be valid JSON)

    private var topLevelObject: Range<Int> {
        let start = skipWhitespace(from: 0)
        return start..<scanValue(from: start)
    }

    private func members(of object: Range<Int>) -> [Member] {
        var result: [Member] = []
        var index = skipWhitespace(from: object.lowerBound + 1)
        while index < object.upperBound - 1, bytes[index] == UInt8(ascii: "\"") {
            let keyEnd = scanString(from: index)
            let colon = skipWhitespace(from: keyEnd)
            let valueStart = skipWhitespace(from: colon + 1)
            let valueEnd = scanValue(from: valueStart)
            result.append(Member(key: index..<keyEnd, value: valueStart..<valueEnd))
            index = skipWhitespace(from: valueEnd)
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index = skipWhitespace(from: index + 1)
            }
        }
        return result
    }

    private func indentation(before position: Int) -> String {
        var start = position
        while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") {
            start -= 1
        }
        guard start > 0, bytes[start - 1] == UInt8(ascii: "\n") else { return "" }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private func skipWhitespace(from index: Int) -> Int {
        var i = index
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        return i
    }

    /// `index` is at an opening quote; returns the index after the closing quote.
    private func scanString(from index: Int) -> Int {
        var i = index + 1
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return i + 1
            default: i += 1
            }
        }
        return i
    }

    /// Returns the index just past the value starting at `index`.
    private func scanValue(from index: Int) -> Int {
        switch bytes[index] {
        case UInt8(ascii: "\""):
            return scanString(from: index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = index
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    i = scanString(from: i)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return i
        default:
            var i = index
            while i < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) {
                i += 1
            }
            return i
        }
    }
}
