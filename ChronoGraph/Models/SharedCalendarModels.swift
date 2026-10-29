import Foundation

enum SharedCalendarModelError: Error, LocalizedError, Equatable {
    case invalidRange
    case rangeTooLarge
    case invalidTimeZone(String)
    case missingOccurrenceDate
    case ambiguousIdentity
    case ambiguousExternalIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange: return NSLocalizedString("sharing.error.range", comment: "Invalid shared calendar range")
        case .rangeTooLarge: return NSLocalizedString("sharing.error.rangeTooLarge", comment: "Date range exceeds safe display limit")
        case .invalidTimeZone: return NSLocalizedString("sharing.error.timeZone", comment: "Unavailable shared calendar time zone")
        case .missingOccurrenceDate: return NSLocalizedString("sharing.error.occurrence", comment: "Unidentifiable recurring occurrence")
        case .ambiguousIdentity, .ambiguousExternalIdentifier:
            return NSLocalizedString("sharing.error.identity", comment: "Ambiguous shared calendar event identity")
        }
    }
}

enum SharedCalendarRange: Codable, Equatable, Sendable {
    /// Keep date grouping, previews and EventKit queries bounded, including restored input.
    static let maximumDayCount = 3660

    case rolling(pastDays: Int = 7, futureDays: Int = 90, timeZoneIdentifier: String = TimeZone.current.identifier)
    case fixed(start: Date, endExclusive: Date, timeZoneIdentifier: String = TimeZone.current.identifier)

    var timeZoneIdentifier: String {
        switch self {
        case .rolling(_, _, let identifier), .fixed(_, _, let identifier): return identifier
        }
    }

    /// Rolling ranges include today, the preceding `pastDays`, and the following `futureDays`.
    func dateInterval(now: Date = Date()) throws -> DateInterval {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw SharedCalendarModelError.invalidTimeZone(timeZoneIdentifier)
        }
        switch self {
        case .rolling(let pastDays, let futureDays, _):
            guard pastDays >= 0, futureDays >= 0, now.timeIntervalSinceReferenceDate.isFinite else {
                throw SharedCalendarModelError.invalidRange
            }
            // Check before addition/negation so even Int.max input cannot overflow.
            guard pastDays < Self.maximumDayCount, futureDays < Self.maximumDayCount,
                  futureDays <= Self.maximumDayCount - 1 - pastDays else {
                throw SharedCalendarModelError.rangeTooLarge
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -pastDays, to: today),
                  let end = calendar.date(byAdding: .day, value: futureDays + 1, to: today), start < end else {
                throw SharedCalendarModelError.invalidRange
            }
            return DateInterval(start: start, end: end)
        case .fixed(let start, let end, _):
            guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                  start < end else { throw SharedCalendarModelError.invalidRange }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard let maximumEnd = calendar.date(byAdding: .day, value: Self.maximumDayCount,
                                                  to: calendar.startOfDay(for: start)), end <= maximumEnd else {
                throw SharedCalendarModelError.rangeTooLarge
            }
            return DateInterval(start: start, end: end)
        }
    }
}

struct SharedCalendarProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sourceCalendarIDs: Set<String>
    var targetSourceID: String
    var targetCalendarID: String?
    var privacyMode: PrivacyMode
    var range: SharedCalendarRange
    var isPaused: Bool
    var revision: Int
    var lastUpdated: Date?
    var lastError: String?
    var pendingDeletion: Bool

    init(id: UUID = UUID(), name: String, sourceCalendarIDs: Set<String>, targetSourceID: String,
         targetCalendarID: String? = nil, privacyMode: PrivacyMode = .partial,
         range: SharedCalendarRange = .rolling(), isPaused: Bool = false, revision: Int = 0,
         lastUpdated: Date? = nil, lastError: String? = nil, pendingDeletion: Bool = false) {
        self.id = id
        self.name = name
        self.sourceCalendarIDs = sourceCalendarIDs
        self.targetSourceID = targetSourceID
        self.targetCalendarID = targetCalendarID
        self.privacyMode = privacyMode
        self.range = range
        self.isPaused = isPaused
        self.revision = revision
        self.lastUpdated = lastUpdated
        self.lastError = lastError
        self.pendingDeletion = pendingDeletion
    }
}

enum SharedVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case excluded, opaque, partial, full
    var id: String { rawValue }

    init(privacyMode: PrivacyMode) {
        switch privacyMode {
        case .opaque: self = .opaque
        case .partial: self = .partial
        case .full: self = .full
        }
    }

    var privacyMode: PrivacyMode? {
        switch self {
        case .excluded: return nil
        case .opaque: return .opaque
        case .partial: return .partial
        case .full: return .full
        }
    }
}

/// An in-memory read snapshot. This complete source content is never persisted by the repository.
struct SourceEventSnapshot: Equatable, Sendable {
    var calendarID: String
    var calendarItemIdentifier: String
    var eventIdentifier: String?
    var externalIdentifier: String?
    var occurrenceDate: Date?
    var isRecurring: Bool
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?
    var isAllDay: Bool
    var timeZoneIdentifier: String?
    /// EventKit represents floating dates in the default zone at the time of the read.
    var readTimeZoneIdentifier: String
    var availability: CalendarEvent.Availability

    init(calendarID: String, calendarItemIdentifier: String, eventIdentifier: String? = nil,
         externalIdentifier: String? = nil, occurrenceDate: Date? = nil, isRecurring: Bool = false,
         title: String, startDate: Date, endDate: Date, location: String? = nil, notes: String? = nil,
         isAllDay: Bool = false, timeZoneIdentifier: String? = nil,
         readTimeZoneIdentifier: String = TimeZone.current.identifier,
         availability: CalendarEvent.Availability = .busy) {
        self.calendarID = calendarID
        self.calendarItemIdentifier = calendarItemIdentifier
        self.eventIdentifier = eventIdentifier
        self.externalIdentifier = externalIdentifier
        self.occurrenceDate = occurrenceDate
        self.isRecurring = isRecurring
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.readTimeZoneIdentifier = readTimeZoneIdentifier
        self.availability = availability
    }

    func occurrenceKey() throws -> String? {
        guard isRecurring else { return nil }
        guard let occurrenceDate else { throw SharedCalendarModelError.missingOccurrenceDate }
        if isAllDay || timeZoneIdentifier == nil {
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(identifier: readTimeZoneIdentifier) else {
                throw SharedCalendarModelError.invalidTimeZone(readTimeZoneIdentifier)
            }
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: occurrenceDate)
            guard let year = parts.year, let month = parts.month, let day = parts.day else {
                throw SharedCalendarModelError.missingOccurrenceDate
            }
            if isAllDay { return String(format: "day:%04d-%02d-%02d", year, month, day) }
            guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
                throw SharedCalendarModelError.missingOccurrenceDate
            }
            return String(format: "floating:%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
        }
        return "instant:\(Int64((occurrenceDate.timeIntervalSince1970 * 1_000).rounded()))"
    }
}

/// Only fields which have passed the visibility policy can reach an EventKit writer.
struct PublishedEvent: Codable, Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?
    var isAllDay: Bool
    var timeZoneIdentifier: String?
    var availability: CalendarEvent.Availability

    init?(source: SourceEventSnapshot, visibility: SharedVisibility) {
        guard visibility != .excluded else { return nil }
        title = visibility == .opaque ? source.availability.localizedName : source.title
        startDate = source.startDate
        endDate = source.endDate
        location = visibility == .full ? source.location : nil
        notes = visibility == .full ? source.notes : nil
        isAllDay = source.isAllDay
        timeZoneIdentifier = source.timeZoneIdentifier
        availability = source.availability
    }
}

struct SourceIdentity: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var calendarID: String
    var calendarItemIdentifiers: Set<String>
    var eventIdentifiers: Set<String>
    var externalIdentifier: String?
    var isRecurring: Bool

    init(id: UUID = UUID(), calendarID: String, calendarItemIdentifiers: Set<String> = [],
         eventIdentifiers: Set<String> = [], externalIdentifier: String? = nil, isRecurring: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.calendarItemIdentifiers = calendarItemIdentifiers
        self.eventIdentifiers = eventIdentifiers
        self.externalIdentifier = externalIdentifier
        self.isRecurring = isRecurring
    }
}

struct SourceInstanceKey: Codable, Hashable, Sendable {
    var sourceIdentityID: UUID
    var occurrenceKey: String?
    var seriesID: UUID { sourceIdentityID }
    init(sourceIdentityID: UUID, occurrenceKey: String? = nil) {
        self.sourceIdentityID = sourceIdentityID
        self.occurrenceKey = occurrenceKey
    }
}

enum SharedVisibilityScope: String, Codable, Sendable { case occurrence, series }

struct SharedVisibilityOverride: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var profileID: UUID
    var sourceIdentityID: UUID
    var occurrenceKey: String?
    var visibility: SharedVisibility

    init(id: UUID = UUID(), profileID: UUID, sourceIdentityID: UUID, occurrenceKey: String? = nil,
         visibility: SharedVisibility) {
        self.id = id
        self.profileID = profileID
        self.sourceIdentityID = sourceIdentityID
        self.occurrenceKey = occurrenceKey
        self.visibility = visibility
    }
}

struct MirrorMapping: Codable, Identifiable, Equatable, Sendable {
    var profileID: UUID
    var sourceKey: SourceInstanceKey
    var mirrorID: UUID
    var targetEventID: String?
    var targetExternalIdentifier: String?
    var lastStart: Date?
    var lastEnd: Date?
    var fingerprint: String?
    var id: UUID { mirrorID }

    init(profileID: UUID, sourceKey: SourceInstanceKey, mirrorID: UUID = UUID(),
         targetEventID: String? = nil, targetExternalIdentifier: String? = nil,
         lastStart: Date? = nil, lastEnd: Date? = nil, fingerprint: String? = nil) {
        self.profileID = profileID
        self.sourceKey = sourceKey
        self.mirrorID = mirrorID
        self.targetEventID = targetEventID
        self.targetExternalIdentifier = targetExternalIdentifier
        self.lastStart = lastStart
        self.lastEnd = lastEnd
        self.fingerprint = fingerprint
    }

    /// This public URL deliberately contains no source IDs or profile IDs.
    var markerURL: URL { URL(string: "chronograph://mirror/v1/\(mirrorID.uuidString.lowercased())")! }

    static func mirrorID(from url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == "chronograph", url.host?.lowercased() == "mirror",
              url.query == nil, url.fragment == nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, components[0] == "v1" else { return nil }
        return UUID(uuidString: components[1])
    }
}

struct MirrorOperation: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case createCalendar, upsert, deleteEvent, deleteCalendar }
    var id: UUID
    var profileID: UUID
    var mappingID: UUID?
    var kind: Kind
    var startedAt: Date
    var targetCalendarID: String?
    var targetSourceID: String?
    var targetName: String?

    init(id: UUID = UUID(), profileID: UUID, mappingID: UUID? = nil, kind: Kind,
         startedAt: Date = Date(), targetCalendarID: String? = nil,
         targetSourceID: String? = nil, targetName: String? = nil) {
        self.id = id
        self.profileID = profileID
        self.mappingID = mappingID
        self.kind = kind
        self.startedAt = startedAt
        self.targetCalendarID = targetCalendarID
        self.targetSourceID = targetSourceID
        self.targetName = targetName
    }
}

struct SharedCalendarState: Codable, Equatable, Sendable {
    var profiles: [SharedCalendarProfile]
    var identities: [SourceIdentity]
    var overrides: [SharedVisibilityOverride]
    var mappings: [MirrorMapping]
    var operations: [MirrorOperation]

    init(profiles: [SharedCalendarProfile] = [], identities: [SourceIdentity] = [],
         overrides: [SharedVisibilityOverride] = [], mappings: [MirrorMapping] = [],
         operations: [MirrorOperation] = []) {
        self.profiles = profiles
        self.identities = identities
        self.overrides = overrides
        self.mappings = mappings
        self.operations = operations
    }

    /// Resolve a whole fresh read together so duplicate external IDs cannot silently merge events.
    mutating func resolveIdentities(for snapshots: [SourceEventSnapshot]) throws -> [SourceInstanceKey] {
        struct ExternalKey: Hashable { var calendarID: String; var externalID: String; var occurrence: String? }
        var seen: [ExternalKey: SourceEventSnapshot] = [:]
        for source in snapshots {
            guard let externalID = source.externalIdentifier, !externalID.isEmpty else { continue }
            let key = ExternalKey(calendarID: source.calendarID, externalID: externalID,
                                  occurrence: try source.occurrenceKey())
            if let previous = seen[key], previous.calendarItemIdentifier != source.calendarItemIdentifier ||
                previous.eventIdentifier != source.eventIdentifier {
                throw SharedCalendarModelError.ambiguousExternalIdentifier(externalID)
            }
            seen[key] = source
        }
        // Identity changes are atomic even if a later event is ambiguous.
        var candidate = self
        let result = try snapshots.map { try candidate.resolveIdentity(for: $0) }
        identities = candidate.identities
        return result
    }

    mutating func resolveIdentity(for source: SourceEventSnapshot) throws -> SourceInstanceKey {
        let occurrence = try source.occurrenceKey()
        let sameCalendar = identities.indices.filter { identities[$0].calendarID == source.calendarID }
        let aliasMatches = sameCalendar.filter { index in
            let identity = identities[index]
            return (!source.calendarItemIdentifier.isEmpty && identity.calendarItemIdentifiers.contains(source.calendarItemIdentifier)) ||
                source.eventIdentifier.map { identity.eventIdentifiers.contains($0) } == true
        }
        guard aliasMatches.count <= 1 else { throw SharedCalendarModelError.ambiguousIdentity }
        let externalMatches = sameCalendar.filter {
            guard let external = source.externalIdentifier, !external.isEmpty else { return false }
            return identities[$0].externalIdentifier == external && identities[$0].isRecurring == source.isRecurring
        }
        guard externalMatches.count <= 1 else {
            throw SharedCalendarModelError.ambiguousExternalIdentifier(source.externalIdentifier ?? "")
        }
        if let alias = aliasMatches.first, let external = externalMatches.first, alias != external {
            throw SharedCalendarModelError.ambiguousIdentity
        }
        let index: Int
        if let found = aliasMatches.first ?? externalMatches.first {
            // A series becoming a standalone event (or the reverse) invalidates occurrence overrides.
            // Pause instead of silently falling back to a potentially more revealing default.
            guard identities[found].isRecurring == source.isRecurring else {
                throw SharedCalendarModelError.ambiguousIdentity
            }
            index = found
        } else {
            identities.append(SourceIdentity(calendarID: source.calendarID, isRecurring: source.isRecurring))
            index = identities.count - 1
        }
        if !source.calendarItemIdentifier.isEmpty { identities[index].calendarItemIdentifiers.insert(source.calendarItemIdentifier) }
        if let eventID = source.eventIdentifier, !eventID.isEmpty { identities[index].eventIdentifiers.insert(eventID) }
        if let externalID = source.externalIdentifier, !externalID.isEmpty { identities[index].externalIdentifier = externalID }
        identities[index].isRecurring = source.isRecurring
        return SourceInstanceKey(sourceIdentityID: identities[index].id, occurrenceKey: occurrence)
    }

    func visibility(profileID: UUID, sourceKey: SourceInstanceKey, defaultMode: PrivacyMode) -> SharedVisibility {
        let candidates = overrides.filter { $0.profileID == profileID && $0.sourceIdentityID == sourceKey.sourceIdentityID }
        if let occurrence = sourceKey.occurrenceKey,
           let value = candidates.last(where: { $0.occurrenceKey == occurrence }) { return value.visibility }
        return candidates.last(where: { $0.occurrenceKey == nil })?.visibility ?? SharedVisibility(privacyMode: defaultMode)
    }

    mutating func setVisibility(_ value: SharedVisibility?, profileID: UUID, sourceKey: SourceInstanceKey,
                                scope: SharedVisibilityScope = .occurrence) {
        let occurrence = scope == .series ? nil : sourceKey.occurrenceKey
        overrides.removeAll { $0.profileID == profileID && $0.sourceIdentityID == sourceKey.sourceIdentityID && $0.occurrenceKey == occurrence }
        if let value {
            overrides.append(SharedVisibilityOverride(profileID: profileID, sourceIdentityID: sourceKey.sourceIdentityID,
                                                      occurrenceKey: occurrence, visibility: value))
        }
    }
}
