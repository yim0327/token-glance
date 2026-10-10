import Foundation
import Testing
@testable import TokenGlanceCore
@testable import TokenGlanceText

struct ServiceMarksTests {
    @Test func bundledMarksLoadAsSinglePaths() throws {
        for tool in Tool.allCases {
            let mark = try #require(ServiceMarks.mark(for: tool), "\(tool) mark")
            #expect(mark.path.count > 10)
            // Every point lies inside the view box, so the drawn shape is the whole mark.
            for segment in mark.path {
                let points: [SVGPath.Point] = switch segment {
                case .move(let p), .line(let p): [p]
                case .curve(let a, let b, let c): [a, b, c]
                case .close: []
                }
                for p in points {
                    #expect(p.x >= mark.viewBox.x && p.x <= mark.viewBox.x + mark.viewBox.width)
                    #expect(p.y >= mark.viewBox.y && p.y <= mark.viewBox.y + mark.viewBox.height)
                }
            }
        }
        #expect(ServiceMarks.mark(for: .claude)?.viewBox == SVGMark.Rect(x: 0, y: 0, width: 94, height: 94))
        #expect(ServiceMarks.mark(for: .codex)?.viewBox == SVGMark.Rect(x: 0, y: 0, width: 716, height: 716))
    }
}
