import Foundation
import Testing
@testable import ChronoGraph

struct CloudDatePresentationTests {
    @Test func declaredZoneDeterminesDisplayedWallTime() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-29T02:00:00Z"))
        let locale = Locale(identifier: "en_GB")
        #expect(CloudDatePresentation.time(instant, timezone: "Asia/Shanghai", locale: locale) == "10:00")
        #expect(CloudDatePresentation.time(instant, timezone: "America/New_York", locale: locale) == "22:00")
        #expect(CloudDatePresentation.dateAndTime(instant, timezone: "America/New_York", locale: locale).contains("28 Oct 2026"))
        #expect(CloudDatePresentation.dateAndTime(instant, timezone: "Asia/Shanghai", locale: locale).contains("29 Oct 2026"))
    }
    @Test func sharedCandidateUsesSameZoneAsItsVisibleLabelAcrossDST() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z"))
        let end = start.addingTimeInterval(3600)
        let text = CloudDatePresentation.share(start: start, end: end, timezone: "America/New_York", locale: Locale(identifier: "en_GB"))
        #expect(text.contains("01:00"))
        #expect(text.contains("02:00"))
        #expect(text.contains("America/New_York"))
        #expect(!text.contains("06:00"))
    }
    @Test func invalidZoneUsesAnExplicitGMTLabel() {
        #expect(CloudDatePresentation.zoneIdentifier("not/a/timezone") == "GMT")
    }
}
