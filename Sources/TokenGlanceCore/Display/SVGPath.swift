import Foundation

/// Reads the path data of the bundled service marks (Resources/Marks) so they can be drawn exactly
/// as supplied, without an image decoder. Only what those files use is supported: absolute
/// M/L/H/V/C/Z. Anything else returns nil and the caller falls back to a letter badge.
public enum SVGPath {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public enum Segment: Equatable, Sendable {
        case move(Point)
        case line(Point)
        case curve(Point, Point, Point)
        case close
    }

    public static func parse(_ data: String) -> [Segment]? {
        var scanner = Tokens(Array(data.utf8))
        var segments: [Segment] = []
        var current = Point(x: 0, y: 0)
        var command: UInt8?
        while true {
            scanner.skipSeparators()
            guard !scanner.atEnd else { break }
            if let letter = scanner.letter() {
                command = letter
                if letter == UInt8(ascii: "Z") {
                    segments.append(.close)
                    command = nil
                    continue
                }
            } else if command == nil {
                return nil // numbers without a command
            }
            guard let active = command else { return nil }
            switch active {
            case UInt8(ascii: "M"), UInt8(ascii: "L"):
                guard let point = scanner.point() else { return nil }
                segments.append(active == UInt8(ascii: "M") ? .move(point) : .line(point))
                current = point
                if active == UInt8(ascii: "M") { command = UInt8(ascii: "L") } // extra pairs are line-tos
            case UInt8(ascii: "H"):
                guard let x = scanner.number() else { return nil }
                current.x = x
                segments.append(.line(current))
            case UInt8(ascii: "V"):
                guard let y = scanner.number() else { return nil }
                current.y = y
                segments.append(.line(current))
            case UInt8(ascii: "C"):
                guard let c1 = scanner.point(), let c2 = scanner.point(), let end = scanner.point() else { return nil }
                segments.append(.curve(c1, c2, end))
                current = end
            default:
                return nil
            }
        }
        guard case .move = segments.first else { return nil }
        return segments
    }

    /// Byte-level tokenizer for SVG path numbers: "37.1-52.1", ".5.25" and "1e1" are all valid.
    private struct Tokens {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipSeparators() {
            while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: ","), 9, 10, 13].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func letter() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (65...90).contains(byte) || (97...122).contains(byte)
            // "e" is part of a number only right after digits, which number() consumes itself.
            guard isLetter else { return nil }
            index += 1
            return byte
        }

        mutating func point() -> Point? {
            guard let x = number(), let y = number() else { return nil }
            return Point(x: x, y: y)
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = 0
            var sawDot = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) {
                    digits += 1
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                } else {
                    break
                }
                index += 1
            }
            guard digits > 0 else { index = start; return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "-") || bytes[lookahead] == UInt8(ascii: "+") { lookahead += 1 }
                if lookahead < bytes.count, (48...57).contains(bytes[lookahead]) {
                    index = lookahead
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                }
            }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
}

/// A single-path SVG mark: its view box and path. Files with several paths, transforms or an
/// even-odd fill rule are rejected rather than drawn differently from the original.
public struct SVGMark: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
    }

    public let viewBox: Rect
    public let path: [SVGPath.Segment]

    public static func parse(_ svg: String) -> SVGMark? {
        let tags = svg.components(separatedBy: "<path").count - 1
        guard tags == 1, !svg.contains("transform"), !svg.contains("evenodd"),
              let box = attribute("viewBox", in: svg)?
                  .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap({ Double($0) }),
              box.count == 4, box[2] > 0, box[3] > 0,
              let data = attribute("d", in: svg), let path = SVGPath.parse(data)
        else { return nil }
        return SVGMark(viewBox: Rect(x: box[0], y: box[1], width: box[2], height: box[3]), path: path)
    }

    private static func attribute(_ name: String, in svg: String) -> String? {
        guard let range = svg.range(of: " \(name)=\"") ?? svg.range(of: "\n\(name)=\"") else { return nil }
        let rest = svg[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
