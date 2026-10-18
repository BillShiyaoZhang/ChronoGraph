import Foundation
import Testing
@testable import ChronoGraph

struct SharedCalendarTests {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func source(itemID: String = "source-item", eventID: String = "source-event",
                        externalID: String? = "external-event", recurring: Bool = false,
                        occurrence: Date? = nil, start: Date? = nil, allDay: Bool = false,
                        zone: String? = "Asia/Shanghai", readZone: String = "Asia/Shanghai",
                        calendarID: String = "private-calendar") -> SourceEventSnapshot {
        let startDate = start ?? date("2026-10-18T02:00:00Z")
        return SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: itemID,
                                   eventIdentifier: eventID, externalIdentifier: externalID,
                                   occurrenceDate: occurrence, isRecurring: recurring, title: "Confidential project",
                                   startDate: startDate, endDate: startDate.addingTimeInterval(3600),
                                   location: "Secret office", notes: "Private meeting notes", isAllDay: allDay,
                                   timeZoneIdentifier: zone, readTimeZoneIdentifier: readZone, availability: .busy)
    }

    @Test func publicationProjectsOnlyAllowedFields() throws {
        let event = source()
        #expect(PublishedEvent(source: event, visibility: .excluded) == nil)
        let opaque = try #require(PublishedEvent(source: event, visibility: .opaque))
        #expect(opaque.title == event.availability.localizedName)
        #expect(opaque.location == nil && opaque.notes == nil)
        #expect(opaque.startDate == event.startDate && opaque.endDate == event.endDate)
        let partial = try #require(PublishedEvent(source: event, visibility: .partial))
        #expect(partial.title == event.title)
        #expect(partial.location == nil && partial.notes == nil)
        let full = try #require(PublishedEvent(source: event, visibility: .full))
        #expect(full.location == event.location && full.notes == event.notes)
        let encoded = String(decoding: try JSONEncoder().encode(opaque), as: UTF8.self)
        #expect(!encoded.contains("Confidential"))
        #expect(!encoded.contains("source-item"))
        #expect(!encoded.contains("private-calendar"))
    }

    @Test func rollingRangeUsesCalendarDaysAcrossDST() throws {
        let range = SharedCalendarRange.rolling(pastDays: 1, futureDays: 1, timeZoneIdentifier: "America/New_York")
        let interval = try range.dateInterval(now: date("2026-03-08T16:00:00Z"))
        #expect(interval.start == date("2026-03-07T05:00:00Z"))
        #expect(interval.end == date("2026-03-10T04:00:00Z"))
        #expect(interval.duration == 71 * 3600)
        let defaultRange = try SharedCalendarRange.rolling(timeZoneIdentifier: "Asia/Shanghai")
            .dateInterval(now: date("2026-10-18T12:00:00Z"))
        #expect(defaultRange.duration == 98 * 24 * 3600)
    }

    @Test func fixedRangeIsHalfOpenAndRejectsInvalidInput() throws {
        let start = date("2026-10-17T16:00:00Z")
        let end = date("2026-10-20T16:00:00Z")
        let interval = try SharedCalendarRange.fixed(start: start, endExclusive: end,
                                                     timeZoneIdentifier: "Asia/Shanghai").dateInterval()
        #expect(interval.start == start && interval.end == end)
        #expect(throws: SharedCalendarModelError.invalidRange) {
            try SharedCalendarRange.fixed(start: end, endExclusive: start).dateInterval()
        }
        #expect(throws: SharedCalendarModelError.invalidRange) {
            try SharedCalendarRange.rolling(pastDays: -1).dateInterval()
        }
        #expect(throws: SharedCalendarModelError.invalidTimeZone("not-a-zone")) {
            try SharedCalendarRange.rolling(timeZoneIdentifier: "not-a-zone").dateInterval()
        }
    }

    @Test func singleOccurrenceOverridesSeriesAndInheritanceIsRestored() {
        let profileID = UUID()
        let sourceID = UUID()
        let first = SourceInstanceKey(sourceIdentityID: sourceID, occurrenceKey: "instant:1")
        let second = SourceInstanceKey(sourceIdentityID: sourceID, occurrenceKey: "instant:2")
        var state = SharedCalendarState()
        state.setVisibility(.opaque, profileID: profileID, sourceKey: first, scope: .series)
        state.setVisibility(.excluded, profileID: profileID, sourceKey: first)
        #expect(state.visibility(profileID: profileID, sourceKey: first, defaultMode: .full) == .excluded)
        #expect(state.visibility(profileID: profileID, sourceKey: second, defaultMode: .full) == .opaque)
        #expect(state.visibility(profileID: UUID(), sourceKey: first, defaultMode: .partial) == .partial)
        state.setVisibility(nil, profileID: profileID, sourceKey: first)
        #expect(state.visibility(profileID: profileID, sourceKey: first, defaultMode: .full) == .opaque)
        state.setVisibility(nil, profileID: profileID, sourceKey: first, scope: .series)
        #expect(state.visibility(profileID: profileID, sourceKey: first, defaultMode: .full) == .full)
    }

    @Test func eventAndRecurringInstanceIdentitySurviveReschedulingAndSyncAliases() throws {
        var state = SharedCalendarState()
        let first = try state.resolveIdentity(for: source())
        let moved = try state.resolveIdentity(for: source(start: date("2026-10-20T02:00:00Z")))
        #expect(first == moved)
        let resynced = try state.resolveIdentity(for: source(itemID: "replacement-item", eventID: "replacement-event"))
        #expect(first == resynced)
        #expect(state.identities.count == 1)
        let originalOccurrence = date("2026-10-18T02:00:00Z")
        let occurrence = try state.resolveIdentity(for: source(itemID: "series", eventID: "series-event",
            externalID: "series-external", recurring: true, occurrence: originalOccurrence))
        let changed = try state.resolveIdentity(for: source(itemID: "series", eventID: "series-event",
            externalID: "series-external", recurring: true, occurrence: originalOccurrence,
            start: date("2026-10-21T02:00:00Z")))
        #expect(occurrence == changed)
        let next = try state.resolveIdentity(for: source(itemID: "series", eventID: "series-event",
            externalID: "series-external", recurring: true, occurrence: date("2026-10-25T02:00:00Z")))
        #expect(occurrence.sourceIdentityID == next.sourceIdentityID)
        #expect(occurrence.occurrenceKey != next.occurrenceKey)
    }

    @Test func allDayIdentityUsesOriginalLocalDate() throws {
        let snapshot = source(recurring: true, occurrence: date("2026-10-17T16:00:00Z"), allDay: true)
        #expect(try snapshot.occurrenceKey() == "day:2026-10-18")
        var moved = snapshot
        moved.startDate = date("2026-10-20T16:00:00Z")
        #expect(try moved.occurrenceKey() == snapshot.occurrenceKey())
    }

    @Test func floatingAndAllDayIdentitySurviveTravelAcrossTimeZones() throws {
        let shanghai = source(recurring: true, occurrence: date("2026-10-18T02:00:00Z"),
                              zone: nil, readZone: "Asia/Shanghai")
        let newYork = source(recurring: true, occurrence: date("2026-10-18T14:00:00Z"),
                             zone: nil, readZone: "America/New_York")
        #expect(try shanghai.occurrenceKey() == "floating:2026-10-18T10:00:00")
        #expect(try shanghai.occurrenceKey() == newYork.occurrenceKey())
        var state = SharedCalendarState()
        let originalKey = try state.resolveIdentity(for: shanghai)
        let profileID = UUID()
        state.setVisibility(.excluded, profileID: profileID, sourceKey: originalKey)
        let traveledKey = try state.resolveIdentity(for: newYork)
        #expect(traveledKey == originalKey)
        #expect(state.visibility(profileID: profileID, sourceKey: traveledKey, defaultMode: .full) == .excluded)

        let originalAllDay = source(recurring: true, occurrence: date("2026-10-17T16:00:00Z"), allDay: true,
                                    zone: nil, readZone: "Asia/Shanghai")
        let traveledAllDay = source(recurring: true, occurrence: date("2026-10-18T04:00:00Z"), allDay: true,
                                    zone: nil, readZone: "America/New_York")
        #expect(try originalAllDay.occurrenceKey() == traveledAllDay.occurrenceKey())

        var absolute = newYork
        absolute.timeZoneIdentifier = "Asia/Shanghai"
        #expect(try absolute.occurrenceKey() != shanghai.occurrenceKey())
    }

    @Test func changingSeriesIntoStandaloneDoesNotDiscardPrivateOccurrenceOverrides() throws {
        var state = SharedCalendarState()
        let occurrence = date("2026-10-18T02:00:00Z")
        let key = try state.resolveIdentity(for: source(recurring: true, occurrence: occurrence))
        let profileID = UUID()
        state.setVisibility(.excluded, profileID: profileID, sourceKey: key)
        let saved = state
        #expect(throws: SharedCalendarModelError.ambiguousIdentity) {
            try state.resolveIdentity(for: source())
        }
        #expect(state == saved)
    }

    @Test func duplicateExternalIdentifiersAreScopedAndDoNotPartiallyMutateState() throws {
        var state = SharedCalendarState()
        let conflicting = [source(), source(itemID: "another-item", eventID: "another-event")]
        #expect(throws: SharedCalendarModelError.ambiguousExternalIdentifier("external-event")) {
            try state.resolveIdentities(for: conflicting)
        }
        #expect(state.identities.isEmpty)
        let keys = try state.resolveIdentities(for: [source(), source(itemID: "another-item", eventID: "another-event",
                                                                     calendarID: "another-calendar")])
        #expect(keys[0].sourceIdentityID != keys[1].sourceIdentityID)
        let duplicateID = SourceIdentity(calendarID: "private-calendar", externalIdentifier: "external-event")
        state.identities.append(duplicateID)
        #expect(throws: SharedCalendarModelError.ambiguousExternalIdentifier("external-event")) {
            try state.resolveIdentity(for: source())
        }
    }

    @Test func markersContainOnlyRandomMirrorIdentity() throws {
        let key = SourceInstanceKey(sourceIdentityID: UUID(), occurrenceKey: "private-occurrence")
        let mapping = MirrorMapping(profileID: UUID(), sourceKey: key)
        #expect(MirrorMapping.mirrorID(from: mapping.markerURL) == mapping.mirrorID)
        #expect(!mapping.markerURL.absoluteString.contains(mapping.profileID.uuidString))
        #expect(!mapping.markerURL.absoluteString.contains(key.sourceIdentityID.uuidString))
        #expect(!mapping.markerURL.absoluteString.contains("private-occurrence"))
        #expect(MirrorMapping.mirrorID(from: URL(string: "https://mirror/v1/\(mapping.mirrorID)")) == nil)
        #expect(MirrorMapping.mirrorID(from: URL(string: "chronograph://mirror/v1/\(mapping.mirrorID)?source=secret")) == nil)
    }

    @MainActor @Test func repositoryAtomicallyRoundTripsConfigurationAndPendingWrites() throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        #expect(try repository.load() == SharedCalendarState())
        let profile = SharedCalendarProfile(name: "Family", sourceCalendarIDs: ["private-calendar"], targetSourceID: "icloud")
        var state = SharedCalendarState(profiles: [profile])
        let key = try state.resolveIdentity(for: source())
        state.setVisibility(.opaque, profileID: profile.id, sourceKey: key)
        let mapping = MirrorMapping(profileID: profile.id, sourceKey: key, lastStart: source().startDate,
                                    lastEnd: source().endDate, fingerprint: "safe-content-digest")
        state.mappings = [mapping]
        state.operations = [MirrorOperation(profileID: profile.id, mappingID: mapping.mirrorID, kind: .upsert)]
        try repository.save(state)
        #expect(try repository.load() == state)
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!encoded.contains("Confidential project"))
        #expect(!encoded.contains("Private meeting notes"))
        state.operations.removeAll()
        state.mappings[0].targetEventID = "saved-target"
        try repository.save(state)
        #expect(try repository.load() == state)
        let separate = try SharedCalendarRepository(inMemory: true)
        #expect(try separate.load().profiles.isEmpty)
    }

    @MainActor @Test func persistentStoreCreatesAnExcludedDirectoryAndReopensSavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("SharedCalendars", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let repository = try SharedCalendarRepository(storageDirectory: directory)
        let profile = SharedCalendarProfile(name: "Local only", sourceCalendarIDs: [], targetSourceID: "icloud")
        try repository.save(SharedCalendarState(profiles: [profile]))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("shared-calendars.store").path))
        let reopened = try SharedCalendarRepository(storageDirectory: directory)
        #expect(try reopened.load().profiles == [profile])
    }
}
