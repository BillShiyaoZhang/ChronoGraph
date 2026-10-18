import Foundation
@preconcurrency import EventKit

struct SharedCalendarOption: Identifiable, Sendable {
    let id: String
    let title: String
    let sourceID: String
    let sourceTitle: String
    let isWritable: Bool
    let isManaged: Bool
}

struct SharedCalendarAccount: Identifiable, Sendable {
    let id: String
    let title: String
    let calendarTitles: [String]
}

struct SharedCalendarInventory: Sendable {
    var calendars: [SharedCalendarOption]
    var accounts: [SharedCalendarAccount]
}

struct SharedEventPreview: Identifiable, Sendable {
    let id: String
    let identityID: UUID
    let occurrenceKey: String?
    let isRecurring: Bool
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let visibility: SharedVisibility
    let override: SharedVisibility?
    let seriesOverride: SharedVisibility?
    let published: PublishedEvent?
    var source: SourceEventSnapshot? = nil
    var defaultPrivacyMode: PrivacyMode = .partial
}

struct MirrorTargetSnapshot: Sendable {
    let eventID: String
    let mirrorID: UUID?
    let content: PublishedEvent
    let hasExtraFields: Bool
    var hasMeetingParticipants: Bool = false
}

enum SharedCalendarError: LocalizedError, Equatable {
    case permission, missingSource, missingTarget, invalidAccount, invalidName
    case managedSource, unavailableStorage, ambiguousRecovery, staleConfiguration, meetingParticipants

    var errorDescription: String? {
        let key: String
        switch self {
        case .permission: key = "sharing.error.permission"
        case .missingSource: key = "sharing.error.sourceMissing"
        case .missingTarget: key = "sharing.error.targetMissing"
        case .invalidAccount: key = "sharing.error.account"
        case .invalidName: key = "sharing.error.name"
        case .managedSource: key = "sharing.error.managedSource"
        case .unavailableStorage: key = "sharing.error.storage"
        case .ambiguousRecovery: key = "sharing.error.recovery"
        case .staleConfiguration: key = "sharing.error.changed"
        case .meetingParticipants: key = "sharing.error.participants"
        }
        return NSLocalizedString(key, comment: "Shared calendar error")
    }
}

protocol CalendarStore: Sendable {
    func inventory(managedCalendarIDs: Set<String>) async throws -> SharedCalendarInventory
    func sourceEvents(calendarIDs: Set<String>, interval: DateInterval, excludedIDs: Set<String>) async throws -> [SourceEventSnapshot]
    func createCalendar(name: String, sourceID: String) async throws -> String
    func renameCalendar(id: String, name: String, sourceID: String) async throws
    func removeCalendar(id: String, sourceID: String) async throws
    func targetEvents(calendarID: String, sourceID: String, interval: DateInterval, mappings: [MirrorMapping]) async throws -> [MirrorTargetSnapshot]
    func upsert(_ event: PublishedEvent, mapping: MirrorMapping, calendarID: String, sourceID: String, existingID: String?) async throws -> String
    func removeEvent(id: String, mirrorID: UUID, calendarID: String, sourceID: String) async throws
}

/// EventKit objects never leave this actor. Only immutable projections cross its boundary.
actor EventKitCalendarStore: CalendarStore {
    private let store = EKEventStore()
    static let namePrefix = "ChronoGraph · "

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw SharedCalendarError.permission
        }
    }

    func inventory(managedCalendarIDs: Set<String>) throws -> SharedCalendarInventory {
        try requireAccess()
        let calendars = store.calendars(for: .event)
        let options = calendars.map { calendar in
            SharedCalendarOption(id: calendar.calendarIdentifier, title: calendar.title,
                sourceID: calendar.source.sourceIdentifier, sourceTitle: calendar.source.title,
                isWritable: calendar.allowsContentModifications,
                isManaged: managedCalendarIDs.contains(calendar.calendarIdentifier) || calendar.title.hasPrefix(Self.namePrefix))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        // Public EventKit does not distinguish iCloud from other CalDAV accounts.
        // The UI asks the owner to explicitly confirm the account.
        let accounts = store.sources.filter { $0.sourceType == .calDAV }.map { source in
            SharedCalendarAccount(id: source.sourceIdentifier, title: source.title,
                calendarTitles: calendars.filter { $0.source.sourceIdentifier == source.sourceIdentifier }.map(\.title).sorted())
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return SharedCalendarInventory(calendars: options, accounts: accounts)
    }

    private func sourceCalendars(_ ids: Set<String>, excluded: Set<String>) throws -> [EKCalendar] {
        try requireAccess()
        return try ids.sorted().map { id in
            guard let calendar = store.calendar(withIdentifier: id) else { throw SharedCalendarError.missingSource }
            guard !excluded.contains(id), !calendar.title.hasPrefix(Self.namePrefix) else { throw SharedCalendarError.managedSource }
            return calendar
        }
    }

    private func chunks(_ interval: DateInterval) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let next = min(start.addingTimeInterval(366 * 86_400), interval.end)
            result.append(DateInterval(start: start, end: next))
            start = next
        }
        return result
    }

    func sourceEvents(calendarIDs: Set<String>, interval: DateInterval, excludedIDs: Set<String>) throws -> [SourceEventSnapshot] {
        let calendars = try sourceCalendars(calendarIDs, excluded: excludedIDs)
        // EventKit treats an empty calendar filter as an unrestricted query on some versions.
        guard !calendars.isEmpty else { return [] }
        var snapshots: [SourceEventSnapshot] = []
        var seen = Set<String>()
        for chunk in chunks(interval) {
            try Task.checkCancellation()
            let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: calendars)
            for event in store.events(matching: predicate) where event.status != .canceled {
                guard event.startDate < interval.end, event.endDate > interval.start || event.startDate >= interval.start else { continue }
                let recurring = event.hasRecurrenceRules || event.isDetached
                let occurrence = recurring ? event.occurrenceDate : nil
                let dedup = "\(event.calendar.calendarIdentifier)|\(event.calendarItemIdentifier)|\(occurrence?.timeIntervalSince1970 ?? event.startDate.timeIntervalSince1970)"
                guard seen.insert(dedup).inserted else { continue }
                snapshots.append(SourceEventSnapshot(calendarID: event.calendar.calendarIdentifier,
                    calendarItemIdentifier: event.calendarItemIdentifier, eventIdentifier: event.eventIdentifier,
                    externalIdentifier: event.calendarItemExternalIdentifier, occurrenceDate: occurrence,
                    isRecurring: recurring, title: event.title ?? NSLocalizedString("event.untitled", comment: ""),
                    startDate: event.startDate, endDate: event.endDate, location: event.location, notes: event.notes,
                    isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZone?.identifier,
                    availability: CalendarEvent.Availability(ekEventAvailability: event.availability)))
            }
        }
        _ = try sourceCalendars(calendarIDs, excluded: excludedIDs)
        return snapshots.sorted { $0.startDate == $1.startDate ? $0.title < $1.title : $0.startDate < $1.startDate }
    }

    private func target(_ id: String, sourceID: String) throws -> EKCalendar {
        try requireAccess()
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications,
              calendar.source.sourceIdentifier == sourceID else { throw SharedCalendarError.missingTarget }
        return calendar
    }

    func createCalendar(name: String, sourceID: String) throws -> String {
        try requireAccess()
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceID && $0.sourceType == .calDAV }) else {
            throw SharedCalendarError.invalidAccount
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.namePrefix + name
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    func renameCalendar(id: String, name: String, sourceID: String) throws {
        let calendar = try target(id, sourceID: sourceID)
        let title = Self.namePrefix + name
        guard calendar.title != title else { return }
        calendar.title = title
        try store.saveCalendar(calendar, commit: true)
    }

    func removeCalendar(id: String, sourceID: String) throws {
        try requireAccess()
        guard store.sources.contains(where: { $0.sourceIdentifier == sourceID && $0.sourceType == .calDAV }) else {
            throw SharedCalendarError.invalidAccount
        }
        // A retry after a successful deletion is already complete.
        guard store.calendar(withIdentifier: id) != nil else { return }
        try store.removeCalendar(try target(id, sourceID: sourceID), commit: true)
    }

    func targetEvents(calendarID: String, sourceID: String, interval: DateInterval, mappings: [MirrorMapping]) throws -> [MirrorTargetSnapshot] {
        let calendar = try target(calendarID, sourceID: sourceID)
        var events: [String: EKEvent] = [:]
        for chunk in chunks(interval) {
            try Task.checkCancellation()
            for event in store.events(matching: store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: [calendar])) {
                if let id = event.eventIdentifier { events[id] = event }
            }
        }
        // Include already published events outside the new window for deletion and crash recovery.
        for mapping in mappings {
            if let id = mapping.targetEventID, let event = store.event(withIdentifier: id), event.calendar.calendarIdentifier == calendarID {
                events[id] = event
            }
            if let start = mapping.lastStart, let end = mapping.lastEnd {
                let recovery = DateInterval(start: start.addingTimeInterval(-1), end: max(end, start.addingTimeInterval(1)).addingTimeInterval(1))
                for chunk in chunks(recovery) {
                    let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: [calendar])
                    for event in store.events(matching: predicate) {
                        if let id = event.eventIdentifier { events[id] = event }
                    }
                }
            }
        }
        return events.values.compactMap { event in
            guard let id = event.eventIdentifier else { return nil }
            let source = SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: event.calendarItemIdentifier,
                title: event.title ?? "", startDate: event.startDate, endDate: event.endDate,
                location: event.location, notes: event.notes, isAllDay: event.isAllDay,
                timeZoneIdentifier: event.timeZone?.identifier,
                availability: CalendarEvent.Availability(ekEventAvailability: event.availability))
            guard let content = PublishedEvent(source: source, visibility: .full) else { return nil }
            return MirrorTargetSnapshot(eventID: id, mirrorID: MirrorMapping.mirrorID(from: event.url), content: content,
                hasExtraFields: event.hasAlarms || event.hasRecurrenceRules || !(event.attendees ?? []).isEmpty || event.organizer != nil || event.structuredLocation?.geoLocation != nil,
                hasMeetingParticipants: !(event.attendees ?? []).isEmpty || event.organizer != nil)
        }
    }

    func upsert(_ content: PublishedEvent, mapping: MirrorMapping, calendarID: String, sourceID: String, existingID: String?) throws -> String {
        let calendar = try target(calendarID, sourceID: sourceID)
        let existing = existingID.flatMap { store.event(withIdentifier: $0) }
        if let existing, existing.calendar.calendarIdentifier != calendarID { throw SharedCalendarError.ambiguousRecovery }
        // Never edit an unrelated item, even if a stale identifier now points at it.
        if let existing {
            let marker = MirrorMapping.mirrorID(from: existing.url)
            guard marker == mapping.mirrorID || (marker == nil && mapping.targetEventID == existingID) else {
                throw SharedCalendarError.ambiguousRecovery
            }
            // Attendee/organizer properties are read-only. Never retain them or trigger meeting
            // cancellation messages by silently replacing an owner-edited invitation.
            guard (existing.attendees ?? []).isEmpty, existing.organizer == nil else {
                throw SharedCalendarError.meetingParticipants
            }
        }
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = content.title
        event.startDate = content.startDate
        event.endDate = content.endDate
        event.isAllDay = content.isAllDay
        event.timeZone = content.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        event.structuredLocation = nil
        event.location = content.location
        event.notes = content.notes
        event.url = mapping.markerURL
        event.alarms = nil
        event.recurrenceRules = nil
        switch content.availability {
        case .busy: event.availability = .busy
        case .free: event.availability = .free
        case .tentative: event.availability = .tentative
        case .unavailable: event.availability = .unavailable
        case .notSupported: event.availability = .notSupported
        }
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw SharedCalendarError.ambiguousRecovery }
        return id
    }

    func removeEvent(id: String, mirrorID: UUID, calendarID: String, sourceID: String) throws {
        _ = try target(calendarID, sourceID: sourceID)
        guard let event = store.event(withIdentifier: id) else { return }
        guard event.calendar.calendarIdentifier == calendarID,
              MirrorMapping.mirrorID(from: event.url) == mirrorID else { throw SharedCalendarError.ambiguousRecovery }
        guard (event.attendees ?? []).isEmpty, event.organizer == nil else { throw SharedCalendarError.meetingParticipants }
        try store.remove(event, span: .thisEvent, commit: true)
    }
}
