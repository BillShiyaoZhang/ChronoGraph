import Foundation
import Testing
@testable import ChronoGraph

struct DateRangeSafetyTests {
    private let now = Date(timeIntervalSince1970: 1_793_232_000)

    @Test func rollingLimitIncludesTodayAndRejectsOversizedOrOverflowingInput() throws {
        let maximum = SharedCalendarRange.maximumDayCount
        let interval = try SharedCalendarRange.rolling(pastDays: 100, futureDays: maximum - 101,
            timeZoneIdentifier: "UTC").dateInterval(now: now)
        #expect(interval.duration == Double(maximum) * 86_400)
        for range in [SharedCalendarRange.rolling(pastDays: 100, futureDays: maximum - 100),
                      .rolling(pastDays: Int.max, futureDays: 0), .rolling(pastDays: 0, futureDays: Int.max)] {
            #expect(throws: SharedCalendarModelError.rangeTooLarge) { try range.dateInterval(now: now) }
        }
        #expect(throws: SharedCalendarModelError.invalidRange) {
            try SharedCalendarRange.rolling(pastDays: Int.min).dateInterval(now: now)
        }
    }

    @Test func fixedLimitUsesCalendarDaysAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = calendar.startOfDay(for: now)
        let end = try #require(calendar.date(byAdding: .day, value: SharedCalendarRange.maximumDayCount, to: start))
        let range = SharedCalendarRange.fixed(start: start, endExclusive: end, timeZoneIdentifier: calendar.timeZone.identifier)
        let original = try range.dateInterval()
        #expect(original.start == start && original.end == end)
        #expect(throws: SharedCalendarModelError.rangeTooLarge) {
            try SharedCalendarRange.fixed(start: start, endExclusive: end.addingTimeInterval(1),
                timeZoneIdentifier: calendar.timeZone.identifier).dateInterval()
        }
        // Validation rejects rather than shortening the configured dates.
        #expect(range == .fixed(start: start, endExclusive: end, timeZoneIdentifier: calendar.timeZone.identifier))
    }

    @Test func nonFiniteDatesCannotReachCalendarArithmetic() {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(throws: SharedCalendarModelError.invalidRange) {
                try SharedCalendarRange.fixed(start: now, endExclusive: Date(timeIntervalSince1970: value)).dateInterval()
            }
            #expect(throws: SharedCalendarModelError.invalidRange) {
                try SharedCalendarRange.rolling().dateInterval(now: Date(timeIntervalSince1970: value))
            }
        }
    }

    @MainActor @Test func rejectedPersonalRangePreservesExistingViewingSelection() {
        let manager = CalendarManager(loadsCalendars: false)
        manager.updateDateRange(.last7Days)
        manager.updateDateRange(.custom(start: now, endExclusive: now.addingTimeInterval(-1)))
        #expect(manager.selectedDateRange == .last7Days)
        manager.updateDateRange(.custom(start: now, endExclusive: now.addingTimeInterval(100_000 * 86_400)))
        #expect(manager.selectedDateRange == .last7Days)
    }

    @Test func queryIdentityDeduplicatesOverlappingWindowsButKeepsCalendarsAndOccurrencesSeparate() {
        let end = now.addingTimeInterval(3600)
        let first = CalendarEventQueryIdentity(calendarID: "work", eventID: "event", start: now, end: end)
        let repeated = CalendarEventQueryIdentity(calendarID: "work", eventID: "event", start: now, end: end)
        let otherCalendar = CalendarEventQueryIdentity(calendarID: "personal", eventID: "event", start: now, end: end)
        let nextOccurrence = CalendarEventQueryIdentity(calendarID: "work", eventID: "event",
            start: now.addingTimeInterval(86_400), end: end.addingTimeInterval(86_400))
        #expect(Set([first, repeated, otherCalendar, nextOccurrence]).count == 3)
    }
}
