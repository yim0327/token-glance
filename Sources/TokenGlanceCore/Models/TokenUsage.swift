/// Token counts normalized across tools.
///
/// - `input` excludes cached input (Codex reports cached tokens inside `input_tokens`;
///   providers subtract them).
/// - `reasoning` is a subset of `output` (thinking / reasoning tokens), kept for display only.
public struct TokenUsage: Equatable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public static let zero = TokenUsage()

    /// All tokens processed: input + cache read + cache write + output.
    public var total: Int {
        input + cacheRead + cacheWrite + output
    }

    public var isZero: Bool { self == .zero }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}
