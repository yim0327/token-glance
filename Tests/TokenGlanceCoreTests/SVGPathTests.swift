import Foundation
import Testing
@testable import TokenGlanceCore

struct SVGPathTests {
    @Test func parsesAbsoluteCommandsWithCompactNumbers() throws {
        let path = try #require(SVGPath.parse("M18.7 62.4L37.1-52.1H36.2V50.5C1 2 3 4 5 6ZM.5.25L1e1 2"))
        #expect(path == [
            .move(.init(x: 18.7, y: 62.4)),
            .line(.init(x: 37.1, y: -52.1)),
            .line(.init(x: 36.2, y: -52.1)),
            .line(.init(x: 36.2, y: 50.5)),
            .curve(.init(x: 1, y: 2), .init(x: 3, y: 4), .init(x: 5, y: 6)),
            .close,
            .move(.init(x: 0.5, y: 0.25)),
            .line(.init(x: 10, y: 2)),
        ])
    }

    @Test func repeatedCoordinatesContinueTheCommand() throws {
        // After "M", extra pairs are line-tos; "C" and "L" repeat with their own argument count.
        let path = try #require(SVGPath.parse("M0 0 1 1L2 2 3 3C1 1 2 2 3 3 4 4 5 5 6 6"))
        #expect(path == [
            .move(.init(x: 0, y: 0)), .line(.init(x: 1, y: 1)),
            .line(.init(x: 2, y: 2)), .line(.init(x: 3, y: 3)),
            .curve(.init(x: 1, y: 1), .init(x: 2, y: 2), .init(x: 3, y: 3)),
            .curve(.init(x: 4, y: 4), .init(x: 5, y: 5), .init(x: 6, y: 6)),
        ])
    }

    @Test func unsupportedOrBrokenDataIsRejected() {
        #expect(SVGPath.parse("m0 0l1 1") == nil)        // relative commands are not supported
        #expect(SVGPath.parse("M0 0A1 1 0 0 1 2 2") == nil) // arcs are not supported
        #expect(SVGPath.parse("M0 0L1") == nil)           // missing coordinate
        #expect(SVGPath.parse("L1 1") == nil)             // must start with a move
        #expect(SVGPath.parse("") == nil)
    }

    @Test func extractsASingleFilledPathAndItsViewBox() throws {
        let svg = """
        <svg width="94" height="94" viewBox="0 0 94 94" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M1 2L3 4Z" fill="#D97757"/>
        </svg>
        """
        let mark = try #require(SVGMark.parse(svg))
        #expect(mark.viewBox == SVGMark.Rect(x: 0, y: 0, width: 94, height: 94))
        #expect(mark.path == [.move(.init(x: 1, y: 2)), .line(.init(x: 3, y: 4)), .close])
    }

    @Test func marksWithSeveralPathsOrTransformsAreRejected() {
        let two = #"<svg viewBox="0 0 10 10"><path d="M0 0L1 1Z"/><path d="M2 2L3 3Z"/></svg>"#
        let transformed = #"<svg viewBox="0 0 10 10"><g transform="scale(2)"><path d="M0 0L1 1Z"/></g></svg>"#
        let evenOdd = #"<svg viewBox="0 0 10 10"><path fill-rule="evenodd" d="M0 0L1 1Z"/></svg>"#
        let noViewBox = #"<svg><path d="M0 0L1 1Z"/></svg>"#
        #expect(SVGMark.parse(two) == nil)
        #expect(SVGMark.parse(transformed) == nil)
        #expect(SVGMark.parse(evenOdd) == nil)
        #expect(SVGMark.parse(noViewBox) == nil)
    }
}
