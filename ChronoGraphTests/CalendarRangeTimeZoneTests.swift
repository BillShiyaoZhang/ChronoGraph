import Foundation
import Testing
@testable import ChronoGraph

@MainActor
struct CalendarRangeTimeZoneTests {
    @Test func personalRangeAcceptsItsOriginalCalendarDayLimitAcrossTimeZones() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let end = try #require(calendar.date(byAdding: .day, value: SharedCalendarRange.maximumDayCount, to: start))
        let original = SharedCalendarRange.fixed(start: start, endExclusive: end, timeZoneIdentifier: calendar.timeZone.identifier)
        _ = try original.dateInterval()
        // The same absolute interval spans part of an extra day in Shanghai.
        // Revalidating in the device's zone would leave the old event query active.
        #expect(throws: SharedCalendarModelError.rangeTooLarge) {
            try SharedCalendarRange.fixed(start: start, endExclusive: end, timeZoneIdentifier: "Asia/Shanghai").dateInterval()
        }

        let manager = CalendarManager(loadsCalendars: false)
        manager.updateDateRange(.last7Days)
        manager.updateDateRange(.custom(start: start, endExclusive: end), timeZoneIdentifier: original.timeZoneIdentifier)
        #expect(manager.selectedDateRange == .custom(start: start, endExclusive: end))
        #expect(manager.selectedDateRangeTimeZoneIdentifier == "America/New_York")
    }

    @Test func rejectedRangeKeepsBothThePreviousDatesAndTheirTimeZone() {
        let manager = CalendarManager(loadsCalendars: false)
        let start = Date(timeIntervalSince1970: 1_793_232_000)
        let valid = CalendarManager.DateRange.custom(start: start, endExclusive: start.addingTimeInterval(86_400))
        manager.updateDateRange(valid, timeZoneIdentifier: "Asia/Tokyo")
        manager.updateDateRange(valid, timeZoneIdentifier: "not-a-time-zone")
        #expect(manager.selectedDateRange == valid)
        #expect(manager.selectedDateRangeTimeZoneIdentifier == "Asia/Tokyo")
        manager.updateDateRange(.custom(start: start, endExclusive: start.addingTimeInterval(100_000 * 86_400)),
            timeZoneIdentifier: "UTC")
        #expect(manager.selectedDateRange == valid)
        #expect(manager.selectedDateRangeTimeZoneIdentifier == "Asia/Tokyo")
        manager.updateDateRange(.today)
        #expect(manager.selectedDateRangeTimeZoneIdentifier == TimeZone.current.identifier)
    }
}
