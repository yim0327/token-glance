import Testing
@testable import TokenGlanceCore

struct AxisTicksTests {
    @Test func niceStepsCoverTheMaximum() {
        #expect(AxisTicks.make(maxValue: 1_234_567) == [0, 500_000, 1_000_000, 1_500_000])
        #expect(AxisTicks.make(maxValue: 100) == [0, 50, 100])
        #expect(AxisTicks.make(maxValue: 7) == [0, 2, 4, 6, 8])
        #expect(AxisTicks.make(maxValue: 3) == [0, 1, 2, 3])
        #expect(AxisTicks.make(maxValue: 1) == [0, 1])
        #expect(AxisTicks.make(maxValue: 80_000_000) == [0, 20_000_000, 40_000_000, 60_000_000, 80_000_000])
    }

    @Test func nothingToShow() {
        #expect(AxisTicks.make(maxValue: 0) == [0])
        #expect(AxisTicks.make(maxValue: -5) == [0])
    }

    @Test func lastTickIsNeverBelowTheMaximum() {
        for value in [1, 9, 11, 99, 101, 999, 1_001, 34_560, 987_654_321] {
            let ticks = AxisTicks.make(maxValue: value)
            #expect(ticks.first == 0)
            #expect(ticks.last! >= value)
            #expect(ticks.count >= 2 && ticks.count <= 6, "\(value): \(ticks)")
        }
    }
}
