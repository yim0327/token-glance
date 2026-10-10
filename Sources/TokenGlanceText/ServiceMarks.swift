import Foundation
import TokenGlanceCore

/// The marks that identify each service in the menu bar label, as supplied by their owners
/// (Resources/Marks, unchanged files; sources in docs/trademarks.md). They identify the service
/// only; Token Glance is not affiliated with, endorsed or approved by Anthropic or OpenAI.
public enum ServiceMarks {
    public static func fileName(for tool: Tool) -> String {
        switch tool {
        case .claude: "claude-spark"
        case .codex: "openai-blossom"
        }
    }

    /// nil when the file is missing or not a single plain path; the label then draws a letter badge.
    public static func mark(for tool: Tool) -> SVGMark? { cache[tool] ?? nil }

    private static let cache: [Tool: SVGMark?] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, load($0)) })

    private static func load(_ tool: Tool) -> SVGMark? {
        let bundle = Localizer.resourceBundle
        guard let url = bundle?.url(forResource: fileName(for: tool), withExtension: "svg")
                ?? bundle?.url(forResource: fileName(for: tool), withExtension: "svg", subdirectory: "Marks"),
              let svg = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return SVGMark.parse(svg)
    }
}
