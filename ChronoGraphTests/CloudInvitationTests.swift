import Foundation
import Testing
@testable import ChronoGraph

@MainActor
struct CloudInvitationTests {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let peer = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!

    private func meeting(id: UUID = UUID(), title: String = "Invitation", host: UUID? = nil, status: String = "proposed",
                         response: String = "pending", start: Date = Date().addingTimeInterval(86_400),
                         participants: [CloudMeetingMember]? = nil) -> CloudMeeting {
        CloudMeeting(id: id, hostId: host ?? peer, title: title, start: start,
                     end: start.addingTimeInterval(1800), timezone: "Asia/Shanghai", revision: 1,
                     status: status, participants: participants ?? [CloudMeetingMember(userId: account, response: response)], updatedAt: Date())
    }

    private func manager(reader: @escaping () async throws -> [CloudMeeting]) -> CloudWorkspaceManager {
        let session = CloudSession(accessToken: "synthetic-invitation-token", tokenType: "bearer", expiresAt: .distantFuture,
                                   user: CloudUser(id: account, displayName: "Test"), deviceId: UUID(), authProvider: "password")
        let defaults = UserDefaults(suiteName: "CloudInvitationTests." + UUID().uuidString)!
        return CloudWorkspaceManager(testingInvitationSession: session, defaults: defaults, invitationReader: reader)
    }

    private func managerWithUploads(reader: @escaping () async throws -> [CloudMeeting],
                                    uploader: @escaping (CloudLocalBinding, CloudSource) async throws -> CloudSource) -> CloudWorkspaceManager {
        let device = UUID(), sourceID = UUID()
        let session = CloudSession(accessToken: "synthetic-invitation-token", tokenType: "bearer", expiresAt: .distantFuture,
                                   user: CloudUser(id: account, displayName: "Test"), deviceId: device, authProvider: "password")
        let source = CloudSource(id: sourceID, ownerId: account, deviceId: device, name: "Source", uploadLevel: .full,
                                 generation: 1, coverageStart: nil, coverageEnd: nil, lastSyncedAt: nil)
        return CloudWorkspaceManager(testingSession: session, source: source,
                                     binding: CloudLocalBinding(sourceId: sourceID, calendarId: "test.calendar", uploadLevel: .full),
                                     defaults: UserDefaults(suiteName: "CloudInvitationTests." + UUID().uuidString)!,
                                     sourceUpdater: { _, _ in source }, snapshotUploader: uploader,
                                     invitationReader: reader)
    }

    @Test func onlyFuturePendingGuestsContributeToTheBadge() {
        let now = Date()
        #expect(meeting().requiresInvitationResponse(from: account, at: now))
        #expect(!meeting(host: account).requiresInvitationResponse(from: account, at: now))
        #expect(!meeting(start: now).requiresInvitationResponse(from: account, at: now))
        #expect(!meeting(start: now.addingTimeInterval(-1)).requiresInvitationResponse(from: account, at: now))
        for response in ["accepted", "declined", "tentative"] {
            #expect(!meeting(response: response).requiresInvitationResponse(from: account, at: now))
        }
        for status in ["confirmed", "cancelled"] {
            #expect(!meeting(status: status).requiresInvitationResponse(from: account, at: now))
        }
        #expect(!meeting().requiresInvitationResponse(from: UUID(), at: now))
    }

    @Test func sectionsPartitionTheListWithoutRepeatingPendingGuests() {
        let now = Date()
        let sooner = meeting(start: now.addingTimeInterval(600))
        let later = meeting(start: now.addingTimeInterval(1200))
        let own = meeting(host: account)
        let answered = meeting(response: "accepted")
        let expired = meeting(start: now.addingTimeInterval(-60))
        let values = [later, own, answered, expired, sooner]
        let groups = CloudInvitationGroups(meetings: values, userID: account, now: now)
        #expect(groups.pending.map(\.id) == [sooner.id, later.id])
        #expect(groups.sent.map(\.id) == [own.id])
        #expect(Set(groups.other.map(\.id)) == Set([answered.id, expired.id]))
        #expect(Set((groups.pending + groups.sent + groups.other).map(\.id)).count == values.count)
        #expect(expired.invitationStatusKey(for: account, at: now) == "invitations.status.expired")
    }

    @Test func anAcceptedProposalShowsReadyForConfirmationForHostsAndGuests() {
        let now = Date()
        let start = now.addingTimeInterval(3600)
        let accepted = CloudMeeting(id: UUID(), hostId: account, title: "Ready", start: start,
                                    end: start.addingTimeInterval(1800), timezone: "Asia/Shanghai", revision: 1,
                                    status: "proposed", participants: [CloudMeetingMember(userId: account, response: "accepted"),
                                                                        CloudMeetingMember(userId: peer, response: "accepted")], updatedAt: now)
        #expect(accepted.invitationStatusKey(for: account, at: now) == "invitations.status.ready")
        #expect(accepted.invitationStatusKey(for: peer, at: now) == "invitations.status.ready")
        #expect(!accepted.requiresInvitationResponse(from: peer, at: now))
        #expect(accepted.invitationStatusKey(for: account, at: start) == "invitations.status.expired")
        #expect(meeting(host: account, response: "pending").invitationStatusKey(for: account, at: now) == "invitations.status.waiting")
    }

    @Test func organizerConfirmationRequiresAFutureProposalWithEveryParticipantAccepted() {
        let now = Date()
        let members = [CloudMeetingMember(userId: account, response: "accepted"), CloudMeetingMember(userId: peer, response: "accepted")]
        let ready = meeting(host: account, participants: members)
        #expect(ready.requiresOrganizerConfirmation(from: account, at: now))
        #expect(!ready.requiresOrganizerConfirmation(from: peer, at: now))
        #expect(!ready.requiresInvitationResponse(from: account, at: now))
        for status in ["confirmed", "cancelled"] {
            #expect(!meeting(host: account, status: status, participants: members).requiresOrganizerConfirmation(from: account, at: now))
        }
        #expect(!meeting(host: account, start: now, participants: members).requiresOrganizerConfirmation(from: account, at: now))
        #expect(!meeting(host: account, participants: []).requiresOrganizerConfirmation(from: account, at: now))
        #expect(!meeting(host: account, participants: [members[0], CloudMeetingMember(userId: peer, response: "pending")])
            .requiresOrganizerConfirmation(from: account, at: now))
    }

    @Test func actionableCountCombinesGuestResponsesAndHostConfirmationsWithoutHistory() async {
        let members = [CloudMeetingMember(userId: account, response: "accepted"), CloudMeetingMember(userId: peer, response: "accepted")]
        let values = [meeting(), meeting(host: account, participants: members), meeting(host: account), meeting(response: "accepted"),
                      meeting(host: account, start: Date().addingTimeInterval(-60), participants: members),
                      meeting(host: account, status: "cancelled", participants: members),
                      meeting(host: account, status: "confirmed", participants: members)]
        let value = manager { values }
        await value.refreshInvitations()
        #expect(value.pendingInvitationCount == 1)
        #expect(value.actionableInvitationCount == 2)
    }

    @Test func hostTaskAppearsAfterTheFinalAcceptanceAndClearsOnConfirmation() async {
        let id = UUID(), start = Date().addingTimeInterval(86_400)
        let selfAccepted = CloudMeetingMember(userId: account, response: "accepted")
        let waiting = meeting(id: id, host: account, start: start,
                              participants: [selfAccepted, CloudMeetingMember(userId: peer, response: "pending")])
        let value = manager { [waiting] }
        await value.refreshInvitations()
        #expect(value.actionableInvitationCount == 0)
        let accepted = meeting(id: id, host: account, start: start,
                               participants: [selfAccepted, CloudMeetingMember(userId: peer, response: "accepted")])
        #expect(value.applyConfirmedMeeting(accepted, scope: value.homeDisplayScope, token: value.session?.accessToken))
        #expect(value.pendingInvitationCount == 0 && value.actionableInvitationCount == 1)
        let confirmed = meeting(id: id, host: account, status: "confirmed", start: start, participants: accepted.participants)
        #expect(value.applyConfirmedMeeting(confirmed, scope: value.homeDisplayScope, token: value.session?.accessToken))
        #expect(value.actionableInvitationCount == 0)
    }

    @Test func invitationReadsDoNotRequireCalendarUploadEnablementOrMutateIt() async {
        var reads = 0
        let invitation = meeting()
        let value = manager { reads += 1; return [invitation] }
        await value.refreshInvitations()
        #expect(reads == 1)
        #expect(value.meetings.map(\.id) == [invitation.id])
        #expect(value.pendingInvitationCount == 1)
        #expect(value.invitationsHasLoaded && value.invitationsLastRefreshedAt != nil)
        #expect(!value.invitationsIsLoading && !value.isBusy)
        #expect(value.sources.isEmpty && value.bindings.isEmpty && value.calendars.isEmpty)
        #expect(value.notice == nil && value.errorMessage == nil && value.invitationsError == nil)
    }

    @Test func invitationReadsContinueWhileAnUploadCommandIsBusyWithoutStartingASnapshot() async throws {
        let device = UUID(), sourceID = UUID()
        let lastUpload = Date()
        let coverageStart = lastUpload.addingTimeInterval(-86_400)
        let coverageEnd = lastUpload.addingTimeInterval(90 * 86_400)
        let session = CloudSession(accessToken: "synthetic-invitation-token", tokenType: "bearer", expiresAt: .distantFuture,
                                   user: CloudUser(id: account, displayName: "Test"), deviceId: device, authProvider: "password")
        let source = CloudSource(id: sourceID, ownerId: account, deviceId: device, name: "Source", uploadLevel: .full,
                                 generation: 1, coverageStart: coverageStart, coverageEnd: coverageEnd, lastSyncedAt: lastUpload)
        let reduced = CloudSource(id: sourceID, ownerId: account, deviceId: device, name: "Source", uploadLevel: .opaque,
                                  generation: 2, coverageStart: coverageStart, coverageEnd: coverageEnd, lastSyncedAt: lastUpload)
        var sourceResponse: CheckedContinuation<CloudSource, Never>?
        var reads = 0, uploads = 0
        let invitation = meeting()
        let value = CloudWorkspaceManager(testingSession: session, source: source,
                                          binding: CloudLocalBinding(sourceId: sourceID, calendarId: "test.calendar", uploadLevel: .full, isPaused: true),
                                          defaults: UserDefaults(suiteName: "CloudInvitationTests." + UUID().uuidString)!,
                                          sourceUpdater: { _, _ in await withCheckedContinuation { sourceResponse = $0 } },
                                          snapshotUploader: { _, source in uploads += 1; return source },
                                          invitationReader: { reads += 1; return [invitation] })
        let command = Task { await value.changeUploadLevel(sourceID: sourceID, level: .opaque) }
        for _ in 0..<1000 where sourceResponse == nil { await Task.yield() }
        let continuation = try #require(sourceResponse)
        #expect(value.isBusy)
        await value.refreshInvitations()
        #expect(reads == 1 && value.pendingInvitationCount == 1)
        #expect(value.isBusy, "The independent read must not end the upload command's busy state")
        #expect(uploads == 0 && !value.invitationsIsLoading)
        continuation.resume(returning: reduced)
        await command.value
        #expect(uploads == 0 && !value.isBusy)
    }

    @Test func failedRefreshKeepsTheLastSuccessfulAccountListAndMarksItStale() async {
        var reads = 0
        let invitation = meeting()
        let value = manager {
            reads += 1
            if reads == 1 { return [invitation] }
            throw URLError(.notConnectedToInternet)
        }
        await value.refreshInvitations()
        let successfulRead = value.invitationsLastRefreshedAt
        await value.refreshInvitations()
        #expect(value.meetings.map(\.id) == [invitation.id])
        #expect(value.pendingInvitationCount == 1)
        #expect(value.invitationsHasLoaded)
        #expect(value.invitationsLastRefreshedAt == successfulRead)
        #expect(value.invitationsError != nil && !value.invitationsIsLoading)
        #expect(value.errorMessage == nil, "Read failures belong to the inbox rather than unrelated upload commands")
    }

    @Test func anInitialFailureDoesNotConfirmAnEmptyInbox() async {
        let value = manager { throw URLError(.notConnectedToInternet) }
        await value.refreshInvitations()
        #expect(value.meetings.isEmpty && !value.invitationsHasLoaded)
        #expect(value.invitationsLastRefreshedAt == nil)
        #expect(value.invitationsError != nil && !value.invitationsIsLoading)
    }

    @Test func anOlderReadCannotReplaceANewerResponse() async throws {
        var suspended: CheckedContinuation<[CloudMeeting], Never>?
        var reads = 0
        let old = meeting(title: "Old pending")
        let current = meeting(title: "Current answered", response: "accepted")
        let value = manager {
            reads += 1
            if reads == 1 { return await withCheckedContinuation { suspended = $0 } }
            return [current]
        }
        let firstRead = Task { await value.refreshInvitations() }
        for _ in 0..<1000 where suspended == nil { await Task.yield() }
        let continuation = try #require(suspended)
        await value.refreshInvitations()
        continuation.resume(returning: [old])
        await firstRead.value
        #expect(value.meetings.map(\.id) == [current.id])
        #expect(value.pendingInvitationCount == 0)
        #expect(!value.invitationsIsLoading && value.invitationsError == nil)
    }

    @Test func logoutClearsTheInboxAndRejectsALateRead() async throws {
        var suspended: CheckedContinuation<[CloudMeeting], Never>?
        let invitation = meeting()
        let value = manager { await withCheckedContinuation { suspended = $0 } }
        let read = Task { await value.refreshInvitations() }
        for _ in 0..<1000 where suspended == nil { await Task.yield() }
        let continuation = try #require(suspended)
        #expect(value.invitationsIsLoading)
        await value.signOut()
        #expect(value.session == nil && !value.invitationsIsLoading)
        continuation.resume(returning: [invitation])
        await read.value
        #expect(value.meetings.isEmpty && value.pendingInvitationCount == 0)
        #expect(!value.invitationsHasLoaded && value.invitationsLastRefreshedAt == nil)
        #expect(value.invitationsError == nil)
    }

    @Test func cancellingAReadKeepsExistingDataWithoutInventingAnError() async throws {
        var suspended: CheckedContinuation<[CloudMeeting], Never>?
        var reads = 0
        let invitation = meeting()
        let value = manager {
            reads += 1
            if reads == 1 { return [invitation] }
            return await withCheckedContinuation { suspended = $0 }
        }
        await value.refreshInvitations()
        let successfulRead = value.invitationsLastRefreshedAt
        let read = Task { await value.refreshInvitations() }
        for _ in 0..<1000 where suspended == nil { await Task.yield() }
        let continuation = try #require(suspended)
        read.cancel()
        continuation.resume(returning: [])
        await read.value
        #expect(value.meetings.map(\.id) == [invitation.id])
        #expect(value.invitationsLastRefreshedAt == successfulRead)
        #expect(value.invitationsError == nil && !value.invitationsIsLoading)
    }

    @Test func aConfirmedResponseInvalidatesAnOlderPendingSnapshotAtTheSameRevision() async throws {
        var suspended: CheckedContinuation<[CloudMeeting], Never>?
        var reads = 0
        let pending = meeting()
        let accepted = meeting(id: pending.id, response: "accepted", start: pending.start)
        let value = manager {
            reads += 1
            if reads == 1 { return [pending] }
            return await withCheckedContinuation { suspended = $0 }
        }
        await value.refreshInvitations()
        let read = Task { await value.refreshInvitations() }
        for _ in 0..<1000 where suspended == nil { await Task.yield() }
        let continuation = try #require(suspended)
        #expect(value.applyConfirmedMeeting(accepted, scope: value.homeDisplayScope, token: value.session?.accessToken))
        #expect(value.pendingInvitationCount == 0 && !value.invitationsIsLoading)
        continuation.resume(returning: [pending])
        await read.value
        #expect(value.meetings.first?.participants.first?.response == "accepted")
        #expect(value.pendingInvitationCount == 0)
        #expect(value.meetings.first?.revision == pending.revision)
    }

    @Test func aConfirmedMutationCannotRepopulateASignedOutAccount() async {
        let value = manager { [] }
        let scope = value.homeDisplayScope, token = value.session?.accessToken
        await value.signOut()
        #expect(!value.applyConfirmedMeeting(meeting(), scope: scope, token: token))
        #expect(value.meetings.isEmpty && value.pendingInvitationCount == 0)
    }

    @Test func aServerErrorReadingInvitationsDoesNotBlockCalendarSync() async {
        let invitation = meeting()
        var reads = 0, uploads = 0
        let value = managerWithUploads(reader: {
            reads += 1
            if reads == 1 { return [invitation] }
            throw CloudClientError.http(503, "Synthetic invitation service unavailable")
        }, uploader: { _, source in uploads += 1; return source })
        await value.refreshInvitations()
        let lastSuccessfulRead = value.invitationsLastRefreshedAt
        await value.sync()
        #expect(reads == 2 && uploads == 1)
        #expect(value.session != nil && value.errorMessage == nil)
        #expect(value.meetings.map(\.id) == [invitation.id])
        #expect(value.invitationsHasLoaded && value.invitationsError != nil)
        #expect(value.invitationsLastRefreshedAt == lastSuccessfulRead)
        #expect(!value.isBusy && !value.invitationsIsLoading)
    }

    @Test func anUnauthorizedInvitationReadStopsSyncAndClearsTheSession() async {
        let invitation = meeting()
        var reads = 0, uploads = 0
        let value = managerWithUploads(reader: {
            reads += 1
            if reads == 1 { return [invitation] }
            throw CloudClientError.http(401, "Synthetic expired session")
        }, uploader: { _, source in uploads += 1; return source })
        await value.refreshInvitations()
        #expect(value.pendingInvitationCount == 1)
        await value.sync()
        #expect(reads == 2 && uploads == 0)
        #expect(value.session == nil && value.errorMessage != nil)
        #expect(value.bindings.isEmpty && value.sources.isEmpty && value.meetings.isEmpty)
        #expect(value.pendingInvitationCount == 0 && !value.invitationsHasLoaded)
        #expect(value.invitationsLastRefreshedAt == nil)
        #expect(!value.isBusy && !value.invitationsIsLoading)
    }
}
