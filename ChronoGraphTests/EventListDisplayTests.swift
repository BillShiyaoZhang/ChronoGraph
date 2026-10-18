import Foundation
import Testing
@testable import ChronoGraph

struct EventListDisplayTests {
    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private func preview(visibility: SharedVisibility, defaultMode: PrivacyMode = .opaque) -> SharedEventPreview {
        let source = SourceEventSnapshot(
            calendarID: "private-calendar", calendarItemIdentifier: "private-id",
            title: "Private source title", startDate: date("2026-10-18T02:00:00Z"),
            endDate: date("2026-10-18T03:00:00Z"), location: "Private office", notes: "Private notes"
        )
        return SharedEventPreview(
            id: "shared-event", identityID: UUID(), occurrenceKey: nil, isRecurring: false,
            title: source.title, startDate: source.startDate, endDate: source.endDate, isAllDay: false,
            visibility: visibility, override: visibility, seriesOverride: nil,
            published: PublishedEvent(source: source, visibility: visibility),
            source: source, defaultPrivacyMode: defaultMode
        )
    }

    @Test func explicitFullUsesPublishedFieldsEvenWhenProfileDefaultIsOpaque() throws {
        var event = preview(visibility: .full)
        event = SharedEventPreview(
            id: event.id, identityID: event.identityID, occurrenceKey: nil, isRecurring: false,
            title: event.title, startDate: event.startDate, endDate: event.endDate, isAllDay: false,
            visibility: .full, override: .full, seriesOverride: nil,
            published: event.published.map {
                var published = $0
                published.title = "Published title"
                published.location = "Published location"
                published.startDate = published.startDate.addingTimeInterval(3600)
                return published
            },
            source: event.source, defaultPrivacyMode: .opaque
        )
        let item = try #require(EventListDisplayItem(sharedEvent: event))
        #expect(item.title == "Published title")
        #expect(item.location == "Published location")
        #expect(item.startDate == event.published?.startDate)
        #expect(item.startDate != event.source?.startDate)
        #expect(item.showsAvailability)
    }

    @Test func effectiveVisibilityControlsEachSharedRowWithoutReadingOriginalDetails() throws {
        let opaque = try #require(EventListDisplayItem(sharedEvent: preview(visibility: .opaque, defaultMode: .full)))
        let partial = try #require(EventListDisplayItem(sharedEvent: preview(visibility: .partial)))
        #expect(opaque.title == CalendarEvent.Availability.busy.localizedName)
        #expect(opaque.location == nil)
        #expect(!opaque.showsAvailability)
        #expect(partial.title == "Private source title")
        #expect(partial.location == nil)
        #expect(partial.showsAvailability)
        #expect(EventListDisplayItem(sharedEvent: preview(visibility: .excluded)) == nil)
    }

    @Test func missingProjectionNeverFallsBackToOriginalSource() {
        let event = preview(visibility: .full)
        let unpublished = SharedEventPreview(
            id: event.id, identityID: event.identityID, occurrenceKey: nil, isRecurring: false,
            title: event.title, startDate: event.startDate, endDate: event.endDate, isAllDay: false,
            visibility: .full, override: .full, seriesOverride: nil, published: nil, source: event.source
        )
        #expect(EventListDisplayItem(sharedEvent: unpublished) == nil)
    }

    @Test func groupingUsesProfileTimeZoneAndIncludesEmptyDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let interval = DateInterval(start: date("2026-03-07T05:00:00Z"), end: date("2026-03-10T04:00:00Z"))
        // UTC March 8 is still March 7 in the profile's time zone.
        let event = CalendarEvent(id: "late-night", title: "Late night", startDate: date("2026-03-08T02:00:00Z"),
                                  endDate: date("2026-03-08T03:00:00Z"), calendar: "Work")
        let days = EventListDisplayDay.grouped(items: [EventListDisplayItem(event: event, privacyMode: .full)],
                                               interval: interval, calendar: calendar)
        #expect(days.map(\.date) == [date("2026-03-07T05:00:00Z"), date("2026-03-08T05:00:00Z"), date("2026-03-09T04:00:00Z")])
        #expect(days.map { $0.items.count } == [1, 0, 0])
    }

    @Test func personalProjectionKeepsExistingPrivacyAndCalendarColor() {
        let event = CalendarEvent(id: "personal", title: "Personal title", startDate: date("2026-10-18T02:00:00Z"),
                                  endDate: date("2026-10-18T03:00:00Z"), location: "Office", calendar: "Work")
        let full = EventListDisplayItem(event: event, privacyMode: .full)
        let partial = EventListDisplayItem(event: event, privacyMode: .partial)
        let opaque = EventListDisplayItem(event: event, privacyMode: .opaque)
        #expect(full.title == event.title && full.location == event.location)
        #expect(full.calendarColor == event.calendarColor)
        #expect(partial.title == event.title && partial.location == nil && partial.showsAvailability)
        #expect(opaque.title == event.availability.localizedName && opaque.location == nil && !opaque.showsAvailability)
    }
}
