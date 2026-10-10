import AppKit
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// The service marks (ServiceMarks) as paths, shared by the menu bar label and the details panel.
/// Each path is drawn as supplied and only scaled uniformly by its own bounds (see docs/trademarks.md).
enum ServiceMarkPath {
    /// nil when the mark file is missing or unreadable.
    static func path(for tool: Tool) -> CGPath? { paths[tool] ?? nil }

    /// The path scaled uniformly to fit and centered in `rect`, flipped from SVG's downward y axis
    /// when `flipped` is true (AppKit drawing); SwiftUI's y axis already points down.
    static func fitted(_ tool: Tool, in rect: CGRect, flipped: Bool) -> CGPath? {
        guard let path = path(for: tool) else { return nil }
        let bounds = path.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: flipped ? -scale : scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return path.copy(using: &transform)
    }

    private static let paths: [Tool: CGPath?] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
        (tool, ServiceMarks.mark(for: tool).map { cgPath($0.path) })
    })

    private static func cgPath(_ segments: [SVGPath.Segment]) -> CGPath {
        let path = CGMutablePath()
        func point(_ p: SVGPath.Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        for segment in segments {
            switch segment {
            case .move(let p): path.move(to: point(p))
            case .line(let p): path.addLine(to: point(p))
            case .curve(let c1, let c2, let end): path.addCurve(to: point(end), control1: point(c1), control2: point(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The mark next to a tool's name in the details panel, filled with the foreground style.
struct ServiceMarkShape: Shape {
    let tool: Tool

    func path(in rect: CGRect) -> Path {
        ServiceMarkPath.fitted(tool, in: rect, flipped: false).map(Path.init) ?? Path()
    }
}
