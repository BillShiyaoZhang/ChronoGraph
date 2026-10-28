import Foundation
@preconcurrency import EventKit
import CryptoKit

struct CloudCalendarOption: Identifiable {
    let id: String
    let title: String
    let account: String
}

/// Cloud collection has its own sources, independent of temporary home browsing settings.
actor CloudCalendarReader {
    private let store = EKEventStore()
    private let snapshots = EventKitCalendarStore()
    func inventory() throws -> [CloudCalendarOption] {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { return CloudSimulatorFixtures.calendars }
        #endif
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CloudClientError.permission }
        let managed = Set(UserDefaults.standard.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? [])
        return store.calendars(for: .event).filter {
            !managed.contains($0.calendarIdentifier) && !$0.title.hasPrefix(CalendarSelectionPolicy.managedCalendarNamePrefix)
                && !$0.isSubscribed
        }.map { CloudCalendarOption(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func events(calendarID: String, interval: DateInterval) async throws -> [SourceEventSnapshot] {
        #if DEBUG
        if CloudSimulatorFixtures.enabled {
            guard CloudSimulatorFixtures.calendars.contains(where: { $0.id == calendarID }) else { throw CloudClientError.missingSource }
            return CloudSimulatorFixtures.events(calendarID: calendarID)
        }
        #endif
        let available = try inventory()
        guard available.contains(where: { $0.id == calendarID }) else { throw CloudClientError.missingSource }
        let managed = Set(UserDefaults.standard.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? [])
        return try await snapshots.sourceEvents(calendarIDs: [calendarID], interval: interval, excludedIDs: managed)
    }
}

enum CloudSnapshotProjection {
    static func opaqueUUID(_ value: String, key: Data) -> UUID {
        var bytes = Array(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func project(_ event: SourceEventSnapshot, sourceID: UUID, level: CloudUploadLevel, key: Data) throws -> CloudBusyEvent {
        guard event.startDate.timeIntervalSinceReferenceDate.isFinite,
              event.endDate.timeIntervalSinceReferenceDate.isFinite,
              event.endDate > event.startDate,
              CloudJSON.normalizedDate(event.endDate) > CloudJSON.normalizedDate(event.startDate) else { throw CloudClientError.invalidEventTime }
        // Match the server's Unicode code-point limits without truncating content.
        // Fields excluded by the upload level do not participate in validation.
        if level != .opaque, event.title.unicodeScalars.count > 500 { throw CloudClientError.uploadFieldLimit("标题", 500) }
        if level == .full {
            if let location = event.location, location.unicodeScalars.count > 1000 { throw CloudClientError.uploadFieldLimit("地点", 1000) }
            if let notes = event.notes, notes.unicodeScalars.count > 10_000 { throw CloudClientError.uploadFieldLimit("备注", 10_000) }
        }
        let identity = "\(sourceID.uuidString)|\(event.calendarItemIdentifier)"
        let occurrence = try event.occurrenceKey() ?? "single"
        return CloudBusyEvent(id: opaqueUUID("\(identity)|\(occurrence)", key: key),
            seriesId: event.isRecurring ? opaqueUUID(identity, key: key) : nil,
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            timezone: event.timeZoneIdentifier ?? event.readTimeZoneIdentifier,
            availability: event.availability == .notSupported ? "unknown" : event.availability.rawValue,
            title: level == .opaque ? nil : event.title,
            location: level == .full ? event.location : nil,
            notes: level == .full ? event.notes : nil)
    }
    static func window(now: Date = Date(), timezone: TimeZone = .current) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: today)!,
                            end: calendar.date(byAdding: .day, value: 91, to: today)!)
    }
}
