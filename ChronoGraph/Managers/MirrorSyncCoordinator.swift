import Foundation
import CryptoKit

/// Local configuration changes are immediate; EventKit operations are serialized and revision-checked.
@MainActor
final class MirrorSyncCoordinator {
    private(set) var state: SharedCalendarState
    var onChange: ((SharedCalendarState) -> Void)?
    private let repository: SharedCalendarRepository
    private let store: any CalendarStore
    private var tail: Task<Void, Never>?
    private var previouslyManagedIDs: Set<String>

    init(repository: SharedCalendarRepository, store: any CalendarStore, knownManagedCalendarIDs: Set<String> = []) throws {
        self.repository = repository
        self.store = store
        state = try repository.load()
        previouslyManagedIDs = knownManagedCalendarIDs.union(state.profiles.compactMap(\.targetCalendarID))
    }

    var managedIDs: Set<String> { previouslyManagedIDs.union(state.profiles.compactMap(\.targetCalendarID)) }

    private func persist() throws {
        do {
            try repository.save(state)
            previouslyManagedIDs.formUnion(state.profiles.compactMap(\.targetCalendarID))
            onChange?(state)
        } catch {
            if let saved = try? repository.load() { state = saved }
            onChange?(state)
            throw error
        }
    }

    private func serialized<T>(_ action: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await action()
        }
        tail = Task { @MainActor in _ = try? await work.value }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    func inventory() async throws -> SharedCalendarInventory {
        try await store.inventory(managedCalendarIDs: managedIDs)
    }

    private func profile(_ id: UUID) throws -> SharedCalendarProfile {
        guard let value = state.profiles.first(where: { $0.id == id }) else { throw SharedCalendarError.staleConfiguration }
        return value
    }

    private func check(_ original: SharedCalendarProfile) throws {
        try Task.checkCancellation()
        let latest = try profile(original.id)
        guard latest.revision == original.revision, !latest.pendingDeletion, !latest.isPaused else {
            throw SharedCalendarError.staleConfiguration
        }
    }

    private func validate(_ value: SharedCalendarProfile) throws {
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedCalendarError.invalidName }
        guard !value.targetSourceID.isEmpty else { throw SharedCalendarError.invalidAccount }
        guard value.sourceCalendarIDs.isDisjoint(with: managedIDs) else { throw SharedCalendarError.managedSource }
        _ = try value.range.dateInterval()
    }

    func create(_ value: SharedCalendarProfile) async throws {
        try validate(value)
        guard !state.profiles.contains(where: { $0.id == value.id }) else { throw SharedCalendarError.staleConfiguration }
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.targetCalendarID = nil
        value.lastUpdated = nil
        value.lastError = nil
        value.pendingDeletion = false
        state.profiles.append(value)
        try persist()
        do {
            try await serialized {
                try await self.createTarget(value.id)
                if !value.isPaused { try await self.synchronize(value.id) }
            }
        } catch {
            try? record(error, for: value.id)
            throw error
        }
    }

    private func createTarget(_ id: UUID) async throws {
        let current = try profile(id)
        guard current.targetCalendarID == nil else { return }
        let inventory = try await self.inventory()
        guard inventory.accounts.contains(where: { $0.id == current.targetSourceID }) else { throw SharedCalendarError.invalidAccount }
        // A temporary, random creation token survives a crash between EventKit and SwiftData.
        // It is never matched against the owner's ordinary calendar name.
        if let pending = state.operations.first(where: { $0.profileID == id && $0.kind == .createCalendar }) {
            guard let temporaryName = pending.targetName else { throw SharedCalendarError.ambiguousRecovery }
            let candidates = inventory.calendars.filter {
                $0.sourceID == current.targetSourceID && $0.title == EventKitCalendarStore.namePrefix + temporaryName
            }
            guard candidates.count == 1, let recovered = candidates.first else { throw SharedCalendarError.ambiguousRecovery }
            state.profiles[state.profiles.firstIndex(where: { $0.id == id })!].targetCalendarID = recovered.id
            state.operations.removeAll { $0.id == pending.id }
            try persist()
            try await store.renameCalendar(id: recovered.id, name: current.name, sourceID: current.targetSourceID)
            return
        }
        var operation = MirrorOperation(profileID: id, kind: .createCalendar, targetSourceID: current.targetSourceID)
        let temporaryName = "\(current.name) · \(operation.id.uuidString.lowercased())"
        operation.targetName = temporaryName
        state.operations.append(operation)
        try persist()
        let targetID: String
        do {
            targetID = try await store.createCalendar(name: temporaryName, sourceID: current.targetSourceID)
        } catch {
            // A fresh, authorized inventory can prove a failed creation left no local item.
            // Otherwise retain the intent so a retry recovers the random token, never a name guess.
            if let fresh = try? await self.inventory(), fresh.accounts.contains(where: { $0.id == current.targetSourceID }),
               !fresh.calendars.contains(where: { $0.sourceID == current.targetSourceID && $0.title == EventKitCalendarStore.namePrefix + temporaryName }) {
                state.operations.removeAll { $0.id == operation.id }
                try persist()
            }
            throw error
        }
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw SharedCalendarError.staleConfiguration }
        state.profiles[index].targetCalendarID = targetID
        state.operations.removeAll { $0.id == operation.id }
        try persist()
        try await store.renameCalendar(id: targetID, name: current.name, sourceID: current.targetSourceID)
    }

    func update(_ value: SharedCalendarProfile) async throws {
        try validate(value)
        let old = try profile(value.id)
        guard !old.pendingDeletion, old.targetSourceID == value.targetSourceID else { throw SharedCalendarError.invalidAccount }
        guard value.revision == old.revision else { throw SharedCalendarError.staleConfiguration }
        var updated = value
        updated.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.targetCalendarID = old.targetCalendarID
        updated.revision = old.revision + 1
        updated.lastUpdated = old.lastUpdated
        updated.lastError = nil
        updated.pendingDeletion = false
        state.profiles[state.profiles.firstIndex(where: { $0.id == value.id })!] = updated
        try persist()
        try await sync(profileID: value.id)
    }

    func setPaused(profileID: UUID, paused: Bool) async throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }), !state.profiles[index].pendingDeletion else {
            throw SharedCalendarError.staleConfiguration
        }
        state.profiles[index].isPaused = paused
        state.profiles[index].revision += 1
        try persist()
        if !paused { try await sync(profileID: profileID) }
    }

    func recreateTarget(profileID: UUID) async throws {
        try await serialized {
            let current = try self.profile(profileID)
            let inventory = try await self.inventory()
            guard !current.pendingDeletion,
                  inventory.accounts.contains(where: { $0.id == current.targetSourceID }) else { throw SharedCalendarError.invalidAccount }
            if current.targetCalendarID == nil,
               let pending = self.state.operations.first(where: { $0.profileID == profileID && $0.kind == .createCalendar }) {
                // Recover a known, randomly tagged creation; do not erase its write intent.
                if let token = pending.targetName,
                   inventory.calendars.contains(where: { $0.sourceID == current.targetSourceID && $0.title == EventKitCalendarStore.namePrefix + token }) {
                    try await self.createTarget(profileID)
                    if !current.isPaused { try await self.synchronize(profileID) }
                    return
                }
                // This explicitly requested recreation has a complete inventory of the original
                // account, and no item bearing our unique creation token. It is safe to retry.
                self.state.operations.removeAll { $0.id == pending.id }
            }
            // Only an absent target can be recreated. Never orphan a live calendar automatically.
            guard current.targetCalendarID == nil || !inventory.calendars.contains(where: { $0.id == current.targetCalendarID }) else {
                throw SharedCalendarError.ambiguousRecovery
            }
            guard let index = self.state.profiles.firstIndex(where: { $0.id == profileID }) else { throw SharedCalendarError.staleConfiguration }
            self.state.profiles[index].targetCalendarID = nil
            self.state.profiles[index].revision += 1
            self.state.profiles[index].lastError = nil
            self.state.profiles[index].lastUpdated = nil
            self.state.mappings.removeAll { $0.profileID == profileID }
            self.state.operations.removeAll { $0.profileID == profileID }
            try self.persist()
            try await self.createTarget(profileID)
            if !current.isPaused { try await self.synchronize(profileID) }
        }
    }

    func delete(profileID: UUID) async throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        state.profiles[index].pendingDeletion = true
        state.profiles[index].isPaused = true
        state.profiles[index].revision += 1
        try persist()
        do {
            try await serialized {
                var current = try self.profile(profileID)
                if current.targetCalendarID == nil,
                   let pending = self.state.operations.first(where: { $0.profileID == profileID && $0.kind == .createCalendar }) {
                    let inventory = try await self.inventory()
                    guard inventory.accounts.contains(where: { $0.id == current.targetSourceID }) else { throw SharedCalendarError.invalidAccount }
                    if let token = pending.targetName,
                       inventory.calendars.contains(where: { $0.sourceID == current.targetSourceID && $0.title == EventKitCalendarStore.namePrefix + token }) {
                        try await self.createTarget(profileID)
                        current = try self.profile(profileID)
                    } else {
                        self.state.operations.removeAll { $0.id == pending.id }
                        try self.persist()
                    }
                }
                if let target = current.targetCalendarID {
                    if !self.state.operations.contains(where: { $0.profileID == profileID && $0.kind == .deleteCalendar }) {
                        self.state.operations.append(MirrorOperation(profileID: profileID, kind: .deleteCalendar,
                            targetCalendarID: target, targetSourceID: current.targetSourceID))
                        try self.persist()
                    }
                    try await self.store.removeCalendar(id: target, sourceID: current.targetSourceID)
                } else if self.state.operations.contains(where: { $0.profileID == profileID && $0.kind == .createCalendar }) {
                    // The target creation outcome is unknown; retain the configuration for explicit recovery.
                    throw SharedCalendarError.ambiguousRecovery
                }
                self.state.profiles.removeAll { $0.id == profileID }
                self.state.overrides.removeAll { $0.profileID == profileID }
                self.state.mappings.removeAll { $0.profileID == profileID }
                self.state.operations.removeAll { $0.profileID == profileID }
                try self.persist()
            }
        } catch {
            try? record(error, for: profileID)
            throw error
        }
    }

    func sync(profileID: UUID) async throws {
        do {
            try await serialized {
                let current = try self.profile(profileID)
                guard !current.isPaused, !current.pendingDeletion else { return }
                if current.targetCalendarID == nil { try await self.createTarget(profileID) }
                try await self.synchronize(profileID)
            }
        } catch {
            if !(error is CancellationError), (error as? SharedCalendarError) != .staleConfiguration {
                try? record(error, for: profileID)
            }
            throw error
        }
    }

    private func record(_ error: Error, for id: UUID) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[index].lastError = error.localizedDescription
        try persist()
    }

    func preview(profileID: UUID) async throws -> [SharedEventPreview] {
        try await serialized {
            let current = try self.profile(profileID)
            return try await self.readPreview(current, range: current.range,
                sourceCalendarIDs: current.sourceCalendarIDs, displayMode: nil)
        }
    }

    func browsePreview(profileID: UUID, range: SharedCalendarRange, sourceCalendarIDs: Set<String>,
                       displayMode: PrivacyMode? = nil) async throws -> [SharedEventPreview] {
        try await serialized {
            try await self.readPreview(self.profile(profileID), range: range,
                sourceCalendarIDs: sourceCalendarIDs, displayMode: displayMode)
        }
    }

    private nonisolated func intersects(_ source: SourceEventSnapshot, _ interval: DateInterval) -> Bool {
        source.startDate < interval.end && (source.endDate > interval.start || source.startDate >= interval.start)
    }

    private func readPreview(_ current: SharedCalendarProfile, range: SharedCalendarRange,
                             sourceCalendarIDs: Set<String>, displayMode: PrivacyMode?) async throws -> [SharedEventPreview] {
        let now = Date()
        let confirmedInterval = try current.range.dateInterval(now: now)
        let events = try await store.sourceEvents(calendarIDs: sourceCalendarIDs,
            interval: range.dateInterval(now: now), excludedIDs: managedIDs)
        try Task.checkCancellation()
        guard try profile(current.id).revision == current.revision else { throw SharedCalendarError.staleConfiguration }
        let oldIdentities = state.identities
        let keys = try state.resolveIdentities(for: events)
        if oldIdentities != state.identities { try persist() }
        return zip(events, keys).map { source, key in
            let overrides = state.overrides.filter { $0.profileID == current.id && $0.sourceIdentityID == key.sourceIdentityID }
            let visibility = state.visibility(profileID: current.id, sourceKey: key, defaultMode: current.privacyMode)
            let membership: SharedEventMembership
            if !current.sourceCalendarIDs.contains(source.calendarID) { membership = .outsideSources }
            else if !intersects(source, confirmedInterval) { membership = .outsideDateRange }
            else if visibility == .excluded { membership = .excluded }
            else { membership = .confirmed }
            return SharedEventPreview(id: "\(key.sourceIdentityID)|\(key.occurrenceKey ?? "single")",
                identityID: key.sourceIdentityID, occurrenceKey: key.occurrenceKey, isRecurring: source.isRecurring,
                title: source.title, startDate: source.startDate, endDate: source.endDate, isAllDay: source.isAllDay,
                visibility: visibility,
                override: overrides.last(where: { $0.occurrenceKey == key.occurrenceKey })?.visibility,
                seriesOverride: source.isRecurring ? overrides.last(where: { $0.occurrenceKey == nil })?.visibility : nil,
                published: membership == .confirmed ? PublishedEvent(source: source, visibility: visibility) : nil,
                source: source, defaultPrivacyMode: current.privacyMode, membership: membership, displayMode: displayMode)
        }
    }

    func review(_ draft: SharedCalendarDraft) async throws -> SharedRuleReview {
        try await serialized {
            let previous = self.state.profiles.first { $0.id == draft.id }
            guard draft.profile.revision == draft.baseRevision,
                  previous.map({ $0.revision == draft.baseRevision && !$0.pendingDeletion }) ?? (draft.baseRevision == 0) else {
                throw SharedCalendarError.staleConfiguration
            }
            try self.validate(draft.profile)
            if let previous, previous.targetSourceID != draft.profile.targetSourceID { throw SharedCalendarError.invalidAccount }
            let now = Date()
            let previousInterval: DateInterval?
            var usesRecordedPublication = false
            do { previousInterval = try previous?.range.dateInterval(now: now) }
            catch SharedCalendarModelError.rangeTooLarge {
                // An older release allowed unbounded scopes. Let owners review a smaller
                // scope without scanning that entire history or changing confirmed state.
                previousInterval = nil
                usesRecordedPublication = true
            }
            let proposedInterval = try draft.profile.range.dateInterval(now: now)
            let before: [SourceEventSnapshot]
            if let previous, let previousInterval {
                before = try await self.store.sourceEvents(calendarIDs: previous.sourceCalendarIDs,
                    interval: previousInterval, excludedIDs: self.managedIDs)
            } else { before = [] }
            let after: [SourceEventSnapshot]
            if previous?.range == draft.profile.range && previous?.sourceCalendarIDs == draft.profile.sourceCalendarIDs {
                after = before
            } else {
                after = try await self.store.sourceEvents(calendarIDs: draft.profile.sourceCalendarIDs,
                    interval: proposedInterval, excludedIDs: self.managedIDs)
            }
            try Task.checkCancellation()
            let latest = self.state.profiles.first { $0.id == draft.id }
            guard latest?.revision == previous?.revision, latest?.pendingDeletion != true else {
                throw SharedCalendarError.staleConfiguration
            }
            // Review identities are temporary; draft-only source events never enter confirmed state.
            var comparison = self.state
            let allKeys = try comparison.resolveIdentities(for: before + after)
            func projection(_ sources: [SourceEventSnapshot], keys: ArraySlice<SourceInstanceKey>,
                            profile: SharedCalendarProfile, interval: DateInterval) -> [SourceInstanceKey: SharedVisibility] {
                var result: [SourceInstanceKey: SharedVisibility] = [:]
                for (source, key) in zip(sources, keys) where profile.sourceCalendarIDs.contains(source.calendarID) && self.intersects(source, interval) {
                    let visibility = comparison.visibility(profileID: profile.id, sourceKey: key, defaultMode: profile.privacyMode)
                    if visibility != .excluded { result[key] = visibility }
                }
                return result
            }
            var oldProjection = previous.flatMap { old in previousInterval.map {
                projection(before, keys: allKeys.prefix(before.count), profile: old, interval: $0)
            } } ?? [:]
            if usesRecordedPublication, let previous {
                for mapping in self.state.mappings where mapping.profileID == previous.id {
                    oldProjection[mapping.sourceKey] = self.state.visibility(profileID: previous.id,
                        sourceKey: mapping.sourceKey, defaultMode: previous.privacyMode)
                }
            }
            let newProjection = projection(after, keys: allKeys.suffix(after.count), profile: draft.profile, interval: proposedInterval)
            let oldKeys = Set(oldProjection.keys)
            let newKeys = Set(newProjection.keys)
            func rank(_ visibility: SharedVisibility) -> Int {
                switch visibility { case .excluded: return 0; case .opaque: return 1; case .partial: return 2; case .full: return 3 }
            }
            var expanded = 0
            var reduced = 0
            for key in oldKeys.intersection(newKeys) {
                guard let old = oldProjection[key], let new = newProjection[key] else { continue }
                if rank(new) > rank(old) { expanded += 1 }
                if rank(new) < rank(old) { reduced += 1 }
            }
            let oldSources = previous?.sourceCalendarIDs ?? []
            let rangeChanged = previous?.range != draft.profile.range
            let privacyChanged = previous?.privacyMode != draft.profile.privacyMode
            let nameChanged = previous?.name != draft.profile.name
            return SharedRuleReview(confirmedProfile: previous, proposedProfile: draft.profile, baseRevision: draft.baseRevision,
                addedSourceCalendarIDs: draft.profile.sourceCalendarIDs.subtracting(oldSources),
                removedSourceCalendarIDs: oldSources.subtracting(draft.profile.sourceCalendarIDs),
                rangeChanged: rangeChanged, privacyModeChanged: privacyChanged, nameChanged: nameChanged,
                previousEventCount: oldProjection.count, proposedEventCount: newProjection.count,
                addedEventCount: newKeys.subtracting(oldKeys).count, removedEventCount: oldKeys.subtracting(newKeys).count,
                expandedDetailCount: expanded, reducedDetailCount: reduced,
                hasChanges: previous == nil || rangeChanged || privacyChanged || nameChanged || oldSources != draft.profile.sourceCalendarIDs || previous?.isPaused != draft.profile.isPaused,
                usesRecordedPublication: usesRecordedPublication)
        }
    }

    func setVisibility(profileID: UUID, event: SharedEventPreview, visibility: SharedVisibility?, entireSeries: Bool,
                       expectedRevision: Int? = nil) async throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }), !state.profiles[index].pendingDeletion else {
            throw SharedCalendarError.staleConfiguration
        }
        let current = state.profiles[index]
        if let expectedRevision, expectedRevision != current.revision { throw SharedCalendarError.staleConfiguration }
        guard let identity = state.identities.first(where: { $0.id == event.identityID }) else {
            throw SharedCalendarError.missingSource
        }
        let interval = try current.range.dateInterval()
        let overlaps = event.startDate < interval.end && (event.endDate > interval.start || event.startDate >= interval.start)
        guard current.sourceCalendarIDs.contains(identity.calendarID), overlaps,
              event.membership != .outsideDateRange, event.membership != .outsideSources else {
            throw SharedCalendarError.outsideSharingScope
        }
        state.setVisibility(visibility, profileID: profileID,
            sourceKey: SourceInstanceKey(sourceIdentityID: event.identityID, occurrenceKey: event.occurrenceKey),
            scope: entireSeries && event.isRecurring ? .series : .occurrence)
        state.profiles[index].revision += 1
        state.profiles[index].lastError = nil
        try persist()
        try await sync(profileID: profileID)
    }

    private func fingerprint(_ event: PublishedEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(event)).map { String(format: "%02x", $0) }.joined()
    }

    private func matches(_ actual: MirrorTargetSnapshot, _ desired: PublishedEvent) -> Bool {
        let content = actual.content
        func clean(_ value: String?) -> String? { value?.isEmpty == true ? nil : value }
        return !actual.hasExtraFields && content.title == desired.title && content.startDate == desired.startDate &&
            content.endDate == desired.endDate && content.isAllDay == desired.isAllDay &&
            clean(content.location) == clean(desired.location) && clean(content.notes) == clean(desired.notes) &&
            (content.availability == .notSupported || content.availability == desired.availability) &&
            (desired.timeZoneIdentifier == nil || content.timeZoneIdentifier == desired.timeZoneIdentifier)
    }

    private func synchronize(_ id: UUID) async throws {
        let current = try profile(id)
        guard !current.pendingDeletion else { return }
        guard !current.isPaused else { return }
        try check(current)
        guard let targetID = current.targetCalendarID else { throw SharedCalendarError.missingTarget }
        let interval = try current.range.dateInterval()
        // Source read must finish successfully before any destructive output operation.
        let sources = try await store.sourceEvents(calendarIDs: current.sourceCalendarIDs, interval: interval, excludedIDs: managedIDs)
        try check(current)
        let keys = try state.resolveIdentities(for: sources)
        try persist()
        let oldMappings = state.mappings.filter { $0.profileID == id }
        let oldByKey = oldMappings.reduce(into: [SourceInstanceKey: MirrorMapping]()) { $0[$1.sourceKey] = $1 }
        let targets = try await store.targetEvents(calendarID: targetID, sourceID: current.targetSourceID,
            interval: interval, mappings: oldMappings)
        try check(current)
        let ownedMarkers = Set(oldMappings.map(\.mirrorID))
        let ownedEventIDs = Set(oldMappings.compactMap(\.targetEventID))
        guard !targets.contains(where: {
            $0.hasMeetingParticipants && (ownedEventIDs.contains($0.eventID) || $0.mirrorID.map(ownedMarkers.contains) == true)
        }) else { throw SharedCalendarError.meetingParticipants }
        let byMarker = Dictionary(grouping: targets.filter { $0.mirrorID != nil }, by: { $0.mirrorID! })
        var desired: [SourceInstanceKey: PublishedEvent] = [:]
        for (source, key) in zip(sources, keys) {
            let visibility = state.visibility(profileID: id, sourceKey: key, defaultMode: current.privacyMode)
            if let event = PublishedEvent(source: source, visibility: visibility) { desired[key] = event }
        }
        // Remove revoked/out-of-window events before adding any new detail.
        for mapping in oldMappings where desired[mapping.sourceKey] == nil {
            try check(current)
            let operation = MirrorOperation(profileID: id, mappingID: mapping.mirrorID, kind: .deleteEvent)
            state.operations.removeAll { $0.profileID == id && $0.mappingID == mapping.mirrorID }
            state.operations.append(operation)
            try persist()
            var revokedTargets = byMarker[mapping.mirrorID] ?? []
            if let tracked = targets.first(where: { $0.eventID == mapping.targetEventID }), tracked.mirrorID != mapping.mirrorID {
                guard tracked.mirrorID == nil else { throw SharedCalendarError.ambiguousRecovery }
                // Restore an owner-removed marker while scrubbing detail first. A failed delete
                // then leaves only a busy block, and a retry can still locate it by the marker.
                var scrubbed = tracked.content
                scrubbed.title = scrubbed.availability.localizedName
                scrubbed.location = nil
                scrubbed.notes = nil
                try check(current)
                let restoredID = try await store.upsert(scrubbed, mapping: mapping, calendarID: targetID,
                    sourceID: current.targetSourceID, existingID: tracked.eventID)
                revokedTargets.append(MirrorTargetSnapshot(eventID: restoredID, mirrorID: mapping.mirrorID,
                    content: scrubbed, hasExtraFields: false))
            }
            for target in revokedTargets {
                try check(current)
                try await store.removeEvent(id: target.eventID, mirrorID: mapping.mirrorID, calendarID: targetID, sourceID: current.targetSourceID)
            }
            state.mappings.removeAll { $0.mirrorID == mapping.mirrorID }
            state.operations.removeAll { $0.id == operation.id }
            try persist()
        }
        // Privacy reductions precede other existing events, then newly introduced items.
        func priority(_ entry: (key: SourceInstanceKey, value: PublishedEvent)) -> Int {
            guard let mapping = oldByKey[entry.key] else { return 2 }
            let actual = byMarker[mapping.mirrorID]?.first ?? targets.first { $0.eventID == mapping.targetEventID }
            if let content = actual?.content,
               (content.notes != nil && entry.value.notes == nil || content.location != nil && entry.value.location == nil ||
                content.title != entry.value.title && entry.value.title == entry.value.availability.localizedName) { return 0 }
            return 1
        }
        let ordered = desired.sorted { a, b in
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            if a.value.startDate != b.value.startDate { return a.value.startDate < b.value.startDate }
            return a.key.sourceIdentityID.uuidString < b.key.sourceIdentityID.uuidString
        }
        for (key, content) in ordered {
            try check(current)
            var mapping = oldByKey[key] ?? MirrorMapping(profileID: id, sourceKey: key)
            let found = byMarker[mapping.mirrorID] ?? []
            // A saved ID also lets us repair a marker removed by an owner, without touching other calendars.
            let existing = found.first ?? targets.first { $0.eventID == mapping.targetEventID }
            let digest = try fingerprint(content)
            for duplicate in found.dropFirst() {
                try check(current)
                try await store.removeEvent(id: duplicate.eventID, mirrorID: mapping.mirrorID, calendarID: targetID, sourceID: current.targetSourceID)
            }
            let needsWrite = existing.map { !matches($0, content) || $0.mirrorID != mapping.mirrorID } ?? true
            if !needsWrite, let existing, mapping.targetEventID == existing.eventID,
               mapping.fingerprint == digest, mapping.lastStart == content.startDate, mapping.lastEnd == content.endDate,
               !state.operations.contains(where: { $0.profileID == id && $0.mappingID == mapping.mirrorID }) {
                // Do not re-encode and save the entire identity journal for every unchanged event.
                // This also allows an interrupted large publication to progress past its completed prefix.
                continue
            }
            mapping.lastStart = content.startDate
            mapping.lastEnd = content.endDate
            if let index = state.mappings.firstIndex(where: { $0.mirrorID == mapping.mirrorID }) { state.mappings[index] = mapping }
            else { state.mappings.append(mapping) }
            if needsWrite {
                state.operations.removeAll { $0.profileID == id && $0.mappingID == mapping.mirrorID }
                state.operations.append(MirrorOperation(profileID: id, mappingID: mapping.mirrorID, kind: .upsert))
                try persist()
                try check(current)
                mapping.targetEventID = try await store.upsert(content, mapping: mapping, calendarID: targetID,
                    sourceID: current.targetSourceID, existingID: existing?.eventID)
            } else { mapping.targetEventID = existing?.eventID }
            mapping.fingerprint = digest
            if let index = state.mappings.firstIndex(where: { $0.mirrorID == mapping.mirrorID }) { state.mappings[index] = mapping }
            state.operations.removeAll { $0.profileID == id && $0.mappingID == mapping.mirrorID }
            try persist()
        }
        try check(current)
        try await store.renameCalendar(id: targetID, name: current.name, sourceID: current.targetSourceID)
        try check(current)
        if let index = state.profiles.firstIndex(where: { $0.id == id }) {
            state.profiles[index].lastUpdated = Date()
            state.profiles[index].lastError = nil
        }
        try persist()
    }
}
