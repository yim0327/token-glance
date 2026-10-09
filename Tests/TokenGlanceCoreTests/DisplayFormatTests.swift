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

    @Test func countdownFormatting() {
        #expect(DisplayFormat.countdown(to: now + 2 * 3600 + 10 * 60 + 59, now: now) == "2h 10m")
        #expect(DisplayFormat.countdown(to: now + 45 * 60, now: now) == "45m")
        #expect(DisplayFormat.countdown(to: now + 59, now: now) == "<1m")
        #expect(DisplayFormat.countdown(to: now + 3 * 86_400 + 4 * 3600 + 30 * 60, now: now) == "3d 4h")
        #expect(DisplayFormat.countdown(to: now + 86_400, now: now) == "1d 0h")
        #expect(DisplayFormat.countdown(to: now, now: now) == "now")
        #expect(DisplayFormat.countdown(to: now - 10, now: now) == "now")
    }

    @Test func countdownIsDerivedFromDatesNotTicks() {
        // the same target viewed at different moments gives consistent results
        let target = now + 3 * 3600
        #expect(DisplayFormat.countdown(to: target, now: now + 3600) == "2h 0m")
        #expect(DisplayFormat.countdown(to: target, now: now + 3600 + 61) == "1h 58m")
    }

    @Test func clockCountdownWithSeconds() {
        #expect(DisplayFormat.clockCountdown(to: now + 2 * 3600 + 5 * 60 + 9, now: now) == "2:05:09")
        #expect(DisplayFormat.clockCountdown(to: now + 3 * 86_400 + 61, now: now) == "3d 0:01:01")
        #expect(DisplayFormat.clockCountdown(to: now - 1, now: now) == "0:00:00")
    }

    @Test func relativeAge() {
        #expect(DisplayFormat.relativeAge(of: now - 20, now: now) == "just now")
        #expect(DisplayFormat.relativeAge(of: now - 3 * 60 - 5, now: now) == "3m ago")
        #expect(DisplayFormat.relativeAge(of: now - 2 * 3600, now: now) == "2h ago")
        #expect(DisplayFormat.relativeAge(of: now - 3 * 86_400, now: now) == "3d ago")
        #expect(DisplayFormat.relativeAge(of: now + 30, now: now) == "just now")
    }

    @Test func compactTokenCounts() {
        #expect(DisplayFormat.tokens(0) == "0")
        #expect(DisplayFormat.tokens(950) == "950")
        #expect(DisplayFormat.tokens(1_000) == "1.0K")
        #expect(DisplayFormat.tokens(34_560) == "34.6K")
        #expect(DisplayFormat.tokens(1_234_567) == "1.2M")
        #expect(DisplayFormat.tokens(753_979_845) == "754.0M")
        #expect(DisplayFormat.tokens(2_100_000_000) == "2.1B")
    }
}
