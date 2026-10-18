import Foundation
import Testing
@testable import ChronoGraph

private enum MockCalendarFailure: Error { case sourceUnavailable, savedThenFailed, calendarCreatedThenFailed, calendarDeleteFailed }

private actor MockCalendarStore: CalendarStore {
    private var sources: [SourceEventSnapshot]
    private var calendars: [String: String] = [:]
    private var targets: [String: [String: MirrorTargetSnapshot]] = [:]
    private var sourceFailure = false
    private var failAfterNextSave = false
    private var failAfterNextCreation = false
    private var failCalendarDeletion = false
    private var accountAvailable = true
    private var shouldBlockWrite = false
    private var blockedWrite = false
    private var writeGate: CheckedContinuation<Void, Never>?
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []
    private(set) var writeCount = 0
    private(set) var removeCount = 0
    private(set) var upsertCallCount = 0
    private(set) var removeEventCallCount = 0
    private(set) var createCount = 0
    private(set) var renameCount = 0
    private(set) var lastRequestedSourceIDs: Set<String> = []
    private(set) var writtenEventIDs: [String] = []

    init(sources: [SourceEventSnapshot]) { self.sources = sources }
    func setSources(_ value: [SourceEventSnapshot]) { sources = value }
    func failSourceReads(_ value: Bool) { sourceFailure = value }
    func failAfterSavingNextWrite() { failAfterNextSave = true }
    func resetWriteLog() { writtenEventIDs.removeAll() }
    func failAfterCreatingNextCalendar() { failAfterNextCreation = true }
    func failCalendarDeletes(_ value: Bool) { failCalendarDeletion = value }
    func setAccountAvailable(_ value: Bool) { accountAvailable = value }
    func externallyRemoveCalendar(_ id: String) {
        calendars.removeValue(forKey: id)
        targets.removeValue(forKey: id)
    }
    func removeMarker(eventID: String, calendarID: String) {
        guard let event = targets[calendarID]?[eventID] else { return }
        targets[calendarID]?[eventID] = MirrorTargetSnapshot(eventID: event.eventID, mirrorID: nil,
            content: event.content, hasExtraFields: event.hasExtraFields, hasMeetingParticipants: event.hasMeetingParticipants)
    }
    func addMeetingParticipants(eventID: String, calendarID: String) {
        guard var event = targets[calendarID]?[eventID] else { return }
        event.hasMeetingParticipants = true
        targets[calendarID]?[eventID] = event
    }
    func blockNextWrite() { shouldBlockWrite = true }
    func waitForBlockedWrite() async {
        guard !blockedWrite else { return }
        await withCheckedContinuation { blockedObservers.append($0) }
    }
    func releaseWrite() {
        blockedWrite = false
        writeGate?.resume()
        writeGate = nil
    }
    func published(in calendarID: String) -> [MirrorTargetSnapshot] {
        Array((targets[calendarID] ?? [:]).values).sorted { $0.content.startDate < $1.content.startDate }
    }

    func inventory(managedCalendarIDs: Set<String>) -> SharedCalendarInventory {
        var options = Set(sources.map(\.calendarID)).sorted().map {
            SharedCalendarOption(id: $0, title: $0, sourceID: "icloud", sourceTitle: "iCloud",
                                 isWritable: false, isManaged: managedCalendarIDs.contains($0))
        }
        options += calendars.map {
            SharedCalendarOption(id: $0.key, title: $0.value, sourceID: "icloud", sourceTitle: "iCloud",
                                 isWritable: true, isManaged: true)
        }
        return SharedCalendarInventory(calendars: options,
            accounts: accountAvailable ? [SharedCalendarAccount(id: "icloud", title: "iCloud", calendarTitles: [])] : [])
    }

    func sourceEvents(calendarIDs: Set<String>, interval: DateInterval, excludedIDs: Set<String>) throws -> [SourceEventSnapshot] {
        lastRequestedSourceIDs = calendarIDs
        if sourceFailure { throw MockCalendarFailure.sourceUnavailable }
        return sources.filter { calendarIDs.contains($0.calendarID) && !excludedIDs.contains($0.calendarID) &&
            $0.startDate < interval.end && $0.endDate > interval.start }
    }

    func createCalendar(name: String, sourceID: String) throws -> String {
        guard accountAvailable else { throw SharedCalendarError.invalidAccount }
        createCount += 1
        let id = "target-\(createCount)"
        calendars[id] = EventKitCalendarStore.namePrefix + name
        targets[id] = [:]
        if failAfterNextCreation {
            failAfterNextCreation = false
            throw MockCalendarFailure.calendarCreatedThenFailed
        }
        return id
    }

    func renameCalendar(id: String, name: String, sourceID: String) throws {
        guard calendars[id] != nil else { throw SharedCalendarError.missingTarget }
        renameCount += 1
        calendars[id] = EventKitCalendarStore.namePrefix + name
    }

    func removeCalendar(id: String, sourceID: String) throws {
        guard accountAvailable else { throw SharedCalendarError.invalidAccount }
        if failCalendarDeletion { throw MockCalendarFailure.calendarDeleteFailed }
        calendars.removeValue(forKey: id)
        targets.removeValue(forKey: id)
    }

    func targetEvents(calendarID: String, sourceID: String, interval: DateInterval,
                      mappings: [MirrorMapping]) throws -> [MirrorTargetSnapshot] {
        guard calendars[calendarID] != nil else { throw SharedCalendarError.missingTarget }
        return published(in: calendarID)
    }

    func upsert(_ event: PublishedEvent, mapping: MirrorMapping, calendarID: String,
                sourceID: String, existingID: String?) async throws -> String {
        upsertCallCount += 1
        guard calendars[calendarID] != nil else { throw SharedCalendarError.missingTarget }
        if let existingID, targets[calendarID]?[existingID]?.hasMeetingParticipants == true {
            throw SharedCalendarError.meetingParticipants
        }
        if shouldBlockWrite {
            shouldBlockWrite = false
            blockedWrite = true
            blockedObservers.forEach { $0.resume() }
            blockedObservers.removeAll()
            await withCheckedContinuation { writeGate = $0 }
        }
        writeCount += 1
        let id = existingID ?? UUID().uuidString
        writtenEventIDs.append(id)
        targets[calendarID, default: [:]][id] = MirrorTargetSnapshot(eventID: id, mirrorID: mapping.mirrorID,
                                                                  content: event, hasExtraFields: false)
        if failAfterNextSave {
            failAfterNextSave = false
            throw MockCalendarFailure.savedThenFailed
        }
        return id
    }

    func removeEvent(id: String, mirrorID: UUID, calendarID: String, sourceID: String) throws {
        removeEventCallCount += 1
        guard let existing = targets[calendarID]?[id] else { return }
        guard !existing.hasMeetingParticipants else { throw SharedCalendarError.meetingParticipants }
        guard existing.mirrorID == mirrorID else { throw SharedCalendarError.ambiguousRecovery }
        targets[calendarID]?.removeValue(forKey: id)
        removeCount += 1
    }
}

@MainActor
struct MirrorSyncTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func source(title: String = "Secret appointment", start: Date? = nil,
                        occurrence: Date? = nil, recurring: Bool = false) -> SourceEventSnapshot {
        let start = start ?? date("2026-10-18T02:00:00Z")
        return SourceEventSnapshot(calendarID: "source", calendarItemIdentifier: "item",
            eventIdentifier: "event", externalIdentifier: "external", occurrenceDate: occurrence,
            isRecurring: recurring, title: title, startDate: start, endDate: start.addingTimeInterval(3600),
            location: "Private address", notes: "Private notes", timeZoneIdentifier: "Asia/Shanghai")
    }
    private func profile(name: String = "Family", privacy: PrivacyMode = .full) -> SharedCalendarProfile {
        SharedCalendarProfile(name: name, sourceCalendarIDs: ["source"], targetSourceID: "icloud",
            privacyMode: privacy, range: .fixed(start: date("2026-10-01T00:00:00Z"),
                                              endExclusive: date("2026-11-01T00:00:00Z"), timeZoneIdentifier: "Asia/Shanghai"))
    }

    @Test func createsUpdatesAndDeletesWithoutDuplicatingOnRefresh() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let first = try #require(await store.published(in: targetID).first)
        try await coordinator.sync(profileID: configuration.id)
        #expect(await store.writeCount == 1)
        #expect(await store.createCount == 1)
        await store.setSources([source(title: "Updated appointment")])
        try await coordinator.sync(profileID: configuration.id)
        let updated = try #require(await store.published(in: targetID).first)
        #expect(updated.eventID == first.eventID)
        #expect(updated.content.title == "Updated appointment")
        await store.setSources([])
        try await coordinator.sync(profileID: configuration.id)
        #expect(await store.published(in: targetID).isEmpty)
        #expect(coordinator.state.mappings.isEmpty)
        #expect(coordinator.state.operations.isEmpty)
    }

    @Test func privacyDowngradeClearsPersistedFieldsAndExclusionDeletes() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        var configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        #expect(await store.published(in: targetID).first?.content.notes == "Private notes")
        configuration.privacyMode = .opaque
        try await coordinator.update(configuration)
        let opaque = try #require(await store.published(in: targetID).first)
        #expect(opaque.content.title == CalendarEvent.Availability.busy.localizedName)
        #expect(opaque.content.location == nil && opaque.content.notes == nil)
        let preview = try #require(try await coordinator.preview(profileID: configuration.id).first)
        try await coordinator.setVisibility(profileID: configuration.id, event: preview,
                                             visibility: .excluded, entireSeries: false)
        #expect(await store.published(in: targetID).isEmpty)
        #expect(coordinator.state.mappings.isEmpty)
    }

    @Test func privacyReductionIsPublishedBeforeAnEarlierEventsDetailExpansion() async throws {
        let earlier = source(title: "Earlier appointment", start: date("2026-10-18T02:00:00Z"))
        var later = source(title: "Later appointment", start: date("2026-10-25T02:00:00Z"))
        later.calendarItemIdentifier = "later-item"
        later.eventIdentifier = "later-event"
        later.externalIdentifier = "later-external"
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [earlier, later])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile(privacy: .partial)
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let previews = try await coordinator.preview(profileID: configuration.id)
        let laterPreview = try #require(previews.first { $0.startDate == later.startDate })
        try await coordinator.setVisibility(profileID: configuration.id, event: laterPreview,
                                             visibility: .full, entireSeries: false)
        let initial = await store.published(in: targetID)
        let earlierID = try #require(initial.first { $0.content.startDate == earlier.startDate }?.eventID)
        let laterID = try #require(initial.first { $0.content.startDate == later.startDate }?.eventID)

        try await coordinator.setPaused(profileID: configuration.id, paused: true)
        try await coordinator.setVisibility(profileID: configuration.id, event: laterPreview,
                                             visibility: .opaque, entireSeries: false)
        var updated = try #require(coordinator.state.profiles.first)
        updated.privacyMode = .full
        try await coordinator.update(updated)
        await store.resetWriteLog()
        try await coordinator.setPaused(profileID: configuration.id, paused: false)

        #expect(await store.writtenEventIDs == [laterID, earlierID])
        let final = await store.published(in: targetID)
        #expect(final.first { $0.eventID == laterID }?.content.notes == nil)
        #expect(final.first { $0.eventID == earlierID }?.content.notes == "Private notes")
    }

    @Test func failedSourceReadPreservesExistingPublication() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let saved = await store.published(in: targetID)
        await store.setSources([])
        await store.failSourceReads(true)
        await #expect(throws: MockCalendarFailure.sourceUnavailable) {
            try await coordinator.sync(profileID: configuration.id)
        }
        let remaining = await store.published(in: targetID)
        #expect(remaining.count == saved.count)
        #expect(remaining.first?.content == saved.first?.content)
        #expect(await store.removeCount == 0)
        #expect(coordinator.state.profiles.first?.lastError != nil)
    }

    @Test func restartRecoversWriteWhichSucceededBeforeReportingFailure() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        await store.failAfterSavingNextWrite()
        await #expect(throws: MockCalendarFailure.savedThenFailed) { try await coordinator.create(configuration) }
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let first = try #require(await store.published(in: targetID).first)
        #expect(coordinator.state.mappings.first?.targetEventID == nil)
        #expect(coordinator.state.operations.contains { $0.kind == .upsert })
        let restored = try MirrorSyncCoordinator(repository: repository, store: store)
        try await restored.sync(profileID: configuration.id)
        let recovered = await store.published(in: targetID)
        #expect(recovered.count == 1)
        #expect(recovered.first?.eventID == first.eventID)
        #expect(await store.writeCount == 1)
        #expect(restored.state.operations.isEmpty)
        #expect(restored.state.mappings.first?.targetEventID == first.eventID)
    }

    @Test func restartRecoversCalendarCreatedBeforeFailureUsingItsUniqueCreationToken() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        await store.failAfterCreatingNextCalendar()
        await #expect(throws: MockCalendarFailure.calendarCreatedThenFailed) {
            try await coordinator.create(configuration)
        }
        #expect(coordinator.state.profiles.first?.targetCalendarID == nil)
        let pending = try #require(coordinator.state.operations.first { $0.kind == .createCalendar })
        #expect(pending.targetName?.contains(pending.id.uuidString.lowercased()) == true)
        let restored = try MirrorSyncCoordinator(repository: repository, store: store)
        try await restored.recreateTarget(profileID: configuration.id)
        let targetID = try #require(restored.state.profiles.first?.targetCalendarID)
        #expect(await store.createCount == 1)
        #expect(restored.state.operations.isEmpty)
        #expect(await store.published(in: targetID).count == 1)
        let inventory = try await restored.inventory()
        #expect(inventory.calendars.first { $0.id == targetID }?.title == EventKitCalendarStore.namePrefix + configuration.name)
    }

    @Test func excludingAnEventWithAnOwnerRemovedMarkerStillRevokesIt() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let event = try #require(await store.published(in: targetID).first)
        await store.removeMarker(eventID: event.eventID, calendarID: targetID)
        let preview = try #require(try await coordinator.preview(profileID: configuration.id).first)
        try await coordinator.setVisibility(profileID: configuration.id, event: preview,
                                             visibility: .excluded, entireSeries: false)
        #expect(await store.published(in: targetID).isEmpty)
        #expect(await store.writeCount == 2)
        #expect(coordinator.state.mappings.isEmpty)
        #expect(coordinator.state.operations.isEmpty)
    }

    @Test func excludingAnOwnerModifiedMeetingStopsBeforeAnyEventMutation() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let target = try #require(await store.published(in: targetID).first)
        let mappings = coordinator.state.mappings
        let writes = await store.upsertCallCount
        let removals = await store.removeEventCallCount
        await store.addMeetingParticipants(eventID: target.eventID, calendarID: targetID)
        // Ownership must also be recognized by the persisted target ID when the URL was removed.
        await store.removeMarker(eventID: target.eventID, calendarID: targetID)
        let preview = try #require(try await coordinator.preview(profileID: configuration.id).first)
        await #expect(throws: SharedCalendarError.meetingParticipants) {
            try await coordinator.setVisibility(profileID: configuration.id, event: preview,
                                                 visibility: .excluded, entireSeries: false)
        }
        #expect(await store.upsertCallCount == writes)
        #expect(await store.removeEventCallCount == removals)
        #expect(coordinator.state.mappings == mappings)
        #expect(coordinator.state.profiles.first?.lastError == SharedCalendarError.meetingParticipants.localizedDescription)
        #expect(await store.published(in: targetID).first?.hasMeetingParticipants == true)
    }

    @Test func sourceDeletionDoesNotCancelAnOwnerModifiedMeetingButExplicitCalendarDeletionWorks() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let target = try #require(await store.published(in: targetID).first)
        let mappings = coordinator.state.mappings
        let writes = await store.upsertCallCount
        let removals = await store.removeEventCallCount
        await store.addMeetingParticipants(eventID: target.eventID, calendarID: targetID)
        await store.setSources([])
        await #expect(throws: SharedCalendarError.meetingParticipants) {
            try await coordinator.sync(profileID: configuration.id)
        }
        #expect(await store.upsertCallCount == writes)
        #expect(await store.removeEventCallCount == removals)
        #expect(coordinator.state.mappings == mappings)
        #expect(coordinator.state.profiles.first?.lastError == SharedCalendarError.meetingParticipants.localizedDescription)
        try await coordinator.delete(profileID: configuration.id)
        #expect(coordinator.state.profiles.isEmpty)
        #expect(coordinator.state.mappings.isEmpty)
        #expect(coordinator.state.operations.isEmpty)
        #expect(await store.published(in: targetID).isEmpty)
        #expect(await store.removeEventCallCount == removals)
    }

    @Test func deselectingAllSourcesClearsOutputWithoutReadingOtherCalendars() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        var other = source(title: "Unselected secret")
        other.calendarID = "other-source"
        let store = MockCalendarStore(sources: [source(), other])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        var cleared = try #require(coordinator.state.profiles.first)
        cleared.sourceCalendarIDs = []
        try await coordinator.update(cleared)
        #expect(await store.lastRequestedSourceIDs.isEmpty)
        #expect(await store.published(in: targetID).isEmpty)
        #expect(coordinator.state.profiles.first?.sourceCalendarIDs.isEmpty == true)
    }

    @Test func pausedConfigurationUpdatesDoNotWriteUntilResumed() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let writeCount = await store.writeCount
        let renameCount = await store.renameCount
        try await coordinator.setPaused(profileID: configuration.id, paused: true)
        var updated = try #require(coordinator.state.profiles.first)
        updated.privacyMode = .opaque
        updated.name = "Paused changes"
        try await coordinator.update(updated)
        #expect(await store.writeCount == writeCount)
        #expect(await store.renameCount == renameCount)
        #expect(coordinator.state.profiles.first?.privacyMode == .opaque)
        try await coordinator.setPaused(profileID: configuration.id, paused: false)
        #expect(await store.writeCount == writeCount + 1)
        #expect(await store.published(in: targetID).first?.content.notes == nil)
    }

    @Test func staleEditorRevisionCannotOverwriteNewerSettings() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let original = profile()
        try await coordinator.create(original)
        var firstEdit = try #require(coordinator.state.profiles.first)
        firstEdit.privacyMode = .opaque
        try await coordinator.update(firstEdit)
        var staleEdit = original
        staleEdit.name = "Stale change"
        await #expect(throws: SharedCalendarError.staleConfiguration) { try await coordinator.update(staleEdit) }
        #expect(coordinator.state.profiles.first?.privacyMode == .opaque)
        #expect(coordinator.state.profiles.first?.name == original.name)
        #expect(coordinator.state.profiles.first?.revision == 1)
    }

    @Test func missingTargetIsOnlyRecreatedExplicitly() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let firstTarget = try #require(coordinator.state.profiles.first?.targetCalendarID)
        await store.externallyRemoveCalendar(firstTarget)
        await #expect(throws: SharedCalendarError.missingTarget) { try await coordinator.sync(profileID: configuration.id) }
        #expect(await store.createCount == 1)
        try await coordinator.recreateTarget(profileID: configuration.id)
        let replacement = try #require(coordinator.state.profiles.first?.targetCalendarID)
        #expect(replacement != firstTarget)
        #expect(await store.createCount == 2)
        #expect(await store.published(in: replacement).count == 1)
    }

    @Test func failedCalendarDeletionRetainsItsIntentAndCanResumeAfterRestart() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        await store.failCalendarDeletes(true)
        await #expect(throws: MockCalendarFailure.calendarDeleteFailed) { try await coordinator.delete(profileID: configuration.id) }
        #expect(coordinator.state.profiles.first?.pendingDeletion == true)
        #expect(coordinator.state.operations.contains { $0.kind == .deleteCalendar })
        #expect(await store.published(in: targetID).count == 1)
        let restored = try MirrorSyncCoordinator(repository: repository, store: store)
        await store.failCalendarDeletes(false)
        try await restored.delete(profileID: configuration.id)
        #expect(restored.state.profiles.isEmpty)
        #expect(restored.state.mappings.isEmpty)
        #expect(restored.state.operations.isEmpty)
    }

    @Test func unavailableAccountCannotRecreateOrForgetAnExistingPublication() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        await store.setAccountAvailable(false)
        await #expect(throws: SharedCalendarError.invalidAccount) { try await coordinator.recreateTarget(profileID: configuration.id) }
        await #expect(throws: SharedCalendarError.invalidAccount) { try await coordinator.delete(profileID: configuration.id) }
        #expect(coordinator.state.profiles.first?.targetCalendarID == targetID)
        #expect(coordinator.state.profiles.first?.pendingDeletion == true)
        #expect(await store.createCount == 1)
        #expect(await store.published(in: targetID).count == 1)
    }

    @Test func multiplePublicationsKeepVisibilityAndDeletionIndependent() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let full = profile(name: "Family")
        let opaque = profile(name: "Work", privacy: .opaque)
        try await coordinator.create(full)
        try await coordinator.create(opaque)
        let fullTarget = try #require(coordinator.state.profiles.first { $0.id == full.id }?.targetCalendarID)
        let opaqueTarget = try #require(coordinator.state.profiles.first { $0.id == opaque.id }?.targetCalendarID)
        #expect(fullTarget != opaqueTarget)
        let event = try #require(try await coordinator.preview(profileID: full.id).first)
        try await coordinator.setVisibility(profileID: full.id, event: event, visibility: .excluded, entireSeries: false)
        #expect(await store.published(in: fullTarget).isEmpty)
        #expect(await store.published(in: opaqueTarget).count == 1)
        #expect(await store.published(in: opaqueTarget).first?.content.notes == nil)
        try await coordinator.delete(profileID: full.id)
        #expect(coordinator.state.profiles.map(\.id) == [opaque.id])
        #expect(await store.published(in: opaqueTarget).count == 1)
    }

    @Test func occurrenceOverridesWinAndFollowRescheduledInstances() async throws {
        let firstDate = date("2026-10-18T02:00:00Z")
        let nextDate = date("2026-10-25T02:00:00Z")
        let first = source(start: firstDate, occurrence: firstDate, recurring: true)
        let second = source(start: nextDate, occurrence: nextDate, recurring: true)
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [first, second])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        let configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        let preview = try #require(try await coordinator.preview(profileID: configuration.id).first)
        try await coordinator.setVisibility(profileID: configuration.id, event: preview, visibility: .opaque, entireSeries: true)
        try await coordinator.setVisibility(profileID: configuration.id, event: preview, visibility: .full, entireSeries: false)
        let before = await store.published(in: targetID)
        let oldID = try #require(before.first { $0.content.startDate == firstDate }?.eventID)
        var rescheduled = first
        rescheduled.startDate = date("2026-10-20T02:00:00Z")
        rescheduled.endDate = rescheduled.startDate.addingTimeInterval(3600)
        await store.setSources([rescheduled, second])
        try await coordinator.sync(profileID: configuration.id)
        let after = await store.published(in: targetID)
        #expect(after.count == 2)
        let moved = try #require(after.first { $0.content.startDate == rescheduled.startDate })
        #expect(moved.eventID == oldID)
        #expect(moved.content.notes == "Private notes")
        #expect(after.first { $0.content.startDate == nextDate }?.content.notes == nil)
    }

    @Test func configurationChangeDuringWriteConvergesToLatestPrivacy() async throws {
        let repository = try SharedCalendarRepository(inMemory: true)
        let store = MockCalendarStore(sources: [source()])
        let coordinator = try MirrorSyncCoordinator(repository: repository, store: store)
        var configuration = profile()
        try await coordinator.create(configuration)
        let targetID = try #require(coordinator.state.profiles.first?.targetCalendarID)
        await store.setSources([source(title: "Changed secret")])
        await store.blockNextWrite()
        let obsolete = Task { try await coordinator.sync(profileID: configuration.id) }
        await store.waitForBlockedWrite()
        configuration.privacyMode = .opaque
        let newConfiguration = configuration
        var update: Task<Void, Error>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coordinator.onChange = { state in
                if state.profiles.first?.privacyMode == .opaque {
                    coordinator.onChange = nil
                    continuation.resume()
                }
            }
            update = Task { try await coordinator.update(newConfiguration) }
        }
        await store.releaseWrite()
        await #expect(throws: SharedCalendarError.staleConfiguration) { try await obsolete.value }
        try await update?.value
        let final = try #require(await store.published(in: targetID).first)
        #expect(final.content.title == CalendarEvent.Availability.busy.localizedName)
        #expect(final.content.notes == nil && final.content.location == nil)
        #expect(coordinator.state.profiles.first?.privacyMode == .opaque)
        #expect(coordinator.state.profiles.first?.lastError == nil)
        #expect(coordinator.state.operations.isEmpty)
    }
}
