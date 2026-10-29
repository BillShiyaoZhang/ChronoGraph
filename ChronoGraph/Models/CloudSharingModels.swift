import Foundation

/// A user-facing outgoing configuration. Source event text is deliberately absent from persisted drafts.
struct CloudSharingDraft: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var calendarIDs: Set<String>
    var defaultVisibility: SharedVisibility
    var range: SharedCalendarRange
    var ruleState: SharedCalendarState
    var baseRevision: Int
    var baseGeneration: Int?
    /// Migrated single-calendar output keeps its existing wire event IDs.
    var legacyCalendarID: String?

    init(id: UUID = UUID(), name: String = "", calendarIDs: Set<String> = [], defaultVisibility: SharedVisibility = .opaque,
         range: SharedCalendarRange = .rolling(), ruleState: SharedCalendarState = SharedCalendarState(),
         baseRevision: Int = 0, baseGeneration: Int? = nil, legacyCalendarID: String? = nil) {
        self.id = id; self.name = name; self.calendarIDs = calendarIDs; self.defaultVisibility = defaultVisibility
        self.range = range; self.ruleState = ruleState; self.baseRevision = baseRevision
        self.baseGeneration = baseGeneration; self.legacyCalendarID = legacyCalendarID
    }
    var uploadLevel: CloudUploadLevel { CloudSharingPolicy.uploadLevel(for: self) }
}

/// Raw event text exists only in this in-memory review, never in the durable configuration.
struct CloudSharingPreview: Identifiable, Sendable {
    let draft: CloudSharingDraft
    let events: [SharedEventPreview]
    let reviewID: UUID
    let interval: DateInterval
    var id: UUID { reviewID }
    var excludedCount: Int { events.filter { $0.visibility == .excluded }.count }
}

enum CloudSharingError: Error, LocalizedError {
    case invalidName, noCalendars, reviewExpired, busy, unavailableCalendar, tooManyEvents
    var errorDescription: String? {
        switch self {
        case .invalidName: return CloudCopy.text("请输入1至120个字符的共享日历名称。")
        case .noCalendars: return CloudCopy.text("请至少选择一份本机来源日历。")
        case .reviewExpired: return CloudCopy.text("共享配置或日期已变更，请重新预览并审阅后再确认。")
        case .busy: return CloudCopy.text("正在处理其他操作，请稍后重试。")
        case .unavailableCalendar: return CloudCopy.text("部分来源日历无法完整读取，尚未更新云端共享。请检查权限和来源。")
        case .tooManyEvents: return CloudCopy.text("共享内容超过20000条日程，请缩小日期范围或减少来源后重新审阅。")
        }
    }
}

enum CloudSharingPolicy {
    static func visibility(draft: CloudSharingDraft, key: SourceInstanceKey) -> SharedVisibility {
        let values = draft.ruleState.overrides.filter { $0.profileID == draft.id && $0.sourceIdentityID == key.sourceIdentityID }
        if let occurrence = key.occurrenceKey, let single = values.last(where: { $0.occurrenceKey == occurrence }) { return single.visibility }
        return values.last(where: { $0.occurrenceKey == nil })?.visibility ?? draft.defaultVisibility
    }
    static func uploadLevel(for draft: CloudSharingDraft) -> CloudUploadLevel {
        let identities = Set(draft.ruleState.identities.filter { draft.calendarIDs.contains($0.calendarID) }.map(\.id))
        let levels = [draft.defaultVisibility] + draft.ruleState.overrides.filter {
            $0.profileID == draft.id && identities.contains($0.sourceIdentityID)
        }.map(\.visibility)
        if levels.contains(.full) { return .full }
        if levels.contains(.partial) { return .partial }
        return .opaque
    }
    static func validate(_ draft: CloudSharingDraft) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 120 else { throw CloudSharingError.invalidName }
        guard !draft.calendarIDs.isEmpty else { throw CloudSharingError.noCalendars }
        _ = try CloudUploadScopePolicy.interval(for: draft.range)
    }
    static func preview(draft: CloudSharingDraft, snapshots: [SourceEventSnapshot], now: Date = Date(), reviewID: UUID = UUID()) throws -> CloudSharingPreview {
        try validate(draft)
        let interval = try CloudUploadScopePolicy.interval(for: draft.range, now: now)
        guard snapshots.allSatisfy({ draft.calendarIDs.contains($0.calendarID) }) else { throw CloudSharingError.unavailableCalendar }
        var resolved = draft
        // Reuse identity and override policy, without carrying iCloud writer state across services.
        resolved.ruleState.profiles = []; resolved.ruleState.mappings = []; resolved.ruleState.operations = []
        resolved.ruleState.overrides.removeAll { $0.profileID != draft.id }
        let originals = snapshots.filter { $0.startDate < interval.end && $0.endDate > interval.start }
        if originals.count > 20_000, resolved.defaultVisibility != .excluded,
           !resolved.ruleState.overrides.contains(where: { $0.profileID == draft.id && $0.visibility == .excluded }) {
            throw CloudSharingError.tooManyEvents
        }
        let keys = try resolved.ruleState.resolveIdentities(for: originals)
        var events: [SharedEventPreview] = []
        for index in originals.indices {
            let source: SourceEventSnapshot = originals[index]
            let key: SourceInstanceKey = keys[index]
            let chosen: SharedVisibility = Self.visibility(draft: resolved, key: key)
            let rules: [SharedVisibilityOverride] = resolved.ruleState.overrides.filter {
                $0.profileID == draft.id && $0.sourceIdentityID == key.sourceIdentityID
            }
            let occurrenceOverride: SharedVisibility? = rules.last(where: { $0.occurrenceKey == key.occurrenceKey })?.visibility
            let seriesOverride: SharedVisibility? = rules.last(where: { $0.occurrenceKey == nil })?.visibility
            let published = PublishedEvent(source: source, visibility: chosen)
            let event = SharedEventPreview(id: "\(key.sourceIdentityID)|\(key.occurrenceKey ?? "single")", identityID: key.sourceIdentityID,
                occurrenceKey: key.occurrenceKey, isRecurring: source.isRecurring, title: source.title,
                startDate: source.startDate, endDate: source.endDate, isAllDay: source.isAllDay, visibility: chosen,
                override: occurrenceOverride, seriesOverride: seriesOverride, published: published, source: source,
                defaultPrivacyMode: resolved.defaultVisibility.privacyMode ?? .opaque,
                membership: chosen == .excluded ? .excluded : .confirmed)
            events.append(event)
        }
        events.sort {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
        return CloudSharingPreview(draft: resolved, events: events, reviewID: reviewID, interval: interval)
    }
    static func project(_ preview: CloudSharingPreview, key: Data) throws -> [CloudBusyEvent] {
        guard preview.events.filter({ $0.visibility != .excluded }).count <= 20_000 else { throw CloudSharingError.tooManyEvents }
        return try preview.events.compactMap { event in
            guard event.visibility != .excluded else { return nil }
            guard let source = event.source, let level = CloudUploadLevel(rawValue: event.visibility.rawValue) else { throw CloudClientError.invalidResponse }
            let namespace: String?
            if source.calendarID == preview.draft.legacyCalendarID { namespace = nil }
            else { namespace = "v2|\(preview.draft.id.uuidString)|\(source.calendarID.utf8.count):\(source.calendarID)|\(event.identityID.uuidString)" }
            return try CloudSnapshotProjection.project(source, sourceID: preview.draft.id, level: level, key: key, identityNamespace: namespace)
        }
    }
}

/// Session-bound, memory-only authorization for one exact review.
struct CloudSharingReviewRecord {
    let preview: CloudSharingPreview
    let scope: String
    let token: String
}
