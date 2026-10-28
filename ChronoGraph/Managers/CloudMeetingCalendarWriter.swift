import Foundation
@preconcurrency import EventKit

struct CloudCalendarDestination: Identifiable {
    let id: String
    let title: String
    let account: String
}

enum CloudCalendarWriteError: LocalizedError {
    case destination, changed
    var errorDescription: String? {
        switch self {
        case .destination: return "请选择自己的可写日历。"
        case .changed: return "之前创建的日程已被手动修改或无法核对。请在系统日历中检查，应用不会覆盖或重复创建。"
        }
    }
}

/// Calendar mutations happen only after an explicit user action, and only for app-owned projections.
actor CloudMeetingCalendarWriter {
    private let store = EKEventStore()
    private struct Mapping: Codable {
        var eventID: String
        var calendarID: String
        var title: String
        var start: Date
        var end: Date
        var revision: Int
        var fingerprint: CloudProjectionFingerprint?
    }
    func destinations() throws -> [CloudCalendarDestination] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CloudClientError.permission }
        // Calendar.app (or another process) may have changed a projection since
        // our last save. Discard cached EKObjects before checking ownership.
        // save() calls this before fetching either its destination or event.
        store.reset()
        let managed = Set(UserDefaults.standard.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? [])
        return store.calendars(for: .event).filter {
            $0.allowsContentModifications && !$0.isSubscribed && !managed.contains($0.calendarIdentifier)
                && !$0.title.hasPrefix(CalendarSelectionPolicy.managedCalendarNamePrefix)
        }.map { CloudCalendarDestination(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func save(_ meeting: CloudMeeting, calendarID: String, namespace: String) throws {
        guard meeting.status == "confirmed", try destinations().contains(where: { $0.id == calendarID }),
              let destination = store.calendar(withIdentifier: calendarID) else { throw CloudCalendarWriteError.destination }
        let marker = URL(string: "chronograph://meeting/v1/\(meeting.id.uuidString.lowercased())")!
        let key = "cloud.calendarProjection.\(namespace).\(meeting.id.uuidString)"
        let mapping = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
        let event: EKEvent
        if let mapping {
            guard let existing = store.event(withIdentifier: mapping.eventID), existing.url == marker,
                  existing.calendar.calendarIdentifier == mapping.calendarID,
                  CloudProjectionOwnership.allowsChange(baseline: mapping.fingerprint, current: fingerprint(existing)) else { throw CloudCalendarWriteError.changed }
            event = existing
        } else {
            // Recover the EventKit-write/local-mapping interruption without creating a second event.
            let interval = DateInterval(start: meeting.start.addingTimeInterval(-86_400), end: meeting.end.addingTimeInterval(86_400))
            let matches = store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: [destination])).filter { $0.url == marker }
            guard matches.count <= 1 else { throw CloudCalendarWriteError.changed }
            event = matches.first ?? EKEvent(eventStore: store)
            if let existing = matches.first {
                guard existing.title == meeting.title, existing.startDate == meeting.start, existing.endDate == meeting.end,
                      existing.notes == nil, existing.location == nil, existing.structuredLocation == nil,
                      !existing.hasAlarms, !existing.hasRecurrenceRules, !existing.isAllDay,
                      existing.availability == .busy, existing.timeZone?.identifier == meeting.timezone,
                      (existing.attendees ?? []).isEmpty, existing.organizer == nil else { throw CloudCalendarWriteError.changed }
            }
        }
        event.calendar = destination
        event.title = meeting.title
        event.startDate = meeting.start
        event.endDate = meeting.end
        event.timeZone = TimeZone(identifier: meeting.timezone)
        event.url = marker
        event.availability = .busy
        try store.save(event, span: .thisEvent, commit: true)
        let saved = Mapping(eventID: event.eventIdentifier, calendarID: calendarID, title: meeting.title,
                            start: meeting.start, end: meeting.end, revision: meeting.revision, fingerprint: fingerprint(event))
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: key)
    }
    func remove(_ meeting: CloudMeeting, namespace: String) throws {
        guard meeting.status != "confirmed", EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CloudClientError.permission }
        store.reset()
        let key = "cloud.calendarProjection.\(namespace).\(meeting.id.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key), let mapping = try? JSONDecoder().decode(Mapping.self, from: data) else { return }
        guard let calendar = store.calendar(withIdentifier: mapping.calendarID) else { throw CloudCalendarWriteError.changed }
        let marker = URL(string: "chronograph://meeting/v1/\(meeting.id.uuidString.lowercased())")!
        let existing = store.event(withIdentifier: mapping.eventID)
        let matches = existing.map { [$0] } ?? store.events(matching: store.predicateForEvents(withStart: mapping.start.addingTimeInterval(-86_400), end: mapping.end.addingTimeInterval(86_400), calendars: [calendar])).filter { $0.url == marker }
        guard matches.count <= 1 else { throw CloudCalendarWriteError.changed }
        if let event = matches.first {
            guard event.url == marker, event.calendar.calendarIdentifier == mapping.calendarID,
                  CloudProjectionOwnership.allowsChange(baseline: mapping.fingerprint, current: fingerprint(event)) else { throw CloudCalendarWriteError.changed }
            try store.remove(event, span: .thisEvent, commit: true)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Returns false when this device has never been authorized to create a projection.
    func reconcile(_ meeting: CloudMeeting, namespace: String) throws -> Bool {
        let key = "cloud.calendarProjection.\(namespace).\(meeting.id.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key), let mapping = try? JSONDecoder().decode(Mapping.self, from: data) else { return false }
        if meeting.status == "confirmed" { try save(meeting, calendarID: mapping.calendarID, namespace: namespace) }
        else { try remove(meeting, namespace: namespace) }
        return true
    }

    private func fingerprint(_ event: EKEvent) -> CloudProjectionFingerprint {
        CloudProjectionFingerprint(title: event.title, start: event.startDate, end: event.endDate,
            timezone: event.timeZone?.identifier, availability: event.availability.rawValue,
            isAllDay: event.isAllDay, notes: event.notes, location: event.location,
            hasAlarms: event.hasAlarms, hasRecurrenceRules: event.hasRecurrenceRules,
            hasStructuredLocation: event.structuredLocation != nil,
            hasParticipants: !(event.attendees ?? []).isEmpty || event.organizer != nil)
    }

}


struct CloudProjectionFingerprint: Codable, Equatable {
    var title: String?
    var start: Date
    var end: Date
    var timezone: String?
    var availability: Int
    var isAllDay: Bool
    var notes: String?
    var location: String?
    var hasAlarms: Bool
    var hasRecurrenceRules: Bool
    var hasStructuredLocation: Bool
    var hasParticipants: Bool
}

enum CloudProjectionOwnership {
    static func allowsChange(baseline: CloudProjectionFingerprint?, current: CloudProjectionFingerprint) -> Bool {
        guard let baseline else { return false }
        return baseline == current
    }
}
