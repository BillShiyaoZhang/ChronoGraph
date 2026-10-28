import Foundation
import XCTest
@preconcurrency import EventKit
@testable import ChronoGraph

#if targetEnvironment(simulator)
/// Opt in only on a fresh, dedicated Simulator. These tests never use an account,
/// upload data, create an EKSource, or query events outside their own local calendar.
@MainActor
final class CloudEventKitIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_EVENTKIT_INTEGRATION"] == "1" else {
            throw XCTSkip("Native Calendar tests require an explicitly opted-in, dedicated Simulator.")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Grant full Calendar access to the Simulator host app before running native Calendar tests.")
        }
    }

    func testNativeReaderPreservesEventsAndExpandsRecurrenceInItsOwnCalendar() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }

        try fixture.addEvent(title: "Simulator private busy", start: fixture.start,
                             availability: .busy, notes: "Synthetic private note", location: "Synthetic place")
        try fixture.addEvent(title: "Simulator free", start: fixture.start.addingTimeInterval(7200), availability: .free)
        try fixture.addEvent(title: "Simulator all-day", start: fixture.start.addingTimeInterval(86_400), isAllDay: true)
        try fixture.addEvent(title: "Simulator recurring", start: fixture.start.addingTimeInterval(2 * 86_400),
                             recurrence: EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                                          end: EKRecurrenceEnd(occurrenceCount: 3)))

        let stored = try fixture.events()
        let reader = CloudCalendarReader()
        let inventory = try await reader.inventory()
        XCTAssertTrue(inventory.contains { $0.id == fixture.calendarID })
        let snapshots = try await reader.events(calendarID: fixture.calendarID, interval: fixture.window)
        XCTAssertEqual(snapshots.count, 6)
        XCTAssertTrue(snapshots.allSatisfy { $0.calendarID == fixture.calendarID })

        let ordinary = try XCTUnwrap(snapshots.first { $0.title == "Simulator private busy" })
        XCTAssertEqual(ordinary.notes, "Synthetic private note")
        XCTAssertEqual(ordinary.location, "Synthetic place")
        XCTAssertEqual(ordinary.startDate, fixture.start)
        let free = try XCTUnwrap(snapshots.first { $0.title == "Simulator free" })
        let storedFree = try XCTUnwrap(stored.first { $0.title == "Simulator free" })
        // A local source may not support availability. The reader must preserve
        // the state actually returned by EventKit rather than inventing Free.
        XCTAssertEqual(free.availability, CalendarEvent.Availability(ekEventAvailability: storedFree.availability))
        if fixture.supportedAvailabilities.contains(.free) { XCTAssertEqual(free.availability, .free) }
        XCTAssertTrue(try XCTUnwrap(snapshots.first { $0.title == "Simulator all-day" }).isAllDay)

        let recurring = snapshots.filter { $0.title == "Simulator recurring" }
        XCTAssertEqual(recurring.count, 3)
        XCTAssertTrue(recurring.allSatisfy(\.isRecurring))
        let occurrenceKeys = try recurring.map { try XCTUnwrap($0.occurrenceKey()) }
        XCTAssertEqual(Set(occurrenceKeys).count, 3)
        let opaque = try CloudSnapshotProjection.project(ordinary, sourceID: UUID(), level: .opaque,
                                                         key: Data(repeating: 9, count: 32))
        XCTAssertNil(opaque.title)
        XCTAssertNil(opaque.notes)
        XCTAssertNil(opaque.location)
    }

    func testNativeReaderSerializesFixedOffsetZonesAndAllDayDates() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let east = try XCTUnwrap(TimeZone(secondsFromGMT: 19_800))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -12_600))
        XCTAssertEqual(east.identifier, "GMT+0530")
        XCTAssertEqual(west.identifier, "GMT-0330")
        try fixture.addEvent(title: "Synthetic east offset", start: fixture.start, timeZone: east)
        try fixture.addEvent(title: "Synthetic west offset", start: fixture.start.addingTimeInterval(7200), timeZone: west)

        var eastCalendar = Calendar(identifier: .gregorian)
        eastCalendar.timeZone = east
        let allDayStart = eastCalendar.startOfDay(for: fixture.start.addingTimeInterval(2 * 86_400))
        try fixture.addEvent(title: "Synthetic offset all-day", start: allDayStart,
                             isAllDay: true, timeZone: east)

        let stored = try fixture.events()
        let reader = CloudCalendarReader()
        let snapshots = try await reader.events(calendarID: fixture.calendarID, interval: fixture.window)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(snapshots.allSatisfy { $0.calendarID == fixture.calendarID })
        for (title, zone, start) in [("Synthetic east offset", east, fixture.start),
                                     ("Synthetic west offset", west, fixture.start.addingTimeInterval(7200))] {
            let native = try XCTUnwrap(stored.first { $0.title == title })
            let snapshot = try XCTUnwrap(snapshots.first { $0.title == title })
            XCTAssertEqual(native.timeZone?.identifier, zone.identifier)
            XCTAssertEqual(snapshot.timeZoneIdentifier, zone.identifier)
            XCTAssertEqual(snapshot.startDate, start)
            XCTAssertEqual(snapshot.endDate, start.addingTimeInterval(3600))
        }

        let sourceID = UUID()
        let projected = try snapshots.map {
            try CloudSnapshotProjection.project($0, sourceID: sourceID, level: .opaque,
                                                key: Data(repeating: 13, count: 32))
        }
        let body = CloudSnapshot(snapshotId: UUID(), expectedGeneration: 0,
                                 windowStart: fixture.window.start, windowEnd: fixture.window.end, events: projected)
        let data = try CloudJSON.encoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireEvents = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(wireEvents.count, 3)
        XCTAssertTrue(wireEvents.allSatisfy { $0["title"] == nil && $0["location"] == nil && $0["notes"] == nil })
        XCTAssertTrue(wireEvents.contains { $0["timezone"] as? String == "GMT+0530" })
        XCTAssertTrue(wireEvents.contains { $0["timezone"] as? String == "GMT-0330" })
        for event in projected {
            let wire = try XCTUnwrap(wireEvents.first { UUID(uuidString: $0["id"] as? String ?? "") == event.id })
            XCTAssertEqual(wire["timezone"] as? String, event.timezone)
            let startWire = try XCTUnwrap(wire["start"] as? String)
            let endWire = try XCTUnwrap(wire["end"] as? String)
            XCTAssertEqual(try CloudJSON.decoder().decode(Date.self, from: JSONEncoder().encode(startWire)), event.start)
            XCTAssertEqual(try CloudJSON.decoder().decode(Date.self, from: JSONEncoder().encode(endWire)), event.end)
        }

        let nativeAllDay = try XCTUnwrap(stored.first { $0.title == "Synthetic offset all-day" })
        let allDaySnapshot = try XCTUnwrap(snapshots.first { $0.title == "Synthetic offset all-day" })
        let allDay = try XCTUnwrap(projected.first { $0.isAllDay })
        // EventKit providers can persist all-day events as floating. Preserve the
        // actual stored date/zone semantics instead of inventing a source timezone.
        let nativeZone = try XCTUnwrap(nativeAllDay.timeZone ?? TimeZone(identifier: allDaySnapshot.readTimeZoneIdentifier))
        var dateCalendar = Calendar(identifier: .gregorian)
        dateCalendar.timeZone = nativeZone
        XCTAssertEqual(allDay.timezone, nativeZone.identifier)
        XCTAssertEqual(dateCalendar.dateComponents([.year, .month, .day], from: allDay.start),
                       dateCalendar.dateComponents([.year, .month, .day], from: nativeAllDay.startDate))
        XCTAssertEqual(dateCalendar.dateComponents([.year, .month, .day], from: allDay.end),
                       dateCalendar.dateComponents([.year, .month, .day], from: nativeAllDay.endDate))

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "native-fixed-offset-snapshot.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeWriterCreatesOnceUpdatesAndRemovesOnlyItsProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let writer = CloudMeetingCalendarWriter()
        let first = fixture.meeting()
        try await writer.save(first, calendarID: fixture.calendarID, namespace: fixture.namespace)
        let initial = try XCTUnwrap(try fixture.projections(for: first.id).first)
        let identifier = initial.eventIdentifier
        XCTAssertEqual(initial.title, first.title)
        XCTAssertEqual(initial.startDate, first.start)
        XCTAssertEqual(initial.endDate, first.end)

        try await writer.save(first, calendarID: fixture.calendarID, namespace: fixture.namespace)
        XCTAssertEqual(try fixture.projections(for: first.id).count, 1)
        XCTAssertEqual(try fixture.projections(for: first.id).first?.eventIdentifier, identifier)

        let updated = fixture.meeting(id: first.id, revision: 2, offset: 7200, title: "Simulator changed time")
        try await writer.save(updated, calendarID: fixture.calendarID, namespace: fixture.namespace)
        let changed = try XCTUnwrap(try fixture.projections(for: first.id).first)
        XCTAssertEqual(changed.eventIdentifier, identifier)
        XCTAssertEqual(changed.title, updated.title)
        XCTAssertEqual(changed.startDate, updated.start)
        XCTAssertEqual(try fixture.projections(for: first.id).count, 1)

        let cancelled = fixture.meeting(id: first.id, revision: 2, status: "cancelled", offset: 7200)
        let reconciled = try await writer.reconcile(cancelled, namespace: fixture.namespace)
        XCTAssertTrue(reconciled)
        XCTAssertTrue(try fixture.projections(for: first.id).isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: fixture.mappingKey(first.id)))
        // A repeated cancellation is harmless and cannot recreate anything.
        try await writer.remove(cancelled, namespace: fixture.namespace)
        XCTAssertTrue(try fixture.events().isEmpty)
    }

    func testNativeWriterDoesNotCreateForUnmappedOrUnconfirmedMeetings() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let writer = CloudMeetingCalendarWriter()
        let confirmed = fixture.meeting()
        let reconciled = try await writer.reconcile(confirmed, namespace: fixture.namespace)
        XCTAssertFalse(reconciled, "First calendar creation requires an explicit destination choice.")
        XCTAssertTrue(try fixture.events().isEmpty)
        let proposed = fixture.meeting(status: "proposed")
        do {
            try await writer.save(proposed, calendarID: fixture.calendarID, namespace: fixture.namespace)
            XCTFail("An unconfirmed proposal must not be inserted into Calendar.")
        } catch CloudCalendarWriteError.destination { }
        do {
            try await writer.save(confirmed, calendarID: UUID().uuidString, namespace: fixture.namespace)
            XCTFail("A missing destination must not fall back to another calendar.")
        } catch CloudCalendarWriteError.destination { }
        XCTAssertTrue(try fixture.events().isEmpty)
    }

    func testNativeWriterRecoversAnUnmodifiedWriteBeforeMappingWasSaved() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        guard fixture.supportedAvailabilities.contains(.busy) else {
            throw XCTSkip("This Simulator's local calendar does not preserve the Busy availability required by recovery.")
        }
        let meeting = fixture.meeting()
        let staged = try fixture.addEvent(title: meeting.title, start: meeting.start,
                                         availability: .busy, marker: fixture.marker(meeting.id))
        let identifier = staged.eventIdentifier
        XCTAssertNil(UserDefaults.standard.data(forKey: fixture.mappingKey(meeting.id)))
        let writer = CloudMeetingCalendarWriter()
        try await writer.save(meeting, calendarID: fixture.calendarID, namespace: fixture.namespace)
        XCTAssertEqual(try fixture.projections(for: meeting.id).count, 1)
        XCTAssertEqual(try fixture.projections(for: meeting.id).first?.eventIdentifier, identifier)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: fixture.mappingKey(meeting.id)))
    }

    func testNativeWriterRefusesAmbiguousMarkerRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let meeting = fixture.meeting()
        try fixture.addEvent(title: meeting.title, start: meeting.start, marker: fixture.marker(meeting.id))
        try fixture.addEvent(title: meeting.title, start: meeting.start.addingTimeInterval(300),
                             marker: fixture.marker(meeting.id))
        let writer = CloudMeetingCalendarWriter()
        await expectChanged {
            try await writer.save(meeting, calendarID: fixture.calendarID, namespace: fixture.namespace)
        }
        XCTAssertEqual(try fixture.projections(for: meeting.id).count, 2)
        XCTAssertNil(UserDefaults.standard.data(forKey: fixture.mappingKey(meeting.id)))
    }

    func testNativeWriterPreservesManualNotesAndLocation() async throws {
        try await assertManualEditIsPreserved { event in
            event.notes = "Synthetic user-added note"
            event.location = "Synthetic user-added location"
        } verify: { event in
            XCTAssertEqual(event.notes, "Synthetic user-added note")
            XCTAssertEqual(event.location, "Synthetic user-added location")
        }
    }

    func testNativeWriterPreservesManualTimeChange() async throws {
        try await assertManualEditIsPreserved { event in
            event.startDate = event.startDate.addingTimeInterval(900)
            event.endDate = event.endDate.addingTimeInterval(900)
        } verify: { event in
            XCTAssertEqual(event.startDate, Self.baseDate.addingTimeInterval(900))
        }
    }

    func testNativeWriterPreservesManualAlarm() async throws {
        try await assertManualEditIsPreserved { event in
            event.addAlarm(EKAlarm(relativeOffset: -600))
        } verify: { event in
            XCTAssertTrue(event.hasAlarms)
        }
    }

    func testNativeWriterPreservesManualRecurrence() async throws {
        try await assertManualEditIsPreserved { event in
            event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                                    end: EKRecurrenceEnd(occurrenceCount: 2)))
        } verify: { event in
            XCTAssertTrue(event.hasRecurrenceRules)
        }
    }

    func testNativeWriterNeverChangesLegacyMappingsWithoutACompleteBaseline() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let writer = CloudMeetingCalendarWriter()
        let meeting = fixture.meeting()
        try await writer.save(meeting, calendarID: fixture.calendarID, namespace: fixture.namespace)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: fixture.mappingKey(meeting.id)))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "fingerprint")
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: legacy), forKey: fixture.mappingKey(meeting.id))
        await expectChanged {
            try await writer.save(meeting, calendarID: fixture.calendarID, namespace: fixture.namespace)
        }
        let cancelled = fixture.meeting(id: meeting.id, status: "cancelled")
        await expectChanged { try await writer.remove(cancelled, namespace: fixture.namespace) }
        XCTAssertEqual(try fixture.projections(for: meeting.id).count, 1)
    }

    private func assertManualEditIsPreserved(_ edit: (EKEvent) -> Void,
                                           verify: (EKEvent) -> Void,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let writer = CloudMeetingCalendarWriter()
        let meeting = fixture.meeting()
        try await writer.save(meeting, calendarID: fixture.calendarID, namespace: fixture.namespace)
        let event = try XCTUnwrap(try fixture.projections(for: meeting.id).first, file: file, line: line)
        edit(event)
        try fixture.store.save(event, span: .thisEvent, commit: true)
        let updated = fixture.meeting(id: meeting.id, revision: 2, offset: 7200)
        await expectChanged(file: file, line: line) {
            try await writer.save(updated, calendarID: fixture.calendarID, namespace: fixture.namespace)
        }
        let cancelled = fixture.meeting(id: meeting.id, status: "cancelled")
        await expectChanged(file: file, line: line) {
            try await writer.remove(cancelled, namespace: fixture.namespace)
        }
        let preserved = try XCTUnwrap(try fixture.projections(for: meeting.id).first, file: file, line: line)
        verify(preserved)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: fixture.mappingKey(meeting.id)), file: file, line: line)
    }

    private func expectChanged(file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("An uncertain or manually changed projection must be preserved.", file: file, line: line)
        } catch CloudCalendarWriteError.changed { }
        catch { XCTFail("Unexpected Calendar error: \(error)", file: file, line: line) }
    }

    private static let baseDate = ISO8601DateFormatter().date(from: "2027-02-10T09:00:00Z")!

    private func makeFixture() throws -> NativeCalendarFixture {
        let store = EKEventStore()
        // Reading source/calendar metadata is allowed. Never create a provider
        // source, pick an iCloud account or query another calendar's events.
        guard let source = store.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The dedicated Simulator has no local EKSource; configure Calendar locally before opting in.")
        }
        let title = "ChronoGraph Simulator Integration " + UUID().uuidString
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return NativeCalendarFixture(store: store, calendar: calendar, title: title, start: Self.baseDate)
    }
}

@MainActor
private final class NativeCalendarFixture {
    let store: EKEventStore
    let calendarID: String
    let title: String
    let sourceID: String
    let namespace = "simulator-integration." + UUID().uuidString
    let start: Date
    let supportedAvailabilities: EKCalendarEventAvailabilityMask
    private var meetingIDs = Set<UUID>()
    var window: DateInterval { DateInterval(start: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(14 * 86_400)) }

    init(store: EKEventStore, calendar: EKCalendar, title: String, start: Date) {
        self.store = store
        self.calendarID = calendar.calendarIdentifier
        self.sourceID = calendar.source.sourceIdentifier
        self.title = title
        self.start = start
        self.supportedAvailabilities = calendar.supportedEventAvailabilities
    }

    func meeting(id: UUID = UUID(), revision: Int = 1, status: String = "confirmed",
                 offset: TimeInterval = 0, title: String = "Simulator fixture meeting") -> CloudMeeting {
        meetingIDs.insert(id)
        let host = UUID()
        return CloudMeeting(id: id, hostId: host, title: title, start: start.addingTimeInterval(offset),
                            end: start.addingTimeInterval(offset + 3600), timezone: "Asia/Shanghai",
                            revision: revision, status: status,
                            participants: [CloudMeetingMember(userId: host, response: "accepted")], updatedAt: Date())
    }

    func marker(_ id: UUID) -> URL { URL(string: "chronograph://meeting/v1/\(id.uuidString.lowercased())")! }
    func mappingKey(_ id: UUID) -> String { "cloud.calendarProjection.\(namespace).\(id.uuidString)" }

    private func ownCalendar() throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: calendarID),
              calendar.source.sourceType == .local, calendar.source.sourceIdentifier == sourceID,
              calendar.title == title else {
            throw NSError(domain: "ChronoGraphSimulatorIntegration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic test calendar ownership could not be verified."])
        }
        return calendar
    }

    @discardableResult
    func addEvent(title: String, start: Date, availability: EKEventAvailability = .busy,
                  isAllDay: Bool = false, notes: String? = nil, location: String? = nil,
                  recurrence: EKRecurrenceRule? = nil, marker: URL? = nil,
                  timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = try ownCalendar()
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(isAllDay ? 86_400 : 3600)
        event.timeZone = timeZone
        event.isAllDay = isAllDay
        event.availability = availability
        event.notes = notes
        event.location = location
        event.url = marker
        if let recurrence { event.recurrenceRules = [recurrence] }
        try store.save(event, span: .thisEvent, commit: true)
        return event
    }

    func events() throws -> [EKEvent] {
        store.reset()
        let calendar = try ownCalendar()
        return store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar]))
    }

    func projections(for id: UUID) throws -> [EKEvent] { try events().filter { $0.url == marker(id) } }

    func dispose(file: StaticString = #filePath, line: UInt = #line) {
        for id in meetingIDs { UserDefaults.standard.removeObject(forKey: mappingKey(id)) }
        do {
            store.reset()
            if store.calendar(withIdentifier: calendarID) != nil {
                try store.removeCalendar(try ownCalendar(), commit: true)
            }
        } catch {
            XCTFail("Could not remove only the synthetic integration calendar: \(error)", file: file, line: line)
        }
    }
}
#endif
