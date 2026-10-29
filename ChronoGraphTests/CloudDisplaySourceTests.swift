import Foundation
import Testing
@testable import ChronoGraph

@MainActor
private final class DisplayResponse<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    func read() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func started() async throws -> CheckedContinuation<Value, Error> {
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        return try #require(continuation)
    }
}

@MainActor
struct CloudDisplaySourceTests {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let peer = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let device = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let ownID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    private let receivedID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    private let base = Date(timeIntervalSince1970: 1_793_232_000)
    private func session(account: UUID? = nil, token: String = "synthetic-display-token") -> CloudSession {
        CloudSession(accessToken: token, tokenType: "bearer", expiresAt: .distantFuture,
                     user: CloudUser(id: account ?? self.account, displayName: "My nickname"), deviceId: device, authProvider: "password")
    }
    private func owned(id: UUID? = nil, owner: UUID? = nil, generation: Int = 3) -> CloudSource {
        CloudSource(id: id ?? ownID, ownerId: owner ?? account, deviceId: device, name: "My cloud calendar", uploadLevel: .full,
                    generation: generation, coverageStart: base, coverageEnd: base.addingTimeInterval(86_400), lastSyncedAt: base)
    }
    private func received(id: UUID? = nil, owner: UUID? = nil, generation: Int = 2) -> CloudSharedSource {
        CloudSharedSource(id: id ?? receivedID, ownerId: owner ?? peer, ownerName: "Friend", name: "Received calendar", privacy: .partial,
                          generation: generation, coverageStart: base, coverageEnd: base.addingTimeInterval(86_400), lastSyncedAt: base)
    }
    private func event() -> CloudBusyEvent {
        CloudBusyEvent(id: UUID(), seriesId: nil, start: base, end: base.addingTimeInterval(3600), isAllDay: false,
                       timezone: "Asia/Shanghai", availability: "busy", title: "Memory only", location: nil, notes: nil)
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CloudDisplaySourceTests." + UUID().uuidString)! }
    private func manager(selected: Set<UUID> = [], savedDefaults: UserDefaults? = nil,
                         ownedReader: (() async throws -> [CloudSource])? = nil,
                         receivedReader: (() async throws -> [CloudSharedSource])? = nil,
                         eventsReader: ((UUID, DateInterval) async throws -> [CloudBusyEvent])? = nil,
                         remover: @escaping (UUID) async throws -> Void = { _ in },
                         availability: ((CloudAvailabilityRequest) async throws -> CloudAvailability)? = nil) -> CloudWorkspaceManager {
        let own = owned(), shared = received()
        return CloudWorkspaceManager(testingDisplaySession: session(), sources: [own], sharedSources: [shared],
                                     selectedSourceIDs: selected, defaults: savedDefaults ?? defaults(),
                                     ownedSourcesReader: ownedReader ?? { [own] }, receivedSourcesReader: receivedReader ?? { [shared] },
                                     eventsReader: eventsReader, receivedSourceRemover: remover, availabilityReader: availability)
    }
    private func readCancelled(_ task: Task<Void, Error>) async -> Bool {
        do { try await task.value; return false }
        catch { return error is CancellationError }
    }

    @Test func ownedSourcesProjectTheSameDisplayAuthorityWithoutAutomaticSelection() throws {
        let value = manager()
        let display = try #require(value.displaySources.first)
        #expect(display == CloudSharedSource(ownedSource: owned(), ownerName: "My nickname"))
        #expect(display.ownerId == account && display.privacy == .full && display.generation == 3)
        #expect(value.displaySources.map(\.id) == [ownID, receivedID])
        #expect(value.sharedSources.map(\.id) == [receivedID])
        #expect(value.selectedDisplaySourceIDs.isEmpty && value.bindings.isEmpty)
        value.toggleDisplaySource(ownID)
        value.toggleSharedSourceDisplay(receivedID)
        #expect(value.selectedDisplaySourceIDs == [ownID, receivedID])
        value.clearDisplaySourceSelection()
        value.selectAllDisplaySources()
        #expect(value.selectedSharedSourceIDs == [ownID, receivedID])
        value.clearSharedSourceDisplay()
        value.toggleDisplaySource(UUID())
        #expect(value.selectedDisplaySourceIDs.isEmpty)
    }

    @Test func atomicRefreshRetainsBothSelectionsAndUsesTheExistingPersistenceKey() async throws {
        let saved = defaults(), unknown = UUID()
        let value = manager(selected: [ownID, receivedID, unknown], savedDefaults: saved)
        try await value.refreshSharedSourcesForDisplay()
        #expect(value.selectedDisplaySourceIDs == [ownID, receivedID])
        let key = "cloud.https://display-tests.invalid.displaySources." + account.uuidString
        #expect(Set(saved.stringArray(forKey: key) ?? []) == Set([ownID.uuidString, receivedID.uuidString]))
        #expect(value.sharedSources.map(\.id) == [receivedID])
    }

    @Test func eitherMetadataFailurePreservesBothCatalogHalvesAndSelection() async {
        for failsOwned in [true, false] {
            let emptyOwn: [CloudSource] = [], emptyReceived: [CloudSharedSource] = []
            let value = manager(selected: [ownID, receivedID], ownedReader: {
                if failsOwned { throw URLError(.notConnectedToInternet) }
                return emptyOwn
            }, receivedReader: {
                if !failsOwned { throw URLError(.notConnectedToInternet) }
                return emptyReceived
            })
            do { try await value.refreshSharedSourcesForDisplay(); Issue.record("Expected a transport failure") }
            catch { #expect(error is URLError) }
            #expect(value.sources.map(\.id) == [ownID] && value.sharedSources.map(\.id) == [receivedID])
            #expect(value.selectedDisplaySourceIDs == [ownID, receivedID])
        }
    }

    @Test func receivedMetadataCannotDuplicateOrMasqueradeAsOwnedSources() async throws {
        let foreign = received(), duplicateOwn = received(id: ownID), invalidOwn = received(id: UUID(), owner: account)
        let value = manager(receivedReader: { [foreign, foreign, duplicateOwn, invalidOwn] })
        try await value.refreshSharedSourcesForDisplay()
        #expect(value.sharedSources.map(\.id) == [receivedID])
        #expect(value.displaySources.map(\.id) == [ownID, receivedID])
    }

    @Test func ownedAndReceivedEventsUseTheSameReadPathButStaleAuthorityCannotFetch() async throws {
        var requested: [UUID] = []
        let sample = event()
        let value = manager(eventsReader: { id, _ in requested.append(id); return [sample] })
        for source in value.displaySources {
            let events = try await value.fetchSharedEvents(source: source, interval: DateInterval(start: base, duration: 86_400))
            #expect(events.map(\.id) == [sample.id])
        }
        #expect(requested == [ownID, receivedID])
        do {
            _ = try await value.fetchSharedEvents(source: received(generation: 1), interval: DateInterval(start: base, duration: 86_400))
            Issue.record("An older authority must not start a read")
        } catch { #expect(requested.count == 2) }
    }

    @Test func removingExactlyOneReceivedGrantClearsSelectionAndCandidateInputs() async throws {
        var removed: [UUID] = []
        let result = CloudAvailability(timezone: "Asia/Shanghai", checkedAt: base, windows: [])
        let value = manager(selected: [ownID, receivedID], remover: { removed.append($0) }, availability: { _ in result })
        await value.search(selectedPeople: [peer], days: 3, duration: 30, dailyStart: "09:00", dailyEnd: "18:00")
        #expect(value.availability != nil && value.lastParticipants.count == 2)
        #expect(await value.removeReceivedSource(sourceID: receivedID))
        #expect(removed == [receivedID] && value.sharedSources.isEmpty)
        #expect(value.sources.map(\.id) == [ownID] && value.selectedDisplaySourceIDs == [ownID])
        #expect(value.availability == nil && value.lastParticipants.isEmpty)
        #expect(!value.isRemovingReceivedSource && value.removeReceivedSourceError == nil)
        // Stale server/name reads cannot silently subscribe again.
        try await value.refreshSharedSourcesForDisplay()
        #expect(value.sharedSources.isEmpty && value.displaySources.map(\.id) == [ownID])
    }

    @Test func failedRemovalKeepsTheGrantSelectionAndPreviousCandidatesForRetry() async {
        let result = CloudAvailability(timezone: "Asia/Shanghai", checkedAt: base, windows: [])
        var attempts = 0
        let value = manager(selected: [ownID, receivedID], remover: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
        }, availability: { _ in result })
        await value.search(selectedPeople: [peer], days: 3, duration: 30, dailyStart: "09:00", dailyEnd: "18:00")
        #expect(!(await value.removeReceivedSource(sourceID: receivedID)))
        #expect(value.sharedSources.map(\.id) == [receivedID] && value.selectedDisplaySourceIDs == [ownID, receivedID])
        #expect(value.availability != nil && value.lastParticipants.count == 2)
        #expect(value.removeReceivedSourceError != nil && !value.isRemovingReceivedSource)
        #expect(await value.removeReceivedSource(sourceID: receivedID))
        #expect(attempts == 2 && value.removeReceivedSourceError == nil)
    }

    @Test func ownedAndUnknownSourcesNeverSendAnUnsubscribeRequest() async {
        var requests = 0
        let value = manager(remover: { _ in requests += 1 })
        #expect(!(await value.removeReceivedSource(sourceID: ownID)))
        #expect(!(await value.removeReceivedSource(sourceID: UUID())))
        #expect(requests == 0 && value.sources.map(\.id) == [ownID] && value.sharedSources.map(\.id) == [receivedID])
    }

    @Test func unsubscribeInvalidatesMetadataAlreadyReadingAndEventsAlreadyInFlight() async throws {
        let metadata = DisplayResponse<[CloudSharedSource]>(), events = DisplayResponse<[CloudBusyEvent]>()
        let value = manager(receivedReader: { try await metadata.read() }, eventsReader: { _, _ in try await events.read() })
        let source = received(), sample = event()
        let read = Task { try await value.refreshSharedSourcesForDisplay() }
        let readResponse = try await metadata.started()
        let eventRead = Task { _ = try await value.fetchSharedEvents(source: source, interval: DateInterval(start: base, duration: 86_400)) }
        let eventResponse = try await events.started()
        #expect(await value.removeReceivedSource(sourceID: receivedID))
        readResponse.resume(returning: [source]); eventResponse.resume(returning: [sample])
        #expect(await readCancelled(read))
        #expect(await readCancelled(eventRead))
        #expect(value.sharedSources.isEmpty && value.selectedDisplaySourceIDs.isEmpty)
    }

    @Test func metadataStartedDuringDeletionCannotRestoreTheRemovedGrant() async throws {
        let removal = DisplayResponse<Void>(), metadata = DisplayResponse<[CloudSharedSource]>()
        let value = manager(receivedReader: { try await metadata.read() }, remover: { _ in try await removal.read() })
        let deletion = Task { await value.removeReceivedSource(sourceID: receivedID) }
        let deleteResponse = try await removal.started()
        let read = Task { try await value.refreshSharedSourcesForDisplay() }
        let readResponse = try await metadata.started()
        deleteResponse.resume(returning: ())
        #expect(await deletion.value)
        readResponse.resume(returning: [received()])
        #expect(await readCancelled(read))
        #expect(value.sharedSources.isEmpty)
    }

    @Test func aNewerMetadataRequestWinsOverAnOlderGeneration() async throws {
        let delayed = DisplayResponse<[CloudSource]>()
        var reads = 0
        let newer = owned(generation: 8), shared = received()
        let value = manager(ownedReader: {
            reads += 1
            return reads == 1 ? try await delayed.read() : [newer]
        }, receivedReader: { [shared] })
        let oldRead = Task { try await value.refreshSharedSourcesForDisplay() }
        let oldResponse = try await delayed.started()
        try await value.refreshSharedSourcesForDisplay()
        oldResponse.resume(returning: [owned(generation: 4)])
        #expect(await readCancelled(oldRead))
        #expect(value.sources.first?.generation == 8 && value.displaySources.first?.generation == 8)
    }

    @Test func tokenRotationCancelsMetadataEventsAndOldRemovalErrors() async throws {
        let metadata = DisplayResponse<[CloudSharedSource]>(), events = DisplayResponse<[CloudBusyEvent]>(), removal = DisplayResponse<Void>()
        let source = received()
        let value = manager(receivedReader: { try await metadata.read() }, eventsReader: { _, _ in try await events.read() },
                            remover: { _ in try await removal.read() })
        let read = Task { try await value.refreshSharedSourcesForDisplay() }
        let readResponse = try await metadata.started()
        let eventRead = Task { _ = try await value.fetchSharedEvents(source: source, interval: DateInterval(start: base, duration: 86_400)) }
        let eventResponse = try await events.started()
        let deletion = Task { await value.removeReceivedSource(sourceID: receivedID) }
        let deleteResponse = try await removal.started()
        value.replaceDisplayTestingSession(session(token: "rotated-synthetic-token"))
        readResponse.resume(returning: [source]); eventResponse.resume(returning: [event()])
        deleteResponse.resume(throwing: CloudClientError.http(401, "Old token"))
        #expect(await readCancelled(read))
        #expect(await readCancelled(eventRead))
        #expect(!(await deletion.value))
        #expect(value.session?.accessToken == "rotated-synthetic-token")
        #expect(value.sharedSources.map(\.id) == [receivedID] && value.removeReceivedSourceError == nil)
        #expect(!value.isRemovingReceivedSource)
    }

    @Test func oldAccountDeletionCannotRemoveASameIDCalendarFromANewAccountOrEndpoint() async throws {
        for changesEndpoint in [false, true] {
            let removal = DisplayResponse<Void>()
            let newAccount = UUID(), newOwn = owned(owner: changesEndpoint ? account : UUID())
            let actualAccount = changesEndpoint ? account : newOwn.ownerId
            let shared = received()
            var switched = false
            let value = manager(ownedReader: { switched ? [newOwn] : [owned()] }, receivedReader: { [shared] },
                                remover: { _ in try await removal.read() })
            let deletion = Task { await value.removeReceivedSource(sourceID: receivedID) }
            let response = try await removal.started()
            switched = true
            value.replaceDisplayTestingSession(session(account: actualAccount, token: newAccount.uuidString),
                                               endpoint: changesEndpoint ? "https://new-display.invalid" : nil)
            try await value.refreshSharedSourcesForDisplay()
            value.toggleDisplaySource(receivedID)
            response.resume(returning: ())
            #expect(!(await deletion.value))
            #expect(value.sharedSources.map(\.id) == [receivedID] && value.selectedDisplaySourceIDs == [receivedID])
            #expect(value.removeReceivedSourceError == nil && value.currentUserID == actualAccount)
        }
    }

    @Test func anInFlightAvailabilitySearchCannotRestoreUnsubscribedParticipants() async throws {
        let availability = DisplayResponse<CloudAvailability>()
        let value = manager(remover: { _ in }, availability: { _ in try await availability.read() })
        let search = Task { await value.search(selectedPeople: [peer], days: 3, duration: 30, dailyStart: "09:00", dailyEnd: "18:00") }
        let response = try await availability.started()
        #expect(value.isBusy)
        #expect(await value.removeReceivedSource(sourceID: receivedID))
        response.resume(returning: CloudAvailability(timezone: "Asia/Shanghai", checkedAt: base, windows: []))
        await search.value
        #expect(value.availability == nil && value.lastParticipants.isEmpty && value.sharedSources.isEmpty)
    }
}
