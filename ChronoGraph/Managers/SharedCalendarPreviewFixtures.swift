#if DEBUG
import Foundation

/// Opt-in UI fixtures. Every calendar read and write stays inside an in-memory actor.
enum SharedCalendarPreviewFixtures {
    static let workProfileID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    static let familyProfileID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    static let privateEventTitle = "Fixture private planning"
    static let familyEventTitle = "Fixture family lunch"

    static let accountID = "fixture.account.icloud"
    static let workSourceID = "fixture.source.work"
    static let familySourceID = "fixture.source.family"
    static let workTargetID = "fixture.target.work"
    static let familyTargetID = "fixture.target.family"

    @MainActor
    static func makeCoordinator() throws -> MirrorSyncCoordinator {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let fourthDay = calendar.date(byAdding: .day, value: 4, to: today)!
        let afterSixthDay = calendar.date(byAdding: .day, value: 7, to: today)!
        let workStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
        let familyStart = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: fourthDay)!
        let zone = calendar.timeZone.identifier
        let events = [
            SourceEventSnapshot(calendarID: workSourceID, calendarItemIdentifier: "fixture.work.item",
                eventIdentifier: "fixture.work.event", externalIdentifier: "fixture.work.external",
                title: privateEventTitle, startDate: workStart,
                endDate: calendar.date(byAdding: .hour, value: 1, to: workStart)!,
                location: "Fixture private room", notes: "Fixture confidential notes",
                timeZoneIdentifier: zone, readTimeZoneIdentifier: zone),
            SourceEventSnapshot(calendarID: familySourceID, calendarItemIdentifier: "fixture.family.item",
                eventIdentifier: "fixture.family.event", externalIdentifier: "fixture.family.external",
                title: familyEventTitle, startDate: familyStart,
                endDate: calendar.date(byAdding: .hour, value: 1, to: familyStart)!,
                location: "Fixture family kitchen", notes: "Fixture lunch notes",
                timeZoneIdentifier: zone, readTimeZoneIdentifier: zone)
        ]
        let options = [
            SharedCalendarOption(id: workSourceID, title: "Work source", sourceID: accountID,
                sourceTitle: "Fixture iCloud", isWritable: true, isManaged: false),
            SharedCalendarOption(id: familySourceID, title: "Family source", sourceID: accountID,
                sourceTitle: "Fixture iCloud", isWritable: true, isManaged: false),
            SharedCalendarOption(id: workTargetID, title: "ChronoGraph · Work", sourceID: accountID,
                sourceTitle: "Fixture iCloud", isWritable: true, isManaged: true),
            SharedCalendarOption(id: familyTargetID, title: "ChronoGraph · Family", sourceID: accountID,
                sourceTitle: "Fixture iCloud", isWritable: true, isManaged: true)
        ]
        let repository = try SharedCalendarRepository(inMemory: true)
        try repository.save(SharedCalendarState(profiles: [
            SharedCalendarProfile(id: workProfileID, name: "Work", sourceCalendarIDs: [workSourceID],
                targetSourceID: accountID, targetCalendarID: workTargetID, privacyMode: .opaque,
                range: .rolling(pastDays: 0, futureDays: 7, timeZoneIdentifier: zone)),
            SharedCalendarProfile(id: familyProfileID, name: "Family", sourceCalendarIDs: [familySourceID],
                targetSourceID: accountID, targetCalendarID: familyTargetID, privacyMode: .full,
                range: .fixed(start: fourthDay, endExclusive: afterSixthDay, timeZoneIdentifier: zone))
        ]))
        return try MirrorSyncCoordinator(repository: repository,
            store: SharedCalendarFixtureStore(calendars: options, sourceEvents: events))
    }
}

/// A complete CalendarStore implementation with no EventKit instance, authorization, or disk writes.
actor SharedCalendarFixtureStore: CalendarStore {
    private var calendars: [String: SharedCalendarOption]
    private let events: [SourceEventSnapshot]
    private var targets: [String: [String: MirrorTargetSnapshot]] = [:]

    init(calendars: [SharedCalendarOption], sourceEvents: [SourceEventSnapshot]) {
        self.calendars = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        events = sourceEvents
        for calendar in calendars where calendar.isManaged { targets[calendar.id] = [:] }
    }

    func inventory(managedCalendarIDs: Set<String>) throws -> SharedCalendarInventory {
        let options = calendars.values.map { calendar in
            SharedCalendarOption(id: calendar.id, title: calendar.title, sourceID: calendar.sourceID,
                sourceTitle: calendar.sourceTitle, isWritable: calendar.isWritable,
                isManaged: calendar.isManaged || managedCalendarIDs.contains(calendar.id))
        }.sorted { $0.title < $1.title }
        let accounts = Dictionary(grouping: options, by: \.sourceID).map { id, values in
            SharedCalendarAccount(id: id, title: values[0].sourceTitle, calendarTitles: values.map(\.title).sorted())
        }.sorted { $0.id < $1.id }
        return SharedCalendarInventory(calendars: options, accounts: accounts)
    }

    func sourceEvents(calendarIDs: Set<String>, interval: DateInterval, excludedIDs: Set<String>) throws -> [SourceEventSnapshot] {
        try Task.checkCancellation()
        for id in calendarIDs {
            guard let calendar = calendars[id] else { throw SharedCalendarError.missingSource }
            guard !calendar.isManaged, !excludedIDs.contains(id) else { throw SharedCalendarError.managedSource }
        }
        guard !calendarIDs.isEmpty else { return [] }
        return events.filter { event in
            calendarIDs.contains(event.calendarID) && event.startDate < interval.end &&
                (event.endDate > interval.start || event.startDate >= interval.start)
        }.sorted { $0.startDate < $1.startDate }
    }

    func createCalendar(name: String, sourceID: String) throws -> String {
        try requireAccount(sourceID)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedCalendarError.invalidName }
        let id = "fixture.target.\(UUID().uuidString.lowercased())"
        calendars[id] = SharedCalendarOption(id: id, title: "ChronoGraph · " + name, sourceID: sourceID,
            sourceTitle: "Fixture iCloud", isWritable: true, isManaged: true)
        targets[id] = [:]
        return id
    }

    func renameCalendar(id: String, name: String, sourceID: String) throws {
        let calendar = try target(id, sourceID: sourceID)
        calendars[id] = SharedCalendarOption(id: id, title: "ChronoGraph · " + name,
            sourceID: sourceID, sourceTitle: calendar.sourceTitle, isWritable: true, isManaged: true)
    }

    func removeCalendar(id: String, sourceID: String) throws {
        try requireAccount(sourceID)
        guard calendars[id] != nil else { return }
        _ = try target(id, sourceID: sourceID)
        targets.removeValue(forKey: id)
        calendars.removeValue(forKey: id)
    }

    func targetEvents(calendarID: String, sourceID: String, interval: DateInterval,
                      mappings: [MirrorMapping]) throws -> [MirrorTargetSnapshot] {
        _ = try target(calendarID, sourceID: sourceID)
        let trackedIDs = Set(mappings.compactMap(\.targetEventID))
        let trackedMarkers = Set(mappings.map(\.mirrorID))
        return (targets[calendarID] ?? [:]).values.filter { snapshot in
            let content = snapshot.content
            return trackedIDs.contains(snapshot.eventID) ||
                snapshot.mirrorID.map { trackedMarkers.contains($0) } == true ||
                (content.startDate < interval.end && content.endDate > interval.start)
        }.sorted { $0.eventID < $1.eventID }
    }

    func upsert(_ event: PublishedEvent, mapping: MirrorMapping, calendarID: String,
                sourceID: String, existingID: String?) throws -> String {
        _ = try target(calendarID, sourceID: sourceID)
        if let existingID, let existing = targets[calendarID]?[existingID] {
            guard existing.mirrorID == mapping.mirrorID ||
                    (existing.mirrorID == nil && mapping.targetEventID == existingID) else {
                throw SharedCalendarError.ambiguousRecovery
            }
            guard !existing.hasMeetingParticipants else { throw SharedCalendarError.meetingParticipants }
        }
        let eventID = existingID ?? "fixture.mirror.\(mapping.mirrorID.uuidString.lowercased())"
        targets[calendarID, default: [:]][eventID] = MirrorTargetSnapshot(eventID: eventID,
            mirrorID: mapping.mirrorID, content: event, hasExtraFields: false)
        return eventID
    }

    func removeEvent(id: String, mirrorID: UUID, calendarID: String, sourceID: String) throws {
        _ = try target(calendarID, sourceID: sourceID)
        guard let event = targets[calendarID]?[id] else { return }
        guard event.mirrorID == mirrorID else { throw SharedCalendarError.ambiguousRecovery }
        guard !event.hasMeetingParticipants else { throw SharedCalendarError.meetingParticipants }
        targets[calendarID]?.removeValue(forKey: id)
    }

    private func requireAccount(_ id: String) throws {
        guard calendars.values.contains(where: { $0.sourceID == id }) else { throw SharedCalendarError.invalidAccount }
    }

    private func target(_ id: String, sourceID: String) throws -> SharedCalendarOption {
        guard let calendar = calendars[id], calendar.sourceID == sourceID,
              calendar.isWritable, calendar.isManaged else { throw SharedCalendarError.missingTarget }
        return calendar
    }
}
#endif
