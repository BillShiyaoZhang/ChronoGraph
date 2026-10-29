import Foundation
import Testing
@testable import ChronoGraph

struct CloudSharingPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_793_232_000)
    private var range: SharedCalendarRange { .fixed(start: now, endExclusive: now.addingTimeInterval(7 * 86_400), timeZoneIdentifier: "UTC") }
    private func event(calendar: String = "work", item: String = "same-item", day: Int = 1, recurring: Bool = false) -> SourceEventSnapshot {
        let start = now.addingTimeInterval(Double(day * 86_400 + 3600))
        return SourceEventSnapshot(calendarID: calendar, calendarItemIdentifier: item, eventIdentifier: item + ".event",
            externalIdentifier: item + ".external", occurrenceDate: recurring ? start : nil, isRecurring: recurring,
            title: "PRIVATE TITLE", startDate: start, endDate: start.addingTimeInterval(1800),
            location: "PRIVATE LOCATION", notes: "PRIVATE NOTES", timeZoneIdentifier: "UTC", readTimeZoneIdentifier: "UTC")
    }
    @Test func occurrenceSeriesAndDefaultRulesShareTheExistingPriority() throws {
        let first = event(recurring: true), second = event(day: 2, recurring: true)
        let draft = CloudSharingDraft(name: "Combined", calendarIDs: ["work"], defaultVisibility: .partial, range: range)
        var preview = try CloudSharingPolicy.preview(draft: draft, snapshots: [first, second], now: now)
        var changed = preview.draft
        let firstKey = SourceInstanceKey(sourceIdentityID: preview.events[0].identityID, occurrenceKey: preview.events[0].occurrenceKey)
        changed.ruleState.setVisibility(.excluded, profileID: changed.id, sourceKey: firstKey, scope: .series)
        changed.ruleState.setVisibility(.full, profileID: changed.id, sourceKey: firstKey, scope: .occurrence)
        preview = try CloudSharingPolicy.preview(draft: changed, snapshots: [first, second], now: now)
        #expect(preview.events[0].visibility == .full)
        #expect(preview.events[1].visibility == .excluded)
        #expect(preview.draft.uploadLevel == .full)
        let wire = try CloudSharingPolicy.project(preview, key: Data(repeating: 3, count: 32))
        #expect(wire.count == 1)
        #expect(wire[0].visibility == .full)
        #expect(wire[0].notes == "PRIVATE NOTES")
    }
    @Test func aFullOverrideDoesNotRevealOtherOpaqueEvents() throws {
        let events = [event(item: "one"), event(item: "two")]
        let draft = CloudSharingDraft(name: "Mixed", calendarIDs: ["work"], defaultVisibility: .opaque, range: range)
        let reviewed = try CloudSharingPolicy.preview(draft: draft, snapshots: events, now: now)
        var changed = reviewed.draft
        let target = reviewed.events.first!
        changed.ruleState.setVisibility(.full, profileID: changed.id,
            sourceKey: SourceInstanceKey(sourceIdentityID: target.identityID, occurrenceKey: target.occurrenceKey))
        let preview = try CloudSharingPolicy.preview(draft: changed, snapshots: events, now: now)
        let wire = try CloudSharingPolicy.project(preview, key: Data(repeating: 2, count: 32))
        #expect(preview.draft.uploadLevel == .full)
        #expect(wire.filter { $0.visibility == .full }.count == 1)
        let hidden = try #require(wire.first { $0.visibility == .opaque })
        #expect(hidden.title == nil && hidden.location == nil && hidden.notes == nil)
    }
    @Test func duplicateIdentifiersAcrossCalendarsCannotCollideOrShareRules() throws {
        let draft = CloudSharingDraft(name: "Combined", calendarIDs: ["work", "personal"], defaultVisibility: .partial, range: range)
        let originals = [event(calendar: "work"), event(calendar: "personal")]
        let preview = try CloudSharingPolicy.preview(draft: draft, snapshots: originals, now: now)
        #expect(Set(preview.events.map(\.identityID)).count == 2)
        let wire = try CloudSharingPolicy.project(preview, key: Data(repeating: 8, count: 32))
        #expect(Set(wire.map(\.id)).count == 2)
        var changed = preview.draft
        let work = try #require(preview.events.first { $0.source?.calendarID == "work" })
        changed.ruleState.setVisibility(.excluded, profileID: changed.id,
            sourceKey: SourceInstanceKey(sourceIdentityID: work.identityID, occurrenceKey: work.occurrenceKey))
        let updated = try CloudSharingPolicy.preview(draft: changed, snapshots: originals, now: now)
        #expect(updated.events.first { $0.source?.calendarID == "personal" }?.visibility == .partial)
        #expect(try CloudSharingPolicy.project(updated, key: Data(repeating: 8, count: 32)).count == 1)
    }
    @Test func legacyCalendarKeepsExistingWireIdsWhenAnotherCalendarIsAdded() throws {
        let id = UUID(), key = Data(repeating: 9, count: 32), work = event(calendar: "work")
        let original = try CloudSnapshotProjection.project(work, sourceID: id, level: .partial, key: key)
        let draft = CloudSharingDraft(id: id, name: "Migrated", calendarIDs: ["work", "personal"], defaultVisibility: .partial,
                                     range: range, legacyCalendarID: "work")
        let preview = try CloudSharingPolicy.preview(draft: draft, snapshots: [work, event(calendar: "personal")], now: now)
        let wire = try CloudSharingPolicy.project(preview, key: key)
        #expect(wire.contains { $0.id == original.id })
        #expect(Set(wire.map(\.id)).count == 2)
    }
    @Test func aliasesRetainRulesAndNewConfigurationIdsForTheSameEvent() throws {
        let draft = CloudSharingDraft(name: "Stable", calendarIDs: ["work"], defaultVisibility: .full, range: range)
        let original = event()
        let first = try CloudSharingPolicy.preview(draft: draft, snapshots: [original], now: now)
        var configured = first.draft
        configured.ruleState.setVisibility(.opaque, profileID: configured.id,
            sourceKey: SourceInstanceKey(sourceIdentityID: first.events[0].identityID))
        var changed = original
        changed.calendarItemIdentifier = "changed-system-alias"; changed.eventIdentifier = "changed-event-alias"
        let before = try CloudSharingPolicy.preview(draft: configured, snapshots: [original], now: now)
        let after = try CloudSharingPolicy.preview(draft: before.draft, snapshots: [changed], now: now)
        #expect(after.events[0].visibility == .opaque)
        #expect(after.events[0].identityID == before.events[0].identityID)
        #expect(try CloudSharingPolicy.project(before, key: Data(repeating: 1, count: 32)).map(\.id) == CloudSharingPolicy.project(after, key: Data(repeating: 1, count: 32)).map(\.id))
    }
    @Test func rulesRemainIsolatedBetweenConfigurationsUsingTheSameCalendar() throws {
        let first = try CloudSharingPolicy.preview(draft: CloudSharingDraft(name: "A", calendarIDs: ["work"], defaultVisibility: .full, range: range), snapshots: [event()], now: now)
        var state = first.draft.ruleState
        state.setVisibility(.excluded, profileID: first.draft.id, sourceKey: SourceInstanceKey(sourceIdentityID: first.events[0].identityID))
        let second = CloudSharingDraft(name: "B", calendarIDs: ["work"], defaultVisibility: .partial, range: range, ruleState: state)
        let preview = try CloudSharingPolicy.preview(draft: second, snapshots: [event()], now: now)
        #expect(preview.events[0].visibility == .partial)
        #expect(preview.draft.ruleState.overrides.isEmpty)
        #expect(preview.draft.uploadLevel == .partial)
    }
    @Test func persistedConfigurationContainsNoOriginalEventText() throws {
        let preview = try CloudSharingPolicy.preview(draft: CloudSharingDraft(name: "Metadata", calendarIDs: ["work"], range: range), snapshots: [event()], now: now)
        let data = try JSONEncoder().encode(preview.draft)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("PRIVATE TITLE") && !text.contains("PRIVATE LOCATION") && !text.contains("PRIVATE NOTES"))
        #expect(try JSONDecoder().decode(CloudSharingDraft.self, from: data) == preview.draft)
    }
    @Test func mergedUploadLimitIsCheckedBeforeConfirmation() throws {
        let draft = CloudSharingDraft(name: "Too large", calendarIDs: ["work"], defaultVisibility: .opaque, range: range)
        let seed = event()
        let originals = (0...20_000).map { index -> SourceEventSnapshot in
            var value = seed; value.calendarItemIdentifier = "item-\(index)"; value.eventIdentifier = nil; value.externalIdentifier = nil; return value
        }
        #expect(throws: CloudSharingError.self) { try CloudSharingPolicy.preview(draft: draft, snapshots: originals, now: now) }
    }
}

@MainActor
struct CloudSharingManagerTests {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let device = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let seedID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private func source(id: UUID, name: String, level: CloudUploadLevel, generation: Int, interval: DateInterval? = nil) -> CloudSource {
        CloudSource(id: id, ownerId: account, deviceId: device, name: name, uploadLevel: level, generation: generation,
                    coverageStart: interval?.start, coverageEnd: interval?.end, lastSyncedAt: interval == nil ? nil : Date())
    }
    private func event(calendar: String = "work", title: String = "REVIEWED TITLE") -> SourceEventSnapshot {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(36_000)
        return SourceEventSnapshot(calendarID: calendar, calendarItemIdentifier: "item", title: title,
            startDate: start, endDate: start.addingTimeInterval(1800), notes: "PRIVATE ORIGINAL NOTES", timeZoneIdentifier: "UTC")
    }
    private func session() -> CloudSession {
        CloudSession(accessToken: "synthetic-only", tokenType: "bearer", expiresAt: .distantFuture,
                     user: CloudUser(id: account, displayName: "Test"), deviceId: device, authProvider: "password")
    }
    @Test func previewAndAnyFailedSourceReadNeverWriteOrStagePendingRules() async throws {
        var creates = 0, snapshots = 0
        let seed = source(id: seedID, name: "Seed", level: .opaque, generation: 1)
        let manager = CloudWorkspaceManager(testingSession: session(), source: seed,
            binding: CloudLocalBinding(sourceId: seedID, calendarId: "seed", uploadLevel: .opaque), defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in seed }, snapshotUploader: { _, source in source },
            sourceCreator: { _, _, _ in creates += 1; return seed }, sharingEventReader: { ids, _ in
                #expect(ids == ["work", "unavailable"])
                _ = self.event(calendar: "work")
                throw CloudSharingError.unavailableCalendar
            }, sharingSnapshotSender: { _, source, _, _ in snapshots += 1; return source })
        let draft = CloudSharingDraft(name: "Merged", calendarIDs: ["work", "unavailable"], range: .rolling(pastDays: 0, futureDays: 2))
        do { _ = try await manager.previewSharing(draft: draft); Issue.record("Expected the failed source to abort the preview") }
        catch { #expect(error is CloudSharingError) }
        #expect(creates == 0 && snapshots == 0)
        #expect(manager.bindings.allSatisfy { $0.pendingSharing == nil })
    }
    @Test func saveUsesOnlyTheFrozenReviewedEventsAndFullScopeIsDurable() async throws {
        var remote: [UUID: CloudSource] = [:]
        var reads = 0, writes = 0
        var liveTitle = "REVIEWED TITLE"
        var uploaded: [CloudBusyEvent] = []
        let seed = source(id: seedID, name: "Seed", level: .opaque, generation: 1)
        let manager = CloudWorkspaceManager(testingSession: session(), source: seed,
            binding: CloudLocalBinding(sourceId: seedID, calendarId: "seed", uploadLevel: .opaque), defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in seed }, snapshotUploader: { _, source in source }, sourceMetadataReader: { id in remote[id] },
            sourceCreator: { id, calendar, level in
                writes += 1
                let value = self.source(id: id, name: calendar.title, level: level, generation: 0); remote[id] = value; return value
            }, sharingEventReader: { ids, _ in reads += 1; return ids.sorted().map { self.event(calendar: $0, title: liveTitle) } },
            sharingSnapshotSender: { binding, source, events, interval in
                uploaded = events
                let value = self.source(id: source.id, name: source.name, level: source.uploadLevel, generation: 1, interval: interval)
                remote[source.id] = value
                #expect(binding.pendingSharing?.calendarIDs == ["work", "personal"])
                return value
            })
        let draft = CloudSharingDraft(name: "Combined", calendarIDs: ["work", "personal"], defaultVisibility: .partial, range: .rolling(pastDays: 0, futureDays: 2))
        let preview = try await manager.previewSharing(draft: draft)
        #expect(writes == 0)
        liveTitle = "NOT REVIEWED NEW TITLE"
        let saved = await manager.saveSharing(preview: preview)
        #expect(saved?.name == "Combined")
        #expect(reads == 1 && writes == 1)
        #expect(uploaded.count == 2)
        #expect(uploaded.allSatisfy { $0.title == "REVIEWED TITLE" && $0.notes == nil && $0.visibility == .partial })
        let binding = try #require(manager.bindings.first { $0.sourceId == draft.id })
        #expect(binding.sharing?.calendarIDs == ["work", "personal"])
        #expect(binding.pendingSharing == nil)
        let text = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
        #expect(!text.contains("REVIEWED TITLE") && !text.contains("PRIVATE ORIGINAL NOTES"))
    }
    @Test func modifyingRulesAfterReviewCannotConfirmAnUnreviewedWiderDefault() async throws {
        var writes = 0
        let seed = source(id: seedID, name: "Seed", level: .opaque, generation: 1)
        let manager = CloudWorkspaceManager(testingSession: session(), source: seed,
            binding: CloudLocalBinding(sourceId: seedID, calendarId: "seed", uploadLevel: .opaque), defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in seed }, snapshotUploader: { _, source in source },
            sourceCreator: { _, _, _ in writes += 1; return seed }, sharingEventReader: { _, _ in [self.event()] })
        let preview = try await manager.previewSharing(draft: CloudSharingDraft(name: "Hidden", calendarIDs: ["work"], range: .rolling(pastDays: 0, futureDays: 2)))
        var changed = preview.draft; changed.defaultVisibility = .full
        let forged = CloudSharingPreview(draft: changed, events: preview.events, reviewID: preview.reviewID, interval: preview.interval)
        #expect(await manager.saveSharing(preview: forged) == nil)
        #expect(writes == 0)
        #expect(manager.bindings.allSatisfy { $0.pendingSharing == nil })
    }
    @Test func unknownCreationPersistsTheWholeConfigurationAndRestoresItsUUIDAfterRestart() async throws {
        var remote: CloudSource?
        var creations = 0, snapshots = 0
        let seed = source(id: seedID, name: "Seed", level: .opaque, generation: 1)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = CloudWorkspaceManager(testingSession: session(), source: seed,
            binding: CloudLocalBinding(sourceId: seedID, calendarId: "seed", uploadLevel: .opaque), defaults: defaults,
            sourceUpdater: { _, _ in seed }, snapshotUploader: { _, source in source }, sourceMetadataReader: { id in remote?.id == id ? remote : nil },
            sourceCreator: { id, calendar, level in
                creations += 1; remote = self.source(id: id, name: calendar.title, level: level, generation: 0)
                throw URLError(.networkConnectionLost)
            }, sharingEventReader: { ids, _ in ids.sorted().map { self.event(calendar: $0) } })
        let initial = try await first.previewSharing(draft: CloudSharingDraft(name: "Durable combined", calendarIDs: ["work", "personal"], defaultVisibility: .partial, range: .rolling(pastDays: 0, futureDays: 2)))
        var edited = initial.draft
        let hidden = try #require(initial.events.first { $0.source?.calendarID == "work" })
        edited.ruleState.setVisibility(.excluded, profileID: edited.id,
            sourceKey: SourceInstanceKey(sourceIdentityID: hidden.identityID, occurrenceKey: hidden.occurrenceKey))
        let reviewed = try await first.previewSharing(draft: edited)
        #expect(await first.saveSharing(preview: reviewed) == nil)
        let pending = try #require(first.bindings.first { $0.sourceId == edited.id })
        #expect(first.pendingSharingDrafts.map(\.id) == [edited.id])
        #expect(pending.pendingSharing?.calendarIDs == ["work", "personal"])
        #expect(pending.pendingSharing?.ruleState.overrides.count == 1)
        let restored = try JSONDecoder().decode(CloudLocalBinding.self, from: JSONEncoder().encode(pending))
        let server = try #require(remote)
        let restarted = CloudWorkspaceManager(testingSession: session(), source: server, binding: restored, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in server }, snapshotUploader: { _, source in source }, sourceMetadataReader: { id in remote?.id == id ? remote : nil },
            sourceCreator: { _, _, _ in creations += 1; return server }, sharingEventReader: { ids, _ in ids.sorted().map { self.event(calendar: $0) } },
            sharingSnapshotSender: { _, source, events, interval in
                snapshots += 1
                #expect(events.count == 1 && events[0].visibility == .partial)
                let value = self.source(id: source.id, name: source.name, level: source.uploadLevel, generation: 1, interval: interval)
                remote = value; return value
            })
        let recoveredDraft = try restarted.makeSharingDraft(sourceID: edited.id)
        #expect(recoveredDraft.id == edited.id && recoveredDraft.ruleState.overrides.count == 1)
        let recoveredReview = try await restarted.previewSharing(draft: recoveredDraft)
        let saved = await restarted.saveSharing(preview: recoveredReview)
        #expect(saved?.id == edited.id)
        #expect(creations == 1 && snapshots == 1)
        #expect(restarted.bindings.count == 1)
        #expect(restarted.pendingSharingDrafts.isEmpty)
    }

    @Test func failedSourceDuringAutomaticConfigurationReadNeverPublishesPartialCoverage() async {
        let draft = CloudSharingDraft(id: seedID, name: "Existing merged", calendarIDs: ["work", "unavailable"], defaultVisibility: .partial,
                                      range: .rolling(pastDays: 0, futureDays: 2))
        let interval = try! draft.range.dateInterval()
        let existing = source(id: seedID, name: draft.name, level: .partial, generation: 2, interval: interval)
        let binding = CloudLocalBinding(sourceId: seedID, calendarId: "work", uploadLevel: .partial,
                                        calendarIds: draft.calendarIDs, sharing: draft, sharingRevision: 1)
        var uploads = 0
        let manager = CloudWorkspaceManager(testingSession: session(), source: existing, binding: binding, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in existing }, snapshotUploader: { _, source in uploads += 1; return source }, sourceMetadataReader: { _ in existing },
            sharingEventReader: { ids, _ in
                #expect(ids == ["work", "unavailable"])
                _ = self.event(calendar: "work")
                throw CloudSharingError.unavailableCalendar
            }, sharingSnapshotSender: { _, source, _, _ in uploads += 1; return source })
        await manager.sync()
        #expect(uploads == 0)
        #expect(manager.bindings.first?.sharing == draft)
        #expect(manager.bindings.first?.pendingSharing == nil)
        #expect(manager.sources.first?.generation == 2)
        #expect(manager.errorMessage != nil)
    }
    @Test func oneLocalCalendarCanBackTwoIndependentlyNamedConfigurations() async throws {
        var remote: [UUID: CloudSource] = [:]
        var uploaded: [UUID: [CloudBusyEvent]] = [:]
        let seed = source(id: seedID, name: "Seed", level: .opaque, generation: 1)
        let manager = CloudWorkspaceManager(testingSession: session(), source: seed,
            binding: CloudLocalBinding(sourceId: seedID, calendarId: "seed", uploadLevel: .opaque), defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sourceUpdater: { _, _ in seed }, snapshotUploader: { _, source in source }, sourceMetadataReader: { id in remote[id] },
            sourceCreator: { id, calendar, level in
                let value = self.source(id: id, name: calendar.title, level: level, generation: 0); remote[id] = value; return value
            }, sharingEventReader: { _, _ in [self.event()] }, sharingSnapshotSender: { _, source, events, interval in
                uploaded[source.id] = events
                let value = self.source(id: source.id, name: source.name, level: source.uploadLevel, generation: 1, interval: interval)
                remote[source.id] = value; return value
            })
        let hidden = CloudSharingDraft(name: "Availability", calendarIDs: ["work"], defaultVisibility: .opaque, range: .rolling(pastDays: 0, futureDays: 2))
        let detailed = CloudSharingDraft(name: "Titles", calendarIDs: ["work"], defaultVisibility: .partial, range: hidden.range)
        let first = try await manager.previewSharing(draft: hidden)
        #expect(await manager.saveSharing(preview: first) != nil)
        let second = try await manager.previewSharing(draft: detailed)
        #expect(await manager.saveSharing(preview: second) != nil)
        #expect(manager.bindings.filter { $0.effectiveCalendarIDs == ["work"] }.count == 2)
        #expect(uploaded[hidden.id]?.first?.title == nil)
        #expect(uploaded[detailed.id]?.first?.title == "REVIEWED TITLE")
        #expect(uploaded[hidden.id]?.first?.id != uploaded[detailed.id]?.first?.id)
    }

}
