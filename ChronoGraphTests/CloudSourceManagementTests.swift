import Foundation
import Testing
@testable import ChronoGraph

@MainActor
struct CloudSourceManagementTests {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let device = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let sourceID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private func source(_ level: CloudUploadLevel = .full, generation: Int = 1, hasCoverage: Bool = true, id: UUID? = nil) -> CloudSource {
        CloudSource(id: id ?? sourceID, ownerId: account, deviceId: device, name: "Test source", uploadLevel: level,
                    generation: generation, coverageStart: hasCoverage ? Date().addingTimeInterval(-86_400) : nil,
                    coverageEnd: hasCoverage ? Date().addingTimeInterval(100 * 86_400) : nil, lastSyncedAt: hasCoverage ? Date() : nil)
    }
    private func manager(paused: Bool = false,
                         updater: @escaping (UUID, CloudUploadLevel) async throws -> CloudSource,
                         uploader: @escaping (CloudLocalBinding, CloudSource) async throws -> CloudSource,
                         refresher: @escaping () async throws -> Void = {},
                         initialSource: CloudSource? = nil, initialBinding: CloudLocalBinding? = nil,
                         metadataReader: ((UUID) async throws -> CloudSource?)? = nil,
                         creator: ((UUID, CloudCalendarOption, CloudUploadLevel) async throws -> CloudSource)? = nil,
                         shareCreator: ((CloudSource) async throws -> CloudShareLink)? = nil,
                         feedCreator: ((CloudSource) async throws -> CloudFeedLink)? = nil) -> CloudWorkspaceManager {
        let session = CloudSession(accessToken: "synthetic-not-a-live-token", tokenType: "bearer", expiresAt: .distantFuture,
                                   user: CloudUser(id: account, displayName: "Test"), deviceId: device, authProvider: "password")
        let defaults = UserDefaults(suiteName: "CloudSourceManagementTests." + UUID().uuidString)!
        return CloudWorkspaceManager(testingSession: session, source: initialSource ?? source(),
                                     binding: initialBinding ?? CloudLocalBinding(sourceId: sourceID, calendarId: "test.calendar", uploadLevel: .full, isPaused: paused),
                                     defaults: defaults, sourceUpdater: updater, snapshotUploader: uploader, refresher: refresher,
                                     sourceMetadataReader: metadataReader, sourceCreator: creator, shareLinkCreator: shareCreator, feedLinkCreator: feedCreator)
    }
    @Test func legacyBindingsRemainActive() throws {
        let data = Data("{\"sourceId\":\"\(sourceID)\",\"calendarId\":\"calendar\",\"uploadLevel\":\"opaque\"}".utf8)
        let binding = try JSONDecoder().decode(CloudLocalBinding.self, from: data)
        #expect(binding.isPaused != true)
        #expect(binding.range == nil)
        #expect(binding.pendingRange == nil)
        #expect(binding.uploadRange == .rolling())
    }
    @Test func rejectedLevelChangePreservesConfirmedBinding() async {
        var uploads = 0
        let value = manager(updater: { _, _ in throw URLError(.notConnectedToInternet) }, uploader: { _, source in uploads += 1; return source })
        await value.changeUploadLevel(sourceID: sourceID, level: .opaque)
        #expect(value.bindings.first?.uploadLevel == .full)
        #expect(value.sources.first?.uploadLevel == .full)
        #expect(uploads == 0)
        #expect(value.errorMessage != nil)
    }
    @Test func reductionUsesAuthoritativeLevelAndGenerationForNextSnapshot() async {
        let reduced = source(.opaque, generation: 2)
        var uploaded: CloudLocalBinding?
        var generation: Int?
        let value = manager(updater: { _, _ in reduced }, uploader: { binding, source in uploaded = binding; generation = source.generation; return source })
        await value.changeUploadLevel(sourceID: sourceID, level: .opaque)
        #expect(uploaded?.uploadLevel == .opaque)
        #expect(generation == 2)
        #expect(value.bindings.first?.uploadLevel == value.sources.first?.uploadLevel)
        #expect(value.errorMessage == nil)
    }
    @Test func snapshotFailureKeepsSuccessfulServerReduction() async {
        let reduced = source(.opaque, generation: 2)
        let value = manager(updater: { _, _ in reduced }, uploader: { _, _ in throw URLError(.networkConnectionLost) })
        await value.changeUploadLevel(sourceID: sourceID, level: .opaque)
        #expect(value.bindings.first?.uploadLevel == .opaque)
        #expect(value.sources.first?.uploadLevel == .opaque)
        #expect(value.errorMessage != nil)
        #expect(value.notice == nil)
    }
    @Test func pausedSourceKeepsAutomaticReadRefreshWithoutUploadsOrDeletion() async {
        var mutations = 0
        var refreshes = 0
        let value = manager(updater: { _, _ in mutations += 1; return source() },
                            uploader: { _, source in mutations += 1; return source }, refresher: { refreshes += 1 })
        await value.setUploadPaused(sourceID, paused: true)
        await value.automaticSyncIfEnabled()
        #expect(value.isUploadPaused(sourceID))
        #expect(value.sources.count == 1)
        #expect(value.sources.first?.uploadLevel == .full)
        #expect(mutations == 0)
        #expect(refreshes == 1)
        #expect(value.errorMessage == nil)
    }
    @Test func manuallySyncingAllPausedSourcesStillRefreshesReadState() async {
        var uploads = 0
        var refreshes = 0
        let value = manager(paused: true, updater: { _, _ in source() },
                            uploader: { _, source in uploads += 1; return source }, refresher: { refreshes += 1 })
        await value.sync()
        #expect(refreshes == 1)
        #expect(uploads == 0)
        #expect(value.isUploadPaused(sourceID))
        #expect(value.sources.count == 1)
        #expect(value.errorMessage == nil)
    }
    @Test func resumeUploadsOnlyAfterExplicitActionAndFailureRemainsPaused() async {
        var uploads = 0
        let value = manager(paused: true, updater: { _, _ in source() }, uploader: { _, _ in uploads += 1; throw URLError(.notConnectedToInternet) })
        #expect(uploads == 0)
        await value.setUploadPaused(sourceID, paused: false)
        #expect(uploads == 1)
        #expect(value.isUploadPaused(sourceID))
        #expect(value.errorMessage != nil)
    }
    @Test func pausedReductionUpdatesServerAndBindingWithoutResuming() async {
        let reduced = source(.opaque, generation: 2)
        var uploads = 0
        let value = manager(paused: true, updater: { _, _ in reduced }, uploader: { _, source in uploads += 1; return source })
        await value.changeUploadLevel(sourceID: sourceID, level: .opaque)
        #expect(value.bindings.first?.uploadLevel == .opaque)
        #expect(value.isUploadPaused(sourceID))
        #expect(uploads == 0)
    }
    @Test func oversizedRangeIsRejectedBeforeAnyMutation() async {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tooLong = SharedCalendarRange.fixed(start: start, endExclusive: start.addingTimeInterval(181 * 86_400))
        var mutations = 0
        let value = manager(updater: { _, _ in mutations += 1; return source(.opaque) },
                            uploader: { _, source in mutations += 1; return source })
        await value.changeUploadScope(sourceID: sourceID, level: .opaque, range: tooLong)
        #expect(mutations == 0)
        #expect(value.bindings.first?.uploadLevel == .full)
        #expect(value.bindings.first?.range == nil)
        #expect(value.bindings.first?.pendingRange == nil)
        #expect(value.errorMessage != nil)
    }
    @Test func successfulRangeReplacementPromotesOnlyTheConfirmedNewRange() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        var uploadedRange: SharedCalendarRange?
        let value = manager(updater: { _, _ in source() }, uploader: { binding, source in
            uploadedRange = binding.uploadRange
            #expect(binding.pendingRange == selected)
            return source
        })
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(uploadedRange == selected)
        #expect(value.bindings.first?.range == selected)
        #expect(value.bindings.first?.pendingRange == nil)
        #expect(value.errorMessage == nil)
    }
    @Test func failedRangeReplacementKeepsNewIntentForRetryInsteadOfRestoringOldDates() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        var attempts = 0
        var attemptedRanges: [SharedCalendarRange] = []
        let value = manager(updater: { _, _ in source() }, uploader: { binding, source in
            attempts += 1; attemptedRanges.append(binding.uploadRange)
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return source
        })
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(value.bindings.first?.range == nil)
        #expect(value.bindings.first?.pendingRange == selected)
        #expect(value.errorMessage != nil)
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(attemptedRanges == [selected, selected])
        #expect(value.bindings.first?.range == selected)
        #expect(value.bindings.first?.pendingRange == nil)
        #expect(value.errorMessage == nil)
    }
    @Test func explicitlyChangingPausedRangeUpdatesOnceAndRetainsPause() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 6, timeZoneIdentifier: "Asia/Shanghai")
        var snapshots = 0
        let value = manager(paused: true, updater: { _, _ in source() }, uploader: { binding, source in
            snapshots += 1
            #expect(binding.isPaused == true)
            #expect(binding.uploadRange == selected)
            return source
        })
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(snapshots == 1)
        #expect(value.isUploadPaused(sourceID))
        #expect(value.bindings.first?.range == selected)
        #expect(value.errorMessage == nil)
    }
    @Test func pendingRangeSurvivesBindingPersistence() throws {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 13, timeZoneIdentifier: "Asia/Shanghai")
        let binding = CloudLocalBinding(sourceId: sourceID, calendarId: "test", uploadLevel: .opaque,
                                        range: .rolling(), pendingRange: selected)
        let restored = try JSONDecoder().decode(CloudLocalBinding.self, from: JSONEncoder().encode(binding))
        #expect(restored.uploadRange == selected)
        #expect(restored.confirmedRange == .rolling())
        #expect(restored.pendingRange == selected)
    }
    @Test func rangePolicyMatchesTheServerElapsedDayLimit() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let allowed = SharedCalendarRange.fixed(start: start, endExclusive: start.addingTimeInterval(180 * 86_400))
        #expect(try CloudUploadScopePolicy.interval(for: allowed).duration == 180 * 86_400)
        let rejected = SharedCalendarRange.fixed(start: start, endExclusive: start.addingTimeInterval(180 * 86_400 + 1))
        #expect(throws: CloudUploadScopeError.self) { try CloudUploadScopePolicy.interval(for: rejected) }
    }

    @Test func pendingRangeBlocksNewLinksBeforeCallingTheTransport() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        let value = manager(updater: { _, _ in source() }, uploader: { _, _ in throw URLError(.networkConnectionLost) })
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        let pairing = await value.createShareLink(source())
        #expect(pairing == nil)
        #expect(value.errorMessage == CloudCopy.text("请先成功更新已确认的上传设置，再创建分享链接。"))
        let feed = await value.createFeedLink(source())
        #expect(feed == nil)
        #expect(value.errorMessage == CloudCopy.text("请先成功更新已确认的上传设置，再创建分享链接。"))
    }

    @Test func lostPatchResponsePersistsFullScopeAndNeverUploadsWiderFields() async throws {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        var authoritative = source()
        var patches = 0
        var snapshots = 0
        let value = manager(updater: { _, _ in
            patches += 1
            authoritative = source(.opaque, generation: 2)
            throw URLError(.networkConnectionLost)
        }, uploader: { _, source in snapshots += 1; return source }, metadataReader: { _ in authoritative })
        await value.changeUploadScope(sourceID: sourceID, level: .opaque, range: selected)
        #expect(value.bindings.first?.pendingRange == selected)
        #expect(value.bindings.first?.pendingLevel == .opaque)
        #expect(value.bindings.first?.uploadLevel == .full)
        #expect(value.bindings.first?.range == nil)
        await value.sync()
        #expect(snapshots == 0)
        #expect(value.sources.first?.uploadLevel == .opaque)
        #expect(value.bindings.first?.hasPendingScope == true)
        let share = await value.createShareLink(source())
        #expect(share == nil)
        let persisted = try JSONDecoder().decode(CloudLocalBinding.self, from: JSONEncoder().encode(#require(value.bindings.first)))
        let restarted = manager(updater: { _, _ in patches += 1; return authoritative }, uploader: { binding, source in
            snapshots += 1
            #expect(binding.uploadLevel == .opaque)
            #expect(binding.pendingLevel == .opaque)
            #expect(binding.uploadRange == selected)
            return source
        }, initialSource: authoritative, initialBinding: persisted, metadataReader: { _ in authoritative })
        await restarted.sync()
        #expect(snapshots == 0)
        await restarted.changeUploadScope(sourceID: sourceID, level: .opaque, range: selected)
        #expect(patches == 1)
        #expect(snapshots == 1)
        #expect(restarted.bindings.first?.range == selected)
        #expect(restarted.bindings.first?.hasPendingScope == false)
    }
    @Test func rejectedPatchAndNarrowerDatesBlockBackgroundSnapshots() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 0, timeZoneIdentifier: "Asia/Shanghai")
        var snapshots = 0
        let value = manager(updater: { _, _ in throw URLError(.notConnectedToInternet) },
                            uploader: { _, source in snapshots += 1; return source })
        await value.changeUploadScope(sourceID: sourceID, level: .opaque, range: selected)
        await value.sync()
        #expect(value.bindings.first?.pendingLevel == .opaque)
        #expect(value.bindings.first?.pendingRange == selected)
        #expect(value.bindings.first?.uploadLevel == .full)
        #expect(value.bindings.first?.range == nil)
        #expect(snapshots == 0)
        #expect(value.errorMessage != nil)
    }
    @Test func committedSnapshotWithLostResponseRefreshesGenerationBeforeEditorRetry() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        var authoritative = source()
        var attemptedGenerations: [Int] = []
        var reads = 0
        let value = manager(updater: { _, _ in authoritative }, uploader: { binding, clientSource in
            attemptedGenerations.append(clientSource.generation)
            guard clientSource.generation == authoritative.generation else { throw CloudClientError.http(409, "stale_generation") }
            #expect(binding.uploadRange == selected)
            authoritative = source(generation: authoritative.generation + 1)
            if attemptedGenerations.count == 1 { throw URLError(.networkConnectionLost) }
            return authoritative
        }, metadataReader: { _ in reads += 1; return authoritative })
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(value.bindings.first?.pendingRange == selected)
        #expect(value.bindings.first?.range == nil)
        await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(reads == 2)
        #expect(attemptedGenerations == [1, 2])
        #expect(value.sources.first?.generation == 3)
        #expect(value.bindings.first?.range == selected)
        #expect(value.bindings.first?.hasPendingScope == false)
        #expect(value.errorMessage == nil)
    }
    @Test func firstSnapshotFailureAllowsRetryingTheUnchangedConfirmedScope() async {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        let unuploaded = source(hasCoverage: false)
        let binding = CloudLocalBinding(sourceId: sourceID, calendarId: "test.calendar", uploadLevel: .full, range: selected)
        #expect(CloudUploadScopePolicy.requiresUpdate(source: unuploaded, binding: binding, level: .full, range: selected))
        var snapshots = 0
        let value = manager(updater: { _, _ in source() }, uploader: { _, _ in snapshots += 1; return source(generation: 2) },
                            initialSource: unuploaded, initialBinding: binding, metadataReader: { _ in unuploaded })
        let completed = await value.changeUploadScope(sourceID: sourceID, level: .full, range: selected)
        #expect(completed?.coverageStart != nil)
        #expect(snapshots == 1)
        #expect(value.bindings.first?.hasPendingScope == false)
    }
    @Test func committedSourceCreationWithLostResponseRestoresTheSameUUIDAfterRestart() async throws {
        let selected = SharedCalendarRange.rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: "Asia/Shanghai")
        let calendar = CloudCalendarOption(id: "new.test.calendar", title: "New calendar", account: "Test")
        var remote: CloudSource?
        var createIDs: [UUID] = []
        var snapshots = 0
        let value = manager(updater: { _, _ in source(.opaque) }, uploader: { _, source in snapshots += 1; return source },
                            metadataReader: { id in remote?.id == id ? remote : nil }, creator: { id, _, level in
            createIDs.append(id)
            remote = source(level, hasCoverage: false, id: id)
            throw URLError(.networkConnectionLost)
        })
        let first = await value.enableCalendar(calendar, level: .opaque, range: selected)
        #expect(first == nil)
        let pending = try #require(value.bindings.first { $0.calendarId == calendar.id })
        #expect(pending.isCreationPending == true)
        #expect(pending.pendingLevel == .opaque)
        #expect(pending.pendingRange == selected)
        #expect(snapshots == 0)
        let restored = try JSONDecoder().decode(CloudLocalBinding.self, from: JSONEncoder().encode(pending))
        let restarted = manager(updater: { _, _ in remote! }, uploader: { binding, source in
            snapshots += 1
            return self.source(source.uploadLevel, generation: 1, id: binding.sourceId)
        }, initialBinding: restored, metadataReader: { id in remote?.id == id ? remote : nil }, creator: { id, _, level in
            createIDs.append(id)
            return self.source(level, hasCoverage: false, id: id)
        })
        let recovered = await restarted.enableCalendar(calendar, level: .opaque, range: selected)
        #expect(recovered?.id == pending.sourceId)
        #expect(createIDs == [pending.sourceId])
        #expect(snapshots == 1)
        #expect(restarted.bindings.count == 1)
        #expect(restarted.bindings.first?.hasPendingScope == false)
        #expect(restarted.bindings.first?.range == selected)
    }
    @Test func uncommittedSourceCreationRetriesTheSameUUID() async throws {
        let calendar = CloudCalendarOption(id: "new.test.calendar", title: "New calendar", account: "Test")
        var createIDs: [UUID] = []
        let value = manager(updater: { _, _ in source(.opaque) }, uploader: { binding, source in self.source(source.uploadLevel, id: binding.sourceId) },
                            metadataReader: { _ in nil }, creator: { id, _, level in
            createIDs.append(id)
            if createIDs.count == 1 { throw URLError(.notConnectedToInternet) }
            return self.source(level, hasCoverage: false, id: id)
        })
        _ = await value.enableCalendar(calendar, level: .opaque)
        let pendingID = try #require(value.bindings.first { $0.calendarId == calendar.id }?.sourceId)
        let recovered = await value.enableCalendar(calendar, level: .opaque)
        #expect(createIDs == [pendingID, pendingID])
        #expect(recovered?.id == pendingID)
        #expect(value.bindings.filter { $0.calendarId == calendar.id }.count == 1)
        #expect(value.bindings.first { $0.calendarId == calendar.id }?.hasPendingScope == false)
    }

    @Test func staleOpaqueReviewCannotCreateFullPermissionLinks() async {
        let reviewed = source(.opaque)
        let current = CloudSource(id: reviewed.id, ownerId: reviewed.ownerId, deviceId: reviewed.deviceId, name: reviewed.name,
                                  uploadLevel: .full, generation: reviewed.generation, coverageStart: reviewed.coverageStart,
                                  coverageEnd: reviewed.coverageEnd, lastSyncedAt: reviewed.lastSyncedAt)
        var requests = 0
        let value = manager(updater: { _, _ in current }, uploader: { _, source in source }, initialSource: current,
                            shareCreator: { _ in requests += 1; return CloudShareLink(id: UUID(), token: "synthetic", joinUrl: URL(string: "https://sharing.invalid/join")!, expiresAt: .distantFuture) },
                            feedCreator: { _ in requests += 1; return CloudFeedLink(id: UUID(), url: URL(string: "https://sharing.invalid/feed.ics")!) })
        let paired = await value.createShareLink(reviewed)
        #expect(paired == nil)
        #expect(value.errorMessage == CloudCopy.error(CloudUploadScopeError.reviewChanged))
        let feed = await value.createFeedLink(reviewed)
        #expect(feed == nil)
        #expect(value.errorMessage == CloudCopy.error(CloudUploadScopeError.reviewChanged))
        #expect(requests == 0)
    }
    @Test func staleGenerationOrCoverageReviewBlocksBothLinkTypes() async {
        let reviewed = source(.opaque)
        let newGeneration = CloudSource(id: reviewed.id, ownerId: reviewed.ownerId, deviceId: reviewed.deviceId, name: reviewed.name,
                                        uploadLevel: .opaque, generation: reviewed.generation + 1, coverageStart: reviewed.coverageStart,
                                        coverageEnd: reviewed.coverageEnd, lastSyncedAt: reviewed.lastSyncedAt)
        let newCoverage = CloudSource(id: reviewed.id, ownerId: reviewed.ownerId, deviceId: reviewed.deviceId, name: reviewed.name,
                                      uploadLevel: .opaque, generation: reviewed.generation, coverageStart: reviewed.coverageStart,
                                      coverageEnd: reviewed.coverageEnd?.addingTimeInterval(86_400), lastSyncedAt: reviewed.lastSyncedAt)
        for current in [newGeneration, newCoverage] {
            var requests = 0
            let value = manager(updater: { _, _ in current }, uploader: { _, source in source }, initialSource: current,
                                shareCreator: { _ in requests += 1; return CloudShareLink(id: UUID(), token: "synthetic", joinUrl: URL(string: "https://sharing.invalid/join")!, expiresAt: .distantFuture) },
                                feedCreator: { _ in requests += 1; return CloudFeedLink(id: UUID(), url: URL(string: "https://sharing.invalid/feed.ics")!) })
            let pair = await value.createShareLink(reviewed)
            let feed = await value.createFeedLink(reviewed)
            #expect(pair == nil)
            #expect(feed == nil)
            #expect(requests == 0)
            #expect(value.errorMessage == CloudCopy.error(CloudUploadScopeError.reviewChanged))
        }
    }
    @Test func reopeningWithFreshReviewAllowsBothLinkTypesAtExactlyTheReviewedLevel() async {
        let fresh = source(.full, generation: 2)
        var requestedLevels: [CloudUploadLevel] = []
        let value = manager(updater: { _, _ in fresh }, uploader: { _, source in source }, initialSource: fresh,
                            shareCreator: { reviewed in
            requestedLevels.append(reviewed.uploadLevel)
            return CloudShareLink(id: UUID(), token: "synthetic", joinUrl: URL(string: "https://sharing.invalid/join")!, expiresAt: .distantFuture)
        }, feedCreator: { reviewed in
            requestedLevels.append(reviewed.uploadLevel)
            return CloudFeedLink(id: UUID(), url: URL(string: "https://sharing.invalid/feed.ics")!)
        })
        let paired = await value.createShareLink(fresh)
        let feed = await value.createFeedLink(fresh)
        #expect(paired != nil)
        #expect(feed != nil)
        #expect(requestedLevels == [.full, .full])
        #expect(value.errorMessage == nil)
    }

}
