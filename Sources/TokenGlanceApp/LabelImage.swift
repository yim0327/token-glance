import AppKit
import TokenGlanceCore
import TokenGlanceText

/// Draws the one- or two-line menu bar label (see docs/adr/0001-menubar-rendering.md).
///
/// The image is not a template: colors are dynamic system colors resolved when the drawing handler
/// runs, which happens with the status button's appearance, so dark/light menu bars just work.
enum LabelImage {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    static let singleLineFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let badgeSize: CGFloat = 10
    static let lineHeight: CGFloat = 10.5
    /// Space between the two lines (2 × 10.5 + 1 = 22 pt, within the 22–24 pt menu bar).
    static let lineSpacing: CGFloat = 1
    static let gap: CGFloat = 2.5

    static func make(_ label: MenuBarLabel, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        let lines = label.lines
        let twoLines = lines.count > 1
        let font = twoLines ? font : singleLineFont
        let badge = twoLines ? badgeSize : 13
        let textWidth = lines.map { width(of: $0, font: font) }.max() ?? 0
        let size = NSSize(width: ceil(badge + gap + textWidth) + 1, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let rowHeight = twoLines ? lineHeight : height
            let spacing = twoLines ? lineSpacing : 0
            let top = (height - rowHeight * CGFloat(lines.count) - spacing * CGFloat(lines.count - 1)) / 2
            for (index, line) in lines.enumerated() {
                let rowY = height - top - rowHeight * CGFloat(index + 1) - spacing * CGFloat(index)
                let text = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color(line.severity)])
                let textSize = text.size()
                let textY = rowY + (rowHeight - textSize.height) / 2
                drawMark(line.tool, in: NSRect(x: 0, y: rowY + (rowHeight - badge) / 2, width: badge, height: badge))
                if line.severity == .unavailable {
                    drawDashes(x: badge + gap, baselineY: textY - font.descender, font: font)
                } else {
                    text.draw(at: NSPoint(x: badge + gap, y: textY))
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(_ severity: Severity) -> NSColor {
        switch severity {
        case .normal, .unavailable: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// A missing value is drawn as two bars, each as wide as a digit, because a thin "--" in the
    /// small label font is barely visible.
    private static func dashMetrics(font: NSFont) -> (digit: CGFloat, spacing: CGFloat, thickness: CGFloat) {
        let digit = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        return (digit, max(1, digit * 0.3), max(1.5, (font.pointSize * 0.17).rounded()))
    }

    private static func width(of line: MenuBarLabel.Line, font: NSFont) -> CGFloat {
        guard line.severity == .unavailable else {
            return NSAttributedString(string: line.text, attributes: [.font: font]).size().width
        }
        let metrics = dashMetrics(font: font)
        return metrics.digit * 2 + metrics.spacing
    }

    private static func drawDashes(x: CGFloat, baselineY: CGFloat, font: NSFont) {
        let metrics = dashMetrics(font: font)
        let midY = baselineY + font.capHeight / 2 - metrics.thickness / 2
        color(.unavailable).setFill()
        // The first bar sits a little to the right; a clear gap still separates the two.
        let offsets = [metrics.spacing / 2, metrics.digit + metrics.spacing]
        for originOffset in offsets {
            let originX = x + originOffset
            let rect = NSRect(x: originX, y: midY, width: metrics.digit - metrics.spacing / 2, height: metrics.thickness)
            NSBezierPath(roundedRect: rect, xRadius: metrics.thickness / 2, yRadius: metrics.thickness / 2).fill()
        }
    }

    static func letter(_ tool: Tool) -> String {
        switch tool {
        case .claude: "C"
        case .codex: "X"
        }
    }

    /// The service's mark (ServiceMarks), filled in one color with `labelColor` so it follows the
    /// menu bar like a template image while the number next to it keeps its warning color. The
    /// path is drawn as supplied, scaled uniformly to fit `rect` by its own bounds (the file's
    /// empty margin is not kept; there is no room for it at this size).
    private static func drawMark(_ tool: Tool, in rect: NSRect) {
        guard let path = markPaths[tool] ?? nil, let context = NSGraphicsContext.current?.cgContext else {
            drawBadge(letter(tool), in: rect)
            return
        }
        let bounds = path.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: -scale) // SVG y grows downwards
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.addPath(path)
        context.setFillColor(NSColor.labelColor.cgColor)
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    private static let markPaths: [Tool: CGPath?] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
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

    /// Fallback when a mark file is missing or unreadable: a filled circle with the letter knocked out.
    private static func drawBadge(_ letter: String, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let glyph = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.76, weight: .heavy),
            .foregroundColor: NSColor.black,
        ])
        let glyphSize = glyph.size()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2))
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
