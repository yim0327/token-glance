import Foundation
import Testing
@testable import TokenGlanceCore

struct DisplayFormatTests {
    let now = Fixtures.t0

    func status(_ used: Double, _ kind: LimitWindow.Kind = .session, resetsIn: TimeInterval = 3600) -> LimitStatus {
        LimitStatus(kind: kind, usedPercent: used, resetsAt: now + resetsIn, isReset: false, observedAt: now)
    }

    @Test func percentReadingRoundsUsedAndKeepsSumAt100() {
        #expect(DisplayFormat.reading(status(0)) == PercentReading(used: 0, left: 100))
        #expect(DisplayFormat.reading(status(100)) == PercentReading(used: 100, left: 0))
        #expect(DisplayFormat.reading(status(37.5)) == PercentReading(used: 38, left: 62))
        #expect(DisplayFormat.reading(status(37.4)) == PercentReading(used: 37, left: 63))
        #expect(DisplayFormat.reading(status(0.4)) == PercentReading(used: 0, left: 100))
        #expect(DisplayFormat.reading(status(99.6)) == PercentReading(used: 100, left: 0))
        #expect(DisplayFormat.reading(status(140)) == PercentReading(used: 100, left: 0))
        #expect(DisplayFormat.reading(status(-3)) == PercentReading(used: 0, left: 100))
    }

    @Test func percentTextByModeAndMissingValue() {
        #expect(DisplayFormat.percentText(status(38), mode: .remaining) == "62%")
        #expect(DisplayFormat.percentText(status(38), mode: .used) == "38%")
        #expect(DisplayFormat.percentText(nil, mode: .remaining) == "--")
        #expect(DisplayFormat.percentText(nil, mode: .used) == "--")
    }

    @Test func severityThresholdsUseRemainingPercent() {
        #expect(DisplayFormat.severity(status(69)) == .normal)    // 31 left
        #expect(DisplayFormat.severity(status(70)) == .warning)   // 30 left
        #expect(DisplayFormat.severity(status(89)) == .warning)   // 11 left
        #expect(DisplayFormat.severity(status(90)) == .critical)  // 10 left
        #expect(DisplayFormat.severity(status(100)) == .critical)
        #expect(DisplayFormat.severity(status(69.6)) == .warning) // rounds to 70 used / 30 left
        #expect(DisplayFormat.severity(nil) == .unavailable)
    }

    @Test func durationPartsAreFlooredAndNeverNegative() {
        #expect(DisplayFormat.durationParts(until: now + 2 * 3600 + 10 * 60 + 59, now: now) == DurationParts(days: 0, hours: 2, minutes: 10, seconds: 59))
        #expect(DisplayFormat.durationParts(until: now + 3 * 86_400 + 61, now: now) == DurationParts(days: 3, hours: 0, minutes: 1, seconds: 1))
        #expect(DisplayFormat.durationParts(until: now - 10, now: now).isZero)
        // derived from dates, so the same target read later is consistent
        #expect(DisplayFormat.durationParts(until: now + 3 * 3600, now: now + 3600 + 61) == DurationParts(days: 0, hours: 1, minutes: 58, seconds: 59))
    }
}
