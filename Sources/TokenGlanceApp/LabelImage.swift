import AppKit
import TokenGlanceCore

/// Draws the one- or two-line menu bar label (see docs/adr/0001-menubar-rendering.md).
///
/// The image is not a template: colors are dynamic system colors resolved when the drawing handler
/// runs, which happens with the status button's appearance, so dark/light menu bars just work.
enum LabelImage {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    static let singleLineFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let badgeSize: CGFloat = 8.5
    static let lineHeight: CGFloat = 10.5
    static let gap: CGFloat = 2.5

    static func make(_ label: MenuBarLabel, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        let lines = label.lines
        let twoLines = lines.count > 1
        let font = twoLines ? font : singleLineFont
        let badge = twoLines ? badgeSize : 11
        let textWidth = lines.map { NSAttributedString(string: $0.text, attributes: [.font: font]).size().width }.max() ?? 0
        let size = NSSize(width: ceil(badge + gap + textWidth) + 1, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let rowHeight = twoLines ? lineHeight : height
            let top = (height - rowHeight * CGFloat(lines.count)) / 2
            for (index, line) in lines.enumerated() {
                let rowY = height - top - rowHeight * CGFloat(index + 1)
                let text = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color(line.severity)])
                let textSize = text.size()
                let textY = rowY + (rowHeight - textSize.height) / 2
                drawBadge(letter(line.tool), in: NSRect(x: 0, y: rowY + (rowHeight - badge) / 2, width: badge, height: badge))
                text.draw(at: NSPoint(x: badge + gap, y: textY))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(_ severity: Severity) -> NSColor {
        switch severity {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        case .unavailable: .secondaryLabelColor
        }
    }

    static func letter(_ tool: Tool) -> String {
        switch tool {
        case .claude: "C"
        case .codex: "X"
        }
    }

    /// A filled circle with the letter knocked out (neutral glyph, no vendor logos).
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
