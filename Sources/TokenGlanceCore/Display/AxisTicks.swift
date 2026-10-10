import Foundation

/// Value-axis ticks for the history chart: evenly spaced "nice" values (1, 2 or 5 × 10ⁿ apart)
/// from zero up to at least the largest value.
public enum AxisTicks {
    /// Ticks starting at 0 whose last value is ≥ `maxValue`, about `target` intervals apart.
    /// Returns `[0]` when there is nothing to show.
    public static func make(maxValue: Int, target: Int = 4) -> [Int] {
        guard maxValue > 0, target > 0 else { return [0] }
        let raw = Double(maxValue) / Double(target)
        let magnitude = pow(10, floor(log10(raw)))
        let multiplier = [1.0, 2, 5, 10].first { $0 * magnitude >= raw } ?? 10
        let step = max(1, Int((multiplier * magnitude).rounded()))
        let top = (maxValue + step - 1) / step * step
        return Array(stride(from: 0, through: top, by: step))
    }
}
