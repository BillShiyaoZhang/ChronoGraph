import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit

@MainActor
final class CloudWorkspaceManager: ObservableObject {
    @Published private(set) var endpoint = "" {
        didSet { if endpoint != oldValue { resetInvitations(); resetDisplaySession(clearSources: true); sharingReview = nil } }
    }
    @Published private(set) var session: CloudSession? {
        didSet {
            if oldValue?.accessToken != session?.accessToken || oldValue?.user.id != session?.user.id { sharingReview = nil }
            if oldValue?.user.id != session?.user.id {
                resetInvitations(); resetDisplaySession(clearSources: true)
            } else if oldValue?.accessToken != session?.accessToken {
                invalidateInvitationReads(); resetDisplaySession(clearSources: false)
                invitationsError = nil
            }
        }
    }
    @Published private(set) var challenge: CloudChallenge?
    @Published private(set) var sources: [CloudSource] = [] {
        didSet { if sources != oldValue { invalidateDisplayReads() } }
    }
    /// Calendars received from other accounts; owned sources remain in `sources`.
    @Published private(set) var sharedSources: [CloudSharedSource] = [] {
        didSet { if sharedSources != oldValue { invalidateDisplayReads() } }
    }
    @Published private(set) var isRemovingReceivedSource = false
    @Published private(set) var removeReceivedSourceError: String?
    @Published private(set) var selectedSharedSourceIDs: Set<UUID> = []
    @Published private(set) var meetings: [CloudMeeting] = []
    @Published private(set) var invitationsIsLoading = false
    @Published private(set) var invitationsError: String?
    @Published private(set) var invitationsLastRefreshedAt: Date?
    @Published private(set) var invitationsHasLoaded = false
    @Published private(set) var calendars: [CloudCalendarOption] = []
    @Published private(set) var bindings: [CloudLocalBinding] = []
    @Published private(set) var availability: CloudAvailability?
    @Published private(set) var lastParticipants: [CloudParticipant] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var calendarSyncStatus: String?
    private var client: CloudAPIClient?
    private let reader = CloudCalendarReader()
    private let calendarWriter = CloudMeetingCalendarWriter()
    private let defaults: UserDefaults
    private var lastAutomaticSync: Date?
    private var activeChallengeID: UUID?
    private var homeSourcesRequestID = UUID()
    private var displayAuthorityID = UUID()
    private var receivedRemovalRequestID = UUID()
    /// A late/stale metadata read cannot restore a locally confirmed unsubscribe.
    /// A successful explicit redemption clears its source's tombstone.
    private var removedReceivedSourceIDs: Set<UUID> = []
    private var invitationRequestID = UUID()
    private var sharingReview: CloudSharingReviewRecord?
    #if DEBUG
    private var testInvitationReader: (() async throws -> [CloudMeeting])?
    #endif
    #if DEBUG
    private var testOwnedDisplayReader: (() async throws -> [CloudSource])?
    private var testReceivedDisplayReader: (() async throws -> [CloudSharedSource])?
    private var testDisplayEventsReader: ((UUID, DateInterval) async throws -> [CloudBusyEvent])?
    private var testReceivedSourceRemover: ((UUID) async throws -> Void)?
    private var testAvailabilityReader: ((CloudAvailabilityRequest) async throws -> CloudAvailability)?

    /// Independent read/delete transports. These tests never create an API client.
    init(testingDisplaySession: CloudSession, sources: [CloudSource] = [], sharedSources: [CloudSharedSource] = [],
         selectedSourceIDs: Set<UUID> = [], defaults: UserDefaults,
         ownedSourcesReader: @escaping () async throws -> [CloudSource],
         receivedSourcesReader: @escaping () async throws -> [CloudSharedSource],
         eventsReader: ((UUID, DateInterval) async throws -> [CloudBusyEvent])? = nil,
         receivedSourceRemover: @escaping (UUID) async throws -> Void,
         availabilityReader: ((CloudAvailabilityRequest) async throws -> CloudAvailability)? = nil) {
        self.defaults = defaults
        endpoint = "https://display-tests.invalid"; session = testingDisplaySession
        self.sources = sources; self.sharedSources = sharedSources; selectedSharedSourceIDs = selectedSourceIDs
        testOwnedDisplayReader = ownedSourcesReader; testReceivedDisplayReader = receivedSourcesReader
        testDisplayEventsReader = eventsReader; testReceivedSourceRemover = receivedSourceRemover
        testAvailabilityReader = availabilityReader
    }
    /// Exercise actual session observers without credentials, persistence, or network access.
    func replaceDisplayTestingSession(_ value: CloudSession?, endpoint: String? = nil) {
        precondition(testOwnedDisplayReader != nil)
        if let endpoint { self.endpoint = endpoint }
        session = value
    }

    private var testSourceUpdater: ((UUID, CloudUploadLevel) async throws -> CloudSource)?
    private var testSnapshotUploader: ((CloudLocalBinding, CloudSource) async throws -> CloudSource)?
    private var testRefresher: (() async throws -> Void)?
    private var testSourceMetadataReader: ((UUID) async throws -> CloudSource?)?
    private var testSourceCreator: ((UUID, CloudCalendarOption, CloudUploadLevel) async throws -> CloudSource)?
    private var testShareLinkCreator: ((CloudSource) async throws -> CloudShareLink)?
    private var testFeedLinkCreator: ((CloudSource) async throws -> CloudFeedLink)?
    private var testSharingEventReader: ((Set<String>, DateInterval) async throws -> [SourceEventSnapshot])?
    private var testSharingSnapshotSender: ((CloudLocalBinding, CloudSource, [CloudBusyEvent], DateInterval) async throws -> CloudSource)?
    private var testSharingSourcePatcher: ((UUID, String, CloudUploadLevel) async throws -> CloudSource)?
    /// In-memory transport injection for source-management tests; it never creates an API client.
    init(testingSession: CloudSession, source: CloudSource, binding: CloudLocalBinding, defaults: UserDefaults,
         sourceUpdater: @escaping (UUID, CloudUploadLevel) async throws -> CloudSource,
         snapshotUploader: @escaping (CloudLocalBinding, CloudSource) async throws -> CloudSource,
         refresher: @escaping () async throws -> Void = {},
         invitationReader: (() async throws -> [CloudMeeting])? = nil,
         sourceMetadataReader: ((UUID) async throws -> CloudSource?)? = nil,
         sourceCreator: ((UUID, CloudCalendarOption, CloudUploadLevel) async throws -> CloudSource)? = nil,
         shareLinkCreator: ((CloudSource) async throws -> CloudShareLink)? = nil,
         feedLinkCreator: ((CloudSource) async throws -> CloudFeedLink)? = nil,
         sharingEventReader: ((Set<String>, DateInterval) async throws -> [SourceEventSnapshot])? = nil,
         sharingSnapshotSender: ((CloudLocalBinding, CloudSource, [CloudBusyEvent], DateInterval) async throws -> CloudSource)? = nil,
         sharingSourcePatcher: ((UUID, String, CloudUploadLevel) async throws -> CloudSource)? = nil) {
        self.defaults = defaults
        endpoint = "https://source-management.invalid"
        session = testingSession; sources = [source]; bindings = [binding]
        testSourceUpdater = sourceUpdater; testSnapshotUploader = snapshotUploader; testRefresher = refresher
        testInvitationReader = invitationReader
        testSourceMetadataReader = sourceMetadataReader; testSourceCreator = sourceCreator
        testShareLinkCreator = shareLinkCreator; testFeedLinkCreator = feedLinkCreator
        testSharingEventReader = sharingEventReader; testSharingSnapshotSender = sharingSnapshotSender
        testSharingSourcePatcher = sharingSourcePatcher
    }
    #endif

    #if DEBUG
    /// An in-memory invitation reader; it performs no API requests or calendar reads.
    init(testingInvitationSession: CloudSession, defaults: UserDefaults,
         invitationReader: @escaping () async throws -> [CloudMeeting]) {
        self.defaults = defaults
        endpoint = "https://invitation-tests.invalid"
        session = testingInvitationSession
        testInvitationReader = invitationReader
    }
    #endif

    var appleSignInAvailable: Bool {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { return !CloudSimulatorFixtures.passwordMode }
        #endif
        return CloudBuildConfiguration.appleSignInEnabled
    }
    var currentUserID: UUID? { session?.user.id }
    var pendingInvitationCount: Int {
        guard let currentUserID else { return 0 }
        return meetings.filter { $0.requiresInvitationResponse(from: currentUserID) }.count
    }
    var actionableInvitationCount: Int {
        guard let currentUserID else { return 0 }
        let now = Date()
        return meetings.filter {
            $0.requiresInvitationResponse(from: currentUserID, at: now) ||
                $0.requiresOrganizerConfirmation(from: currentUserID, at: now)
        }.count
    }
    var homeDisplayScope: String? { currentUserID.map { endpoint + "." + $0.uuidString } }
    /// One display catalog: owned projections first, followed by received calendars.
    /// Adding an owned source never enables its display selection automatically.
    var displaySources: [CloudSharedSource] {
        guard let user = session?.user else { return [] }
        var seen: Set<UUID> = []
        let owned = sources.filter { $0.ownerId == user.id && seen.insert($0.id).inserted }
            .map { CloudSharedSource(ownedSource: $0, ownerName: user.displayName) }
        let received = sharedSources.filter {
            $0.ownerId != user.id && !removedReceivedSourceIDs.contains($0.id) && seen.insert($0.id).inserted
        }
        return owned + received
    }
    var selectedDisplaySourceIDs: Set<UUID> { selectedSharedSourceIDs }
    private var displaySelectionKey: String { namespace + ".displaySources." + (currentUserID?.uuidString ?? "none") }
    var hasBackgroundWork: Bool { session != nil }
    private var namespace: String { "cloud." + endpoint }
    private var bindingKey: String { namespace + ".bindings." + (currentUserID?.uuidString ?? "none") }

    init(defaults: UserDefaults = .standard) {
        #if DEBUG
        self.defaults = CloudSimulatorFixtures.enabled ? CloudSimulatorFixtures.defaults() : defaults
        if CloudSimulatorFixtures.enabled {
            endpoint = CloudSimulatorFixtures.endpoint.absoluteString
            client = CloudAPIClient(baseURL: CloudSimulatorFixtures.endpoint)
            if CloudSimulatorFixtures.startsSignedIn {
                try? CloudSecureStore.save(CloudJSON.encoder().encode(CloudSimulatorFixtures.session()), key: namespace + ".session")
                restoreStoredSession()
            }
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        let isolated = arguments.contains("-cloud-ui-testing") || arguments.contains("-sharing-home-fixtures")
            || arguments.contains("-sharing-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        self.defaults = defaults
        let isolated = false
        #endif
        let configured = isolated ? "" : defaults.string(forKey: "cloud.endpoint") ?? Bundle.main.object(forInfoDictionaryKey: "ChronoGraphAPIBaseURL") as? String ?? ""
        if let url = try? CloudEndpointPolicy.validated(configured) {
            endpoint = url.absoluteString
            client = CloudAPIClient(baseURL: url)
            // Password sessions work with Personal Teams; dormant Apple sessions remain
            // saved until a build with the matching entitlement is explicitly enabled.
            restoreStoredSession()
        }
    }
    private func restoreStoredSession() {
        guard let data = CloudSecureStore.read(namespace + ".session"),
              let saved = try? CloudJSON.decoder().decode(CloudSession.self, from: data),
              saved.expiresAt > Date(), saved.canRestore(appleSignInAvailable: appleSignInAvailable) else { return }
        session = saved; client?.accessToken = saved.accessToken
        restoreBindings()
    }
    func configure(_ text: String) async {
        await perform {
            guard self.session == nil else { return }
            let url = try CloudEndpointPolicy.validated(text)
            self.endpoint = url.absoluteString
            self.defaults.set(self.endpoint, forKey: "cloud.endpoint")
            self.client = CloudAPIClient(baseURL: url)
            self.challenge = nil
            if self.appleSignInAvailable { try await self.prepareChallenge() }
            else { self.notice = CloudCopy.text("服务器地址已保存。") }
        }
    }
    func prepareSignIn() async {
        guard appleSignInAvailable else { return }
        await perform { try await self.prepareChallenge() }
    }
    private func prepareChallenge() async throws {
        guard appleSignInAvailable else { throw CloudClientError.cloudLoginUnavailable }
        guard session == nil else { return }
        challenge = try await api.request("POST", "auth/apple/challenge", authenticated: false)
    }
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard appleSignInAvailable else {
            errorMessage = CloudCopy.error(CloudClientError.cloudLoginUnavailable)
            return
        }
        guard let challenge, challenge.expiresAt > Date() else { return }
        activeChallengeID = challenge.challengeId
        request.nonce = SHA256.hash(data: Data(challenge.nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.state = challenge.challengeId.uuidString
        request.requestedScopes = []
    }
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard appleSignInAvailable else {
            errorMessage = CloudCopy.error(CloudClientError.cloudLoginUnavailable)
            return
        }
        await perform {
            guard let expected = self.activeChallengeID,
                  let credential = try result.get().credential as? ASAuthorizationAppleIDCredential,
                  credential.state?.lowercased() == expected.uuidString.lowercased(),
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else { throw CloudClientError.signIn }
            let device = try self.stableDeviceID(appleUserID: credential.user)
            struct Login: Encodable { let challengeId: UUID; let identityToken: String; let deviceId: UUID; let deviceName: String }
            let saved: CloudSession = try await self.api.request("POST", "auth/apple", body: self.api.encoded(Login(challengeId: expected, identityToken: token, deviceId: device, deviceName: "ChronoGraph iOS")), authenticated: false)
            do {
                try CloudSecureStore.save(Data(credential.user.utf8), key: self.namespace + ".appleUser")
                try CloudSecureStore.save(CloudJSON.encoder().encode(saved), key: self.namespace + ".session")
            }
            catch { self.client?.accessToken = saved.accessToken; _ = try? await self.api.send("DELETE", "auth/session"); self.client?.accessToken = nil; throw error }
            CloudSecureStore.remove(self.namespace + ".passwordUser")
            self.session = saved
            self.client?.accessToken = saved.accessToken
            self.challenge = nil
            self.restoreBindings()
            try await self.reload()
        }
        if session == nil { challenge = nil; activeChallengeID = nil; try? await prepareChallenge() }
    }
    /// Registration creates a session, but never creates a calendar source or enables upload.
    @discardableResult
    func passwordSignIn(username: String, password: String, inviteCode: String? = nil, displayName: String = "") async -> Bool {
        await perform {
            guard self.session == nil else { return }
            let username = try CloudPasswordPolicy.username(username)
            try CloudPasswordPolicy.validate(password)
            let deviceKey = try CloudDeviceIdentityPolicy.storageKey(endpoint: self.endpoint, passwordUsername: username)
            let device = try self.deviceID(for: deviceKey)
            let saved: CloudSession
            if let inviteCode {
                let invite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !invite.isEmpty else { throw CloudClientError.missingInvite }
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.unicodeScalars.count <= 100 else { throw CloudClientError.invalidDisplayName }
                struct Register: Encodable { let username: String; let password: String; let inviteCode: String; let displayName: String; let deviceId: UUID; let deviceName: String }
                saved = try await self.api.request("POST", "auth/password/register", body: self.api.encoded(Register(username: username, password: password, inviteCode: invite, displayName: name.isEmpty ? username : name, deviceId: device, deviceName: "ChronoGraph iOS")), authenticated: false)
            } else {
                struct Login: Encodable { let username: String; let password: String; let deviceId: UUID; let deviceName: String }
                saved = try await self.api.request("POST", "auth/password/login", body: self.api.encoded(Login(username: username, password: password, deviceId: device, deviceName: "ChronoGraph iOS")), authenticated: false)
            }
            guard saved.usesPassword else { throw CloudClientError.invalidResponse }
            do {
                try CloudSecureStore.save(Data(username.utf8), key: self.namespace + ".passwordUser")
                try CloudSecureStore.save(CloudJSON.encoder().encode(saved), key: self.namespace + ".session")
            } catch {
                let revoke = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(self.endpoint), accessToken: saved.accessToken)
                _ = try? await revoke.send("DELETE", "auth/session")
                throw error
            }
            CloudSecureStore.remove(self.namespace + ".appleUser")
            self.session = saved; self.client?.accessToken = saved.accessToken
            self.challenge = nil; self.activeChallengeID = nil
            self.restoreBindings()
            try await self.reload()
            self.notice = CloudCopy.text("已登录。请添加你明确允许上传的日历。")
        }
        return session?.usesPassword == true
    }
    @discardableResult
    func changePassword(current: String, new: String) async -> Bool {
        var changed = false
        await perform {
            guard self.session?.usesPassword == true else { throw CloudClientError.signIn }
            try CloudPasswordPolicy.validate(new)
            struct Change: Encodable { let currentPassword: String; let newPassword: String }
            let saved: CloudSession = try await self.api.request("POST", "auth/password/change", body: self.api.encoded(Change(currentPassword: current, newPassword: new)))
            guard saved.usesPassword, saved.user.id == self.currentUserID else { throw CloudClientError.invalidResponse }
            // The server has revoked the old token, so adopt the new token before saving.
            self.session = saved; self.client?.accessToken = saved.accessToken
            do { try CloudSecureStore.save(CloudJSON.encoder().encode(saved), key: self.namespace + ".session") }
            catch {
                _ = try? await self.api.send("DELETE", "auth/session")
                CloudSecureStore.remove(self.namespace + ".session")
                self.session = nil; self.client?.accessToken = nil
                self.bindings = []; self.selectedSharedSourceIDs = []; self.sources = []; self.sharedSources = []; self.meetings = []
                throw error
            }
            self.notice = CloudCopy.text("密码已更新，其他设备需要重新登录。")
            changed = true
        }
        return changed
    }
    func signOut() async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; notice = nil
        defer { isBusy = false }
        // Keep a separate revocation client: clearing the live client must take effect locally
        // before any network request, while this one can finish revoking the old bearer token.
        let revocation = client.map { CloudAPIClient(baseURL: $0.baseURL, accessToken: $0.accessToken) }
        CloudSecureStore.remove(namespace + ".session")
        CloudSecureStore.remove(namespace + ".appleUser")
        CloudSecureStore.remove(namespace + ".passwordUser")
        session = nil; client?.accessToken = nil; bindings = []; selectedSharedSourceIDs = []
        sources = []; sharedSources = []; meetings = []; availability = nil; lastParticipants = []
        calendars = []; lastAutomaticSync = nil
        calendarSyncStatus = nil; challenge = nil; activeChallengeID = nil
        notice = CloudCopy.text("已退出本机，正在撤销服务器会话…")
        var remoteFailure: Error?
        do { _ = try await revocation?.send("DELETE", "auth/session") }
        catch {
            if case CloudClientError.http(let status, _) = error, status == 401 { /* Already invalid. */ }
            else { remoteFailure = error }
        }
        notice = remoteFailure == nil ? CloudCopy.text("已退出此设备。") : CloudCopy.text("已退出本机；未能确认服务器会话撤销，请稍后重新登录并检查其他会话。")
        // Preparing the next Apple sign-in must not postpone the local logout result.
        if appleSignInAvailable { Task { [weak self] in try? await self?.prepareChallenge() } }
    }
    func updateDisplayName(_ value: String) async {
        await perform {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.unicodeScalars.count <= 100 else { throw CloudClientError.invalidDisplayName }
            struct Update: Encodable { let displayName: String }
            let user: CloudUser = try await self.api.request("PATCH", "me", body: self.api.encoded(Update(displayName: name)))
            try self.persistCurrentUser(user)
            self.notice = CloudCopy.text("昵称已保存，获得授权的人将看到此昵称。")
        }
    }
    func deleteAccount() async {
        await perform {
            let localBindingKey = self.bindingKey
            let localDisplayKey = self.displaySelectionKey
            let account = self.currentUserID?.uuidString ?? "none"
            let passwordDeviceKey = CloudSecureStore.read(self.namespace + ".passwordUser")
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { try? CloudDeviceIdentityPolicy.storageKey(endpoint: self.endpoint, passwordUsername: $0) }
            let deviceKey = CloudSecureStore.read(self.namespace + ".appleUser")
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { try? CloudDeviceIdentityPolicy.storageKey(endpoint: self.endpoint, appleUserID: $0) }
            _ = try await self.api.send("DELETE", "me")
            self.defaults.removeObject(forKey: localBindingKey)
            self.defaults.removeObject(forKey: localDisplayKey)
            CloudSecureStore.remove(self.namespace + ".session")
            CloudSecureStore.remove(self.namespace + ".appleUser")
            CloudSecureStore.remove(self.namespace + ".identity." + account)
            CloudSecureStore.remove(self.namespace + ".pendingMeeting." + account)
            if let deviceKey { CloudSecureStore.remove(deviceKey) }
            if let passwordDeviceKey { CloudSecureStore.remove(passwordDeviceKey) }
            CloudSecureStore.remove(self.namespace + ".passwordUser")
            self.session = nil; self.client?.accessToken = nil
            self.challenge = nil; self.activeChallengeID = nil
            self.bindings = []; self.selectedSharedSourceIDs = []; self.sources = []; self.sharedSources = []; self.meetings = []
            self.availability = nil; self.lastParticipants = []; self.calendarSyncStatus = nil
            self.notice = CloudCopy.text("云端账号已删除。系统日历和已保存的日程仍保留。")
            if self.appleSignInAvailable { try? await self.prepareChallenge() }
        }
    }
    private func persistCurrentUser(_ user: CloudUser) throws {
        guard let current = session, user.id == current.user.id else { throw CloudClientError.signIn }
        let updated = CloudSession(accessToken: current.accessToken, tokenType: current.tokenType,
            expiresAt: current.expiresAt, user: user, deviceId: current.deviceId, authProvider: current.authProvider)
        try CloudSecureStore.save(CloudJSON.encoder().encode(updated), key: namespace + ".session")
        session = updated
    }
    /// Read-only and independent of upload commands and their five-minute throttle.
    /// A failed refresh keeps the current account's last successful invitation list.
    func refreshInvitations() async {
        do { try await readInvitations(includesDisplayNames: true) }
        catch { /* The invitation-specific error is shown beside the retained list. */ }
    }
    private func resetInvitations() {
        invalidateInvitationReads()
        meetings = []
        invitationsError = nil
        invitationsLastRefreshedAt = nil
        invitationsHasLoaded = false
    }
    private func invalidateInvitationReads() {
        invitationRequestID = UUID()
        invitationsIsLoading = false
    }
    /// Apply the server's mutation response before any follow-up list refresh.
    /// Guest responses do not change a proposal's revision, so a revision-only
    /// comparison cannot prevent an older pending snapshot from restoring a badge.
    @discardableResult
    func applyConfirmedMeeting(_ updated: CloudMeeting, scope: String?, token: String?) -> Bool {
        guard matchesSession(scope: scope, token: token) else { return false }
        invalidateInvitationReads()
        if let index = meetings.firstIndex(where: { $0.id == updated.id }) { meetings[index] = updated }
        else { meetings.append(updated) }
        return true
    }
    private func readInvitations(includesDisplayNames: Bool) async throws {
        guard let scope = homeDisplayScope, let token = session?.accessToken else {
            resetInvitations()
            return
        }
        let request = UUID()
        invitationRequestID = request
        invitationsIsLoading = true
        invitationsError = nil
        defer {
            if invitationRequestID == request, matchesSession(scope: scope, token: token) {
                invitationsIsLoading = false
            }
        }
        do {
            let values: [CloudMeeting]
            let invitationReader: CloudAPIClient?
            #if DEBUG
            if let testInvitationReader {
                values = try await testInvitationReader()
                invitationReader = nil
            } else {
                let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
                invitationReader = reader
                values = try await reader.request("GET", "meetings")
            }
            #else
            let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
            invitationReader = reader
            values = try await reader.request("GET", "meetings")
            #endif
            guard invitationRequestID == request, matchesSession(scope: scope, token: token), !Task.isCancelled else { return }
            meetings = values
            invitationsHasLoaded = true
            invitationsLastRefreshedAt = Date()
            invitationsError = nil
            // Names improve the list, but unavailable name metadata must not turn
            // a successful invitation read into an empty list or an upload task.
            let namesAuthority = displayAuthorityID
            if includesDisplayNames, sharedSources.isEmpty, !values.isEmpty, let invitationReader,
               let names: [CloudSharedSource] = try? await invitationReader.request("GET", "shared-sources"),
               invitationRequestID == request, matchesSession(scope: scope, token: token), !Task.isCancelled, sharedSources.isEmpty, displayAuthorityID == namesAuthority {
                sharedSources = receivedDisplaySources(names)
            }
        } catch {
            guard invitationRequestID == request, matchesSession(scope: scope, token: token), !Task.isCancelled else { return }
            if !(error is CancellationError) { invitationsError = CloudCopy.error(error) }
            throw error
        }
    }
    private func readInvitationsForWorkspace() async throws {
        do { try await readInvitations(includesDisplayNames: false) }
        catch {
            // Invitation availability is independent of calendar uploads. The
            // inbox keeps its own error and cached list; expired credentials
            // still flow through perform's normal session cleanup.
            if case CloudClientError.http(let status, _) = error, status == 401 { throw error }
        }
    }
    func refresh() async { await perform { try await self.reload() } }
    private func reload() async throws {
        guard let reloadScope = homeDisplayScope, let reloadToken = session?.accessToken else { return }
        #if DEBUG
        if let refresher = testRefresher {
            try await refresher()
            if testInvitationReader != nil { try await readInvitationsForWorkspace() }
            return
        }
        #endif
        let reloadClient = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: reloadToken)
        try await validateAppleSession()
        guard matchesSession(scope: reloadScope, token: reloadToken), !Task.isCancelled else { return }
        let user: CloudUser = try await reloadClient.request("GET", "me")
        guard matchesSession(scope: reloadScope, token: reloadToken), !Task.isCancelled else { return }
        try persistCurrentUser(user)
        do { try await refreshSharedSourcesForDisplay() }
        catch is CancellationError { /* A newer display read or source mutation superseded this catalog. */ }
        guard matchesSession(scope: reloadScope, token: reloadToken), !Task.isCancelled else { return }
        try await readInvitationsForWorkspace()
        await reconcileCalendarTasks()
    }
    func loadCalendars() async {
        await perform { self.calendars = try await self.reader.inventory() }
    }
    @discardableResult
    func enableCalendar(_ calendar: CloudCalendarOption, level: CloudUploadLevel, range: SharedCalendarRange = .rolling()) async -> CloudSource? {
        var createdID: UUID?
        await perform {
            _ = try CloudUploadScopePolicy.interval(for: range)
            let scope = self.homeDisplayScope, token = self.session?.accessToken
            let previous = self.bindings.first { $0.calendarId == calendar.id }
            guard previous == nil || previous?.isCreationPending == true else { throw CloudClientError.missingSource }
            let id = previous?.sourceId ?? UUID()
            if let index = self.bindings.firstIndex(where: { $0.sourceId == id }) {
                self.bindings[index].pendingRange = range; self.bindings[index].pendingLevel = level
            } else {
                self.bindings.append(CloudLocalBinding(sourceId: id, calendarId: calendar.id, uploadLevel: level,
                    pendingRange: range, pendingLevel: level, isCreationPending: true))
            }
            // A committed POST whose response is lost remains recoverable under this exact UUID.
            self.persistBindings()
            let recovered = previous == nil ? nil : try await self.readUploadSource(id)
            let source: CloudSource
            if let recovered { source = recovered }
            else { source = try await self.createUploadSource(id: id, calendar: calendar, level: level) }
            guard self.matchesSession(scope: scope, token: token), source.id == id,
                  source.ownerId == self.currentUserID, source.deviceId == self.session?.deviceId,
                  let index = self.bindings.firstIndex(where: { $0.sourceId == id && $0.calendarId == calendar.id }) else { throw CloudClientError.invalidResponse }
            createdID = id
            self.bindings[index].isCreationPending = false
            self.bindings[index].uploadLevel = source.uploadLevel
            self.sources.removeAll { $0.id == id }; self.sources.append(source)
            self.persistBindings()
            let updated = source.uploadLevel == level ? source : try await self.patchUploadLevel(sourceID: id, level: level)
            guard self.matchesSession(scope: scope, token: token), updated.id == id, updated.uploadLevel == level, updated.ownerId == source.ownerId, updated.deviceId == source.deviceId,
                  let currentIndex = self.bindings.firstIndex(where: { $0.sourceId == id && $0.calendarId == calendar.id }) else { throw CancellationError() }
            self.bindings[currentIndex].uploadLevel = level
            self.sources.removeAll { $0.id == id }; self.sources.append(updated)
            self.persistBindings()
            try await self.upload(sourceID: id, metadataIsFresh: true)
        }
        return createdID.flatMap { id in sources.first { $0.id == id } }
    }
    private func createUploadSource(id: UUID, calendar: CloudCalendarOption, level: CloudUploadLevel) async throws -> CloudSource {
        #if DEBUG
        if let creator = testSourceCreator { return try await creator(id, calendar, level) }
        #endif
        let uploadClient = try api
        struct Create: Encodable { let id: UUID; let name: String; let uploadLevel: CloudUploadLevel; let deviceId: UUID }
        return try await uploadClient.request("POST", "sources", body: uploadClient.encoded(Create(id: id, name: calendar.title, uploadLevel: level, deviceId: try stableDeviceID())))
    }

    func sync() async {
        await perform {
            guard !self.bindings.isEmpty else { throw CloudClientError.noSources }
            // Pausing uploads must not stop received calendars, invitations, or local writeback reconciliation.
            try await self.reload()
            let activeBindings = self.bindings.filter { $0.isPaused != true && $0.isCreationPending != true }
            guard !activeBindings.isEmpty else {
                self.notice = self.bindings.contains(where: { $0.isCreationPending == true })
                    ? CloudCopy.text("有来源等待恢复创建。请在上传日历中选择原日历，核对已确认的上传设置后重试。")
                    : CloudCopy.text("此设备的上传均已暂停。云端内容和分享权限继续保留。")
                self.lastAutomaticSync = Date()
                return
            }
            for binding in activeBindings { try Task.checkCancellation(); try await self.upload(sourceID: binding.sourceId) }
            self.lastAutomaticSync = Date()
            self.availability = nil
            self.notice = CloudCopy.text("已上传所选日历的允许字段。未向他人自动开放访问。")
        }
    }
    func automaticSyncIfEnabled() async {
        guard session != nil, !isBusy,
              lastAutomaticSync.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        if bindings.isEmpty { await refresh(); lastAutomaticSync = Date() }
        else { await sync() }
    }
    func removeSource(_ source: CloudSource) async {
        await perform {
            _ = try await self.api.send("DELETE", "sources/\(source.id.uuidString)")
            self.bindings.removeAll { $0.sourceId == source.id }; self.persistBindings()
            try await self.reload()
            self.availability = nil
        }
    }
    func isUploadPaused(_ sourceID: UUID) -> Bool {
        bindings.first { $0.sourceId == sourceID }?.isPaused == true
    }
    func displayName(for userID: UUID) -> String {
        if userID == currentUserID { return CloudCopy.text("我") }
        return sharedSources.first { $0.ownerId == userID }?.ownerName ?? CloudCopy.text("参与者")
    }
    /// Pause affects this installation only. Server snapshots, links, and grants are untouched.
    func setUploadPaused(_ sourceID: UUID, paused: Bool) async {
        await perform {
            let scope = self.homeDisplayScope, token = self.session?.accessToken
            guard let index = self.bindings.firstIndex(where: { $0.sourceId == sourceID }),
                  self.sources.contains(where: { $0.id == sourceID && $0.deviceId == self.session?.deviceId }) else {
                throw CloudClientError.missingSource
            }
            self.bindings[index].isPaused = paused
            self.persistBindings()
            self.availability = nil
            if !paused {
                do { try await self.upload(sourceID: sourceID) }
                catch {
                    if self.matchesSession(scope: scope, token: token), let currentIndex = self.bindings.firstIndex(where: { $0.sourceId == sourceID }) {
                        self.bindings[currentIndex].isPaused = true
                        self.persistBindings()
                    }
                    throw error
                }
            }
            guard self.matchesSession(scope: scope, token: token) else { throw CancellationError() }
            self.notice = (paused ? CloudCopy.text("此设备已暂停上传。已有云端内容和分享权限继续保留。") : CloudCopy.text("已恢复此设备上传，并更新允许的日程内容。"))
        }
    }
    /// Compatibility entry point: field-only edits preserve the already confirmed date selection.
    func changeUploadLevel(sourceID: UUID, level: CloudUploadLevel) async {
        let range = bindings.first(where: { $0.sourceId == sourceID })?.uploadRange ?? .rolling()
        await changeUploadScope(sourceID: sourceID, level: level, range: range)
    }
    /// Save the complete confirmed scope before any PATCH. Unknown server outcomes cannot erase intent.
    @discardableResult
    func changeUploadScope(sourceID: UUID, level: CloudUploadLevel, range: SharedCalendarRange) async -> CloudSource? {
        var completed = false
        await perform {
            _ = try CloudUploadScopePolicy.interval(for: range)
            let scope = self.homeDisplayScope, token = self.session?.accessToken
            guard let originalBinding = self.bindings.first(where: { $0.sourceId == sourceID }),
                  let originalSource = self.sources.first(where: { $0.id == sourceID }), originalSource.deviceId == self.session?.deviceId,
                  let intentIndex = self.bindings.firstIndex(where: { $0.sourceId == sourceID }) else { throw CloudClientError.missingSource }
            self.bindings[intentIndex].pendingRange = range
            self.bindings[intentIndex].pendingLevel = level
            self.persistBindings()
            guard let source = try await self.readUploadSource(sourceID), source.deviceId == self.session?.deviceId else { throw CloudClientError.missingSource }
            let updated = level == source.uploadLevel ? source : try await self.patchUploadLevel(sourceID: sourceID, level: level)
            guard self.matchesSession(scope: scope, token: token),
                  let index = self.bindings.firstIndex(where: { $0.sourceId == sourceID && $0.calendarId == originalBinding.calendarId }) else { throw CancellationError() }
            guard updated.id == sourceID, updated.ownerId == source.ownerId, updated.deviceId == source.deviceId,
                  updated.uploadLevel == level else { throw CloudClientError.invalidResponse }
            let requiresSnapshot = !self.isUploadPaused(sourceID) || range != originalBinding.confirmedRange
                || originalBinding.hasPendingScope || source.coverageStart == nil || source.coverageEnd == nil
            self.bindings[index].uploadLevel = updated.uploadLevel
            self.bindings[index].isCreationPending = false
            self.sources.removeAll { $0.id == sourceID }; self.sources.append(updated)
            self.persistBindings()
            self.availability = nil
            if requiresSnapshot {
                try await self.upload(sourceID: sourceID, applyingConfirmedRange: true, metadataIsFresh: true)
            } else {
                // A field-only change on a paused source is complete after the authoritative PATCH.
                self.bindings[index].pendingRange = nil; self.bindings[index].pendingLevel = nil
                self.persistBindings()
            }
            guard self.matchesSession(scope: scope, token: token) else { throw CancellationError() }
            self.notice = CloudCopy.text("上传授权已更新。已收紧的链接和访问授权不会自动扩大。")
            completed = true
        }
        return completed ? sources.first { $0.id == sourceID } : nil
    }
    private func patchUploadLevel(sourceID: UUID, level: CloudUploadLevel) async throws -> CloudSource {
        #if DEBUG
        if let updater = testSourceUpdater { return try await updater(sourceID, level) }
        #endif
        struct Change: Encodable { let uploadLevel: CloudUploadLevel }
        return try await api.request("PATCH", "sources/\(sourceID.uuidString)", body: api.encoded(Change(uploadLevel: level)))
    }
    /// Refresh this source's generation without discarding any local confirmed scope intent.
    private func readUploadSource(_ sourceID: UUID) async throws -> CloudSource? {
        let scope = homeDisplayScope, token = session?.accessToken
        let value: CloudSource?
        #if DEBUG
        if let reader = testSourceMetadataReader { value = try await reader(sourceID) }
        else if testSourceUpdater != nil { value = sources.first { $0.id == sourceID } }
        else { value = try await readUploadSourceFromAPI(sourceID) }
        #else
        value = try await readUploadSourceFromAPI(sourceID)
        #endif
        guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
        if let value {
            guard value.id == sourceID, value.ownerId == currentUserID else { throw CloudClientError.invalidResponse }
            sources.removeAll { $0.id == sourceID }; sources.append(value)
        }
        return value
    }
    private func readUploadSourceFromAPI(_ sourceID: UUID) async throws -> CloudSource? {
        let readClient = try api
        let values: [CloudSource] = try await readClient.request("GET", "sources")
        return values.first { $0.id == sourceID }
    }

    private func matchesSession(scope: String?, token: String?) -> Bool {
        scope != nil && token != nil && homeDisplayScope == scope && session?.accessToken == token
    }
    private func upload(sourceID: UUID, applyingConfirmedRange: Bool = false, metadataIsFresh: Bool = false) async throws {
        let scope = homeDisplayScope, token = session?.accessToken
        guard let binding = bindings.first(where: { $0.sourceId == sourceID }),
              var source = sources.first(where: { $0.id == sourceID }) else { throw CloudClientError.missingSource }
        guard binding.isPaused != true || applyingConfirmedRange else { return }
        if binding.pendingSharing != nil || binding.sharing != nil {
            try await uploadSharingConfiguration(binding: binding, source: source, metadataIsFresh: metadataIsFresh)
            return
        }
        guard binding.isCreationPending != true else { throw CloudUploadScopeError.updatePending }
        if binding.hasPendingScope && !metadataIsFresh {
            guard let latest = try await readUploadSource(sourceID) else { throw CloudClientError.missingSource }
            source = latest
        }
        if let intendedLevel = binding.pendingLevel {
            guard binding.uploadLevel == intendedLevel, source.uploadLevel == intendedLevel else { throw CloudUploadScopeError.updatePending }
        }
        guard binding.uploadLevel == source.uploadLevel else { throw CloudClientError.http(409, CloudCopy.text("云端上传范围已改变，请删除本机绑定并重新审阅授权。")) }
        #if DEBUG
        if let uploader = testSnapshotUploader {
            let updated = try await uploader(binding, source)
            guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
            guard updated.id == binding.sourceId, updated.ownerId == source.ownerId, updated.deviceId == source.deviceId,
                  updated.uploadLevel == binding.uploadLevel else { throw CloudClientError.invalidResponse }
            self.completeUpload(updated, binding: binding)
            return
        }
        #endif
        let uploadClient = try api
        let key = try identityKey()
        let interval = try CloudUploadScopePolicy.interval(for: binding.uploadRange)
        let original = try await reader.events(calendarID: binding.calendarId, interval: interval)
        guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
        let projected = try original.filter { $0.startDate < interval.end && $0.endDate > interval.start }
            .map { try CloudSnapshotProjection.project($0, sourceID: sourceID, level: binding.uploadLevel, key: key) }
        let snapshot = CloudSnapshot(snapshotId: UUID(), expectedGeneration: source.generation,
                                     windowStart: interval.start, windowEnd: interval.end, events: projected)
        let updated: CloudSource = try await uploadClient.request("PUT", "sources/\(sourceID.uuidString)/snapshot", body: uploadClient.encoded(snapshot))
        guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
        guard updated.id == binding.sourceId, updated.ownerId == source.ownerId, updated.deviceId == source.deviceId,
              updated.uploadLevel == binding.uploadLevel else { throw CloudClientError.invalidResponse }
        completeUpload(updated, binding: binding)
    }
    private func completeUpload(_ updated: CloudSource, binding: CloudLocalBinding) {
        sources.removeAll { $0.id == updated.id }; sources.append(updated)
        if let pending = binding.pendingRange,
           let index = bindings.firstIndex(where: { $0.sourceId == binding.sourceId && $0.calendarId == binding.calendarId && $0.pendingRange == pending && $0.pendingLevel == binding.pendingLevel }) {
            bindings[index].range = pending
            bindings[index].pendingRange = nil
            bindings[index].pendingLevel = nil
            bindings[index].isCreationPending = false
            persistBindings()
        }
    }
    private func shareableSource(_ reviewed: CloudSource) throws -> CloudSource {
        guard let source = sources.first(where: { $0.id == reviewed.id && $0.ownerId == currentUserID }) else { throw CloudClientError.missingSource }
        guard bindings.first(where: { $0.sourceId == reviewed.id })?.hasPendingScope != true else { throw CloudUploadScopeError.updatePending }
        guard source.coverageStart != nil, source.coverageEnd != nil else { throw CloudClientError.coverage }
        guard source.ownerId == reviewed.ownerId, source.deviceId == reviewed.deviceId,
              source.uploadLevel == reviewed.uploadLevel, source.generation == reviewed.generation,
              source.coverageStart == reviewed.coverageStart, source.coverageEnd == reviewed.coverageEnd else {
            throw CloudUploadScopeError.reviewChanged
        }
        // Only the snapshot whose scope the caller reviewed may authorize a new link.
        return reviewed
    }
    func createShareLink(_ source: CloudSource) async -> CloudShareLink? {
        var result: CloudShareLink?
        await perform {
            let source = try self.shareableSource(source)
            #if DEBUG
            if let creator = self.testShareLinkCreator { result = try await creator(source); return }
            #endif
            struct Create: Encodable { let privacy: CloudUploadLevel }
            result = try await self.api.request("POST", "sources/\(source.id.uuidString)/share-links", body: self.api.encoded(Create(privacy: source.uploadLevel)))
        }
        return result
    }
    func createFeedLink(_ source: CloudSource) async -> CloudFeedLink? {
        var result: CloudFeedLink?
        await perform {
            let source = try self.shareableSource(source)
            #if DEBUG
            if let creator = self.testFeedLinkCreator { result = try await creator(source); return }
            #endif
            struct Create: Encodable { let privacy: CloudUploadLevel }
            result = try await self.api.request("POST", "sources/\(source.id.uuidString)/feed-links", body: self.api.encoded(Create(privacy: source.uploadLevel)))
        }
        return result
    }
    func redeem(_ value: String) async {
        await perform {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = URL(string: trimmed)
            let token = URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "token" })?.value
                ?? (parsed?.scheme != nil ? parsed?.lastPathComponent : nil) ?? trimmed
            struct Redeem: Encodable { let token: String }
            let scope = self.homeDisplayScope, sessionToken = self.session?.accessToken
            let source: CloudSharedSource = try await self.api.request("POST", "share-links/redeem", body: self.api.encoded(Redeem(token: token)))
            guard self.matchesSession(scope: scope, token: sessionToken) else { throw CancellationError() }
            self.removedReceivedSourceIDs.remove(source.id)
            self.invalidateDisplayReads()
            try await self.reload(); self.availability = nil
        }
    }
    func search(selectedPeople: Set<UUID>, days: Int, duration: Int, dailyStart: String, dailyEnd: String) async {
        await perform {
            guard let userID = self.currentUserID else { throw CloudClientError.signIn }
            let scope = self.homeDisplayScope, token = self.session?.accessToken, authority = self.displayAuthorityID
            let own = self.sources.map(\.id)
            guard !own.isEmpty else { throw CloudClientError.noSources }
            var participants = [CloudParticipant(userId: userID, sourceIds: own)]
            for person in selectedPeople.sorted(by: { $0.uuidString < $1.uuidString }) {
                let ids = self.sharedSources.filter { $0.ownerId == person }.map(\.id)
                guard !ids.isEmpty else { throw CloudClientError.missingSource }
                participants.append(CloudParticipant(userId: person, sourceIds: ids))
            }
            guard participants.count >= 2 else { throw CloudClientError.coverage }
            let now = Date(); let calendar = Calendar.current
            let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
            let request = CloudAvailabilityRequest(participants: participants, windowStart: now, windowEnd: end,
                durationMinutes: duration, timezone: TimeZone.current.identifier, dailyStart: dailyStart, dailyEnd: dailyEnd)
            self.availability = nil
            let result = try await self.readAvailability(request)
            guard self.matchesSession(scope: scope, token: token), self.displayAuthorityID == authority, !Task.isCancelled else { return }
            self.lastParticipants = participants; self.availability = result
        }
    }
    private func readAvailability(_ request: CloudAvailabilityRequest) async throws -> CloudAvailability {
        #if DEBUG
        if let reader = testAvailabilityReader { return try await reader(request) }
        #endif
        let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: session?.accessToken)
        return try await reader.request("POST", "availability/search", body: reader.encoded(request))
    }
    func propose(_ candidate: CloudCandidate, title: String) async {
        await perform {
            let scope = self.homeDisplayScope, token = self.session?.accessToken
            guard !self.lastParticipants.isEmpty else { throw CloudClientError.coverage }
            var request = CloudCreateMeeting(requestId: UUID(), title: title, start: candidate.suggestedStart, end: candidate.suggestedEnd,
                timezone: self.availability?.timezone ?? TimeZone.current.identifier, participants: self.lastParticipants)
            let pendingKey = self.namespace + ".pendingMeeting." + (self.currentUserID?.uuidString ?? "none")
            if let data = CloudSecureStore.read(pendingKey), let pending = try? CloudJSON.decoder().decode(CloudCreateMeeting.self, from: data), pending.samePayload(as: request) {
                request.requestId = pending.requestId
            }
            let body = try self.api.encoded(request)
            try CloudSecureStore.save(body, key: pendingKey)
            self.invalidateInvitationReads()
            let updated: CloudMeeting = try await self.api.request("POST", "meetings", body: body)
            guard self.applyConfirmedMeeting(updated, scope: scope, token: token) else { return }
            CloudSecureStore.remove(pendingKey)
            try await self.reload(); self.notice = CloudCopy.text("邀约已保存，等待参与者回应。")
        }
    }
    func meetingAction(_ meeting: CloudMeeting, action: String, response: String? = nil) async {
        await perform {
            let scope = self.homeDisplayScope, token = self.session?.accessToken
            self.invalidateInvitationReads()
            struct Action: Encodable { let revision: Int; let response: String? }
            let updated: CloudMeeting = try await self.api.request("POST", "meetings/\(meeting.id.uuidString)/\(action)", body: self.api.encoded(Action(revision: meeting.revision, response: response)))
            guard self.applyConfirmedMeeting(updated, scope: scope, token: token) else { return }
            try await self.reload()
        }
    }
    func revokeFeed(_ link: CloudFeedLink) async {
        await perform { _ = try await self.api.send("DELETE", "feed-links/\(link.id.uuidString)") }
    }
    func invalidateCandidates() { availability = nil; lastParticipants = [] }
    private var calendarNamespace: String { endpoint + "." + (currentUserID?.uuidString ?? "none") }
    func saveCalendar(_ displayed: CloudMeeting, calendarID: String) async throws {
        let current: CloudMeeting = try await api.request("GET", "meetings/\(displayed.id.uuidString)")
        guard current.status == "confirmed", current.revision == displayed.revision else {
            throw CloudClientError.http(409, CloudCopy.text("约定已经改期或取消，请刷新后重试。"))
        }
        try await calendarWriter.save(current, calendarID: calendarID, namespace: calendarNamespace)
        // The external calendar write cannot be atomic with a backend transaction. Recheck and converge.
        let after: CloudMeeting = try await api.request("GET", "meetings/\(displayed.id.uuidString)")
        if after.status != "confirmed" || after.revision != current.revision {
            _ = try await calendarWriter.reconcile(after, namespace: calendarNamespace)
            throw CloudClientError.http(409, CloudCopy.text("保存期间约定发生变化，已核对本机日程。请刷新邀约。"))
        }
        try await acknowledgeCalendarWrite(current)
    }
    func removeCalendarProjection(_ meeting: CloudMeeting) async throws {
        let current: CloudMeeting = try await api.request("GET", "meetings/\(meeting.id.uuidString)")
        guard current.status != "confirmed" else { throw CloudClientError.http(409, CloudCopy.text("约定当前仍已定档，未移除日程。")) }
        try await calendarWriter.remove(current, namespace: calendarNamespace)
        try await acknowledgeCalendarWrite(current, action: "delete")
    }
    private func reconcileCalendarTasks() async {
        guard session != nil else { return }
        do {
            let device = try stableDeviceID()
            let tasks: [CloudDeviceTask] = try await api.request("GET", "device-tasks?device_id=\(device.uuidString)")
            var handled = Set<UUID>(), waiting = 0, failures = 0
            for task in tasks {
                try Task.checkCancellation()
                guard handled.insert(task.meetingId).inserted else { continue }
                do {
                    let current: CloudMeeting = try await api.request("GET", "meetings/\(task.meetingId.uuidString)")
                    guard try await calendarWriter.reconcile(current, namespace: calendarNamespace) else { waiting += 1; continue }
                    // All older queue records have converged to a current authoritative projection.
                    for item in tasks where item.meetingId == current.id && item.revision <= current.revision {
                        _ = try await api.send("POST", "device-tasks/\(item.id.uuidString)/ack")
                    }
                } catch { failures += 1 }
            }
            calendarSyncStatus = failures > 0 ? CloudCopy.format("%d份本机日程需要检查（权限、网络或手动更改）；未强制覆盖。", failures) : waiting > 0 ? CloudCopy.format("%d个约定等待你选择日历保存。", waiting) : CloudCopy.text("已核对本机日历写回状态。")
        } catch { calendarSyncStatus = CloudCopy.text("暂未能核对日历写回任务；原日程保持不变。") }
    }
    func acknowledgeCalendarWrite(_ meeting: CloudMeeting, action: String = "upsert") async throws {
        let deviceID = try stableDeviceID()
        let tasks: [CloudDeviceTask] = try await api.request("GET", "device-tasks?device_id=\(deviceID.uuidString)")
        // Only acknowledge the exact revision actually persisted by this device.
        for task in tasks where task.meetingId == meeting.id && task.revision == meeting.revision && task.action == action {
            _ = try await api.send("POST", "device-tasks/\(task.id.uuidString)/ack")
        }
    }
    func accessRecords(source: CloudSource, kind: String) async -> [CloudAccessRecord] {
        var output: [CloudAccessRecord] = []
        await perform { output = try await self.api.request("GET", "sources/\(source.id.uuidString)/\(kind)") }
        return output
    }
    func revokeAccess(source: CloudSource, kind: String, id: UUID) async {
        await perform {
            let path = kind == "grants" ? "sources/\(source.id.uuidString)/grants/\(id.uuidString)" : "\(kind)/\(id.uuidString)"
            _ = try await self.api.send("DELETE", path)
        }
    }
    private var api: CloudAPIClient {
        get throws {
            guard let client else { throw CloudClientError.invalidEndpoint }
            return client
        }
    }
    private func validateAppleSession() async throws {
        guard session?.usesPassword != true else { return }
        guard appleSignInAvailable else { throw CloudClientError.cloudLoginUnavailable }
        guard let data = CloudSecureStore.read(namespace + ".appleUser"), let appleUser = String(data: data, encoding: .utf8) else { return }
        let state: ASAuthorizationAppleIDProvider.CredentialState = try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUser) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state) }
            }
        }
        guard state == .authorized else {
            _ = try? await api.send("DELETE", "auth/session")
            throw CloudClientError.http(401, CloudCopy.text("Apple 登录授权已改变，请重新登录。"))
        }
    }
    private func stableDeviceID(appleUserID: String? = nil) throws -> UUID {
        // Once authenticated, the server session is the authority for the current account's device.
        if appleUserID == nil, let session { return session.deviceId }
        guard let appleUserID else { throw CloudClientError.signIn }
        let key = try CloudDeviceIdentityPolicy.storageKey(endpoint: endpoint, appleUserID: appleUserID)
        return try deviceID(for: key)
    }
    private func deviceID(for key: String) throws -> UUID {
        if let data = CloudSecureStore.read(key), let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        try CloudSecureStore.save(Data(id.uuidString.utf8), key: key)
        return id
    }
    private func identityKey() throws -> Data {
        let key = namespace + ".identity." + (currentUserID?.uuidString ?? "none")
        if let saved = CloudSecureStore.read(key) { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CloudClientError.keychain(status) }
        let data = Data(bytes); try CloudSecureStore.save(data, key: key); return data
    }
    func toggleDisplaySource(_ id: UUID) {
        guard session != nil, displaySources.contains(where: { $0.id == id }) else { return }
        if selectedSharedSourceIDs.contains(id) { selectedSharedSourceIDs.remove(id) }
        else { selectedSharedSourceIDs.insert(id) }
        persistDisplaySelection()
    }
    func selectAllDisplaySources() {
        selectedSharedSourceIDs = Set(displaySources.map(\.id)); persistDisplaySelection()
    }
    func clearDisplaySourceSelection() { selectedSharedSourceIDs = []; persistDisplaySelection() }
    // Persisted names and call sites from older versions remain compatible.
    func toggleSharedSourceDisplay(_ id: UUID) { toggleDisplaySource(id) }
    func selectAllSharedSourcesForDisplay() { selectAllDisplaySources() }
    func clearSharedSourceDisplay() { clearDisplaySourceSelection() }
    private func persistDisplaySelection() {
        guard session != nil else { return }
        defaults.set(selectedSharedSourceIDs.map(\.uuidString).sorted(), forKey: displaySelectionKey)
    }
    private func pruneDisplaySelection() {
        selectedSharedSourceIDs.formIntersection(Set(displaySources.map(\.id)))
        persistDisplaySelection()
    }
    private func invalidateDisplayReads() {
        homeSourcesRequestID = UUID(); displayAuthorityID = UUID()
    }
    private func resetDisplaySession(clearSources: Bool) {
        invalidateDisplayReads()
        receivedRemovalRequestID = UUID(); isRemovingReceivedSource = false; removeReceivedSourceError = nil
        if clearSources {
            removedReceivedSourceIDs = []; sources = []; sharedSources = []; selectedSharedSourceIDs = []
        }
    }
    private func receivedDisplaySources(_ values: [CloudSharedSource]) -> [CloudSharedSource] {
        var seen: Set<UUID> = []
        return values.filter { value in
            value.ownerId != currentUserID && !sources.contains(where: { $0.id == value.id })
                && !removedReceivedSourceIDs.contains(value.id) && seen.insert(value.id).inserted
        }
    }
    /// Reads both halves atomically. Partial failures retain metadata and persisted selection.
    func refreshSharedSourcesForDisplay() async throws {
        guard let scope = homeDisplayScope, let token = session?.accessToken else { return }
        let request = UUID(), authority = displayAuthorityID
        homeSourcesRequestID = request
        let owned: [CloudSource]
        let received: [CloudSharedSource]
        #if DEBUG
        if let ownedReader = testOwnedDisplayReader, let receivedReader = testReceivedDisplayReader {
            owned = try await ownedReader()
            received = try await receivedReader()
        } else {
            let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
            owned = try await reader.request("GET", "sources")
            received = try await reader.request("GET", "shared-sources")
        }
        #else
        let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
        owned = try await reader.request("GET", "sources")
        received = try await reader.request("GET", "shared-sources")
        #endif
        guard homeSourcesRequestID == request, displayAuthorityID == authority,
              matchesSession(scope: scope, token: token), !Task.isCancelled else { throw CancellationError() }
        guard owned.allSatisfy({ $0.ownerId == currentUserID }) else { throw CloudClientError.invalidResponse }
        sources = owned; sharedSources = receivedDisplaySources(received)
        pruneDisplaySelection()
    }
    func fetchSharedEvents(source: CloudSharedSource, interval: DateInterval) async throws -> [CloudBusyEvent] {
        guard let scope = homeDisplayScope, let token = session?.accessToken,
              displaySources.contains(source) else { throw CloudClientError.missingSource }
        let authority = displayAuthorityID
        let values: [CloudBusyEvent]
        #if DEBUG
        if let reader = testDisplayEventsReader { values = try await reader(source.id, interval) }
        else { values = try await readDisplayEvents(sourceID: source.id, interval: interval, token: token) }
        #else
        values = try await readDisplayEvents(sourceID: source.id, interval: interval, token: token)
        #endif
        guard matchesSession(scope: scope, token: token), displayAuthorityID == authority,
              displaySources.contains(source), !Task.isCancelled else { throw CancellationError() }
        return values
    }
    private func readDisplayEvents(sourceID: UUID, interval: DateInterval, token: String) async throws -> [CloudBusyEvent] {
        let reader = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
        func timestamp(_ value: Date) throws -> String {
            try JSONDecoder().decode(String.self, from: CloudJSON.encoder().encode(value))
        }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "start", value: try timestamp(interval.start)),
                            URLQueryItem(name: "end", value: try timestamp(interval.end))]
        return try await reader.request("GET", "sources/\(sourceID.uuidString)/events?" + (query.percentEncodedQuery ?? ""))
    }
    /// Revoke only this account's received grant; uploading calendars and other recipients are untouched.
    @discardableResult
    func removeReceivedSource(sourceID: UUID) async -> Bool {
        guard !isRemovingReceivedSource, let scope = homeDisplayScope, let token = session?.accessToken else { return false }
        guard sharedSources.contains(where: { $0.id == sourceID && $0.ownerId != currentUserID }),
              !sources.contains(where: { $0.id == sourceID }) else {
            removeReceivedSourceError = CloudCopy.error(CloudClientError.missingSource)
            return false
        }
        let request = UUID()
        receivedRemovalRequestID = request; isRemovingReceivedSource = true; removeReceivedSourceError = nil
        invalidateDisplayReads()
        defer {
            if receivedRemovalRequestID == request, matchesSession(scope: scope, token: token) { isRemovingReceivedSource = false }
        }
        do {
            #if DEBUG
            if let remover = testReceivedSourceRemover { try await remover(sourceID) }
            else { try await deleteReceivedSource(sourceID, token: token) }
            #else
            try await deleteReceivedSource(sourceID, token: token)
            #endif
            guard receivedRemovalRequestID == request, matchesSession(scope: scope, token: token) else { return false }
            removedReceivedSourceIDs.insert(sourceID)
            invalidateDisplayReads()
            sharedSources.removeAll { $0.id == sourceID }
            selectedSharedSourceIDs.remove(sourceID); persistDisplaySelection()
            availability = nil; lastParticipants = []
            return true
        } catch {
            guard receivedRemovalRequestID == request, matchesSession(scope: scope, token: token) else { return false }
            removeReceivedSourceError = CloudCopy.error(error)
            return false
        }
    }
    private func deleteReceivedSource(_ sourceID: UUID, token: String) async throws {
        let removal = CloudAPIClient(baseURL: try CloudEndpointPolicy.validated(endpoint), accessToken: token)
        _ = try await removal.send("DELETE", "shared-sources/\(sourceID.uuidString)")
    }
    private func restoreBindings() {
        selectedSharedSourceIDs = Set((defaults.stringArray(forKey: displaySelectionKey) ?? []).compactMap(UUID.init(uuidString:)))
        bindings = defaults.data(forKey: bindingKey).flatMap { try? JSONDecoder().decode([CloudLocalBinding].self, from: $0) } ?? []
    }
    private func persistBindings() { if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: bindingKey) } }
    private func perform(_ action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; notice = nil
        defer { isBusy = false }
        do { try await action() }
        catch {
            errorMessage = CloudCopy.error(error)
            if case CloudClientError.http(let status, _) = error, status == 401 {
                CloudSecureStore.remove(namespace + ".session")
                CloudSecureStore.remove(namespace + ".appleUser")
                CloudSecureStore.remove(namespace + ".passwordUser")
                session = nil; client?.accessToken = nil; bindings = []; selectedSharedSourceIDs = []
                sources = []; sharedSources = []; meetings = []; availability = nil; lastParticipants = []
                calendars = []; lastAutomaticSync = nil
                calendarSyncStatus = nil; challenge = nil; activeChallengeID = nil
                if appleSignInAvailable { try? await prepareChallenge() }
            }
        }
    }
}

extension CloudWorkspaceManager {
    var pendingSharingDrafts: [CloudSharingDraft] { bindings.compactMap(\.pendingSharing) }

    func makeSharingDraft(sourceID: UUID? = nil) throws -> CloudSharingDraft {
        guard let sourceID else { return CloudSharingDraft() }
        guard let binding = bindings.first(where: { $0.sourceId == sourceID }) else { throw CloudClientError.missingSource }
        var draft: CloudSharingDraft
        if let stored = binding.pendingSharing ?? binding.sharing { draft = stored }
        else {
            let level = binding.pendingLevel ?? binding.uploadLevel
            draft = CloudSharingDraft(id: sourceID, name: sources.first { $0.id == sourceID }?.name ?? calendars.first { $0.id == binding.calendarId }?.title ?? CloudCopy.text("共享日历"),
                calendarIDs: binding.calendarIds ?? [binding.calendarId], defaultVisibility: SharedVisibility(rawValue: level.rawValue) ?? .opaque,
                range: binding.uploadRange, legacyCalendarID: binding.calendarId)
        }
        draft.baseRevision = binding.sharingRevision ?? 0
        draft.baseGeneration = sources.first { $0.id == sourceID }?.generation
        return draft
    }

    /// A complete read and local rule projection; no calendar, rule or cloud snapshot is written.
    func previewSharing(draft: CloudSharingDraft) async throws -> CloudSharingPreview {
        sharingReview = nil
        try CloudSharingPolicy.validate(draft)
        guard let scope = homeDisplayScope, let token = session?.accessToken else { throw CloudClientError.signIn }
        let revision = bindings.first { $0.sourceId == draft.id }?.sharingRevision ?? 0
        guard revision == draft.baseRevision else { throw CloudSharingError.reviewExpired }
        var candidate = draft
        if bindings.contains(where: { $0.sourceId == draft.id }) || sources.contains(where: { $0.id == draft.id }) {
            candidate.baseGeneration = try await readUploadSource(draft.id)?.generation
        } else { candidate.baseGeneration = nil }
        let reviewTime = Date()
        let interval = try CloudUploadScopePolicy.interval(for: candidate.range, now: reviewTime)
        let snapshots = try await readSharingEvents(calendarIDs: candidate.calendarIDs, interval: interval)
        guard matchesSession(scope: scope, token: token), (bindings.first { $0.sourceId == draft.id }?.sharingRevision ?? 0) == revision else { throw CloudSharingError.reviewExpired }
        let preview = try CloudSharingPolicy.preview(draft: candidate, snapshots: snapshots, now: reviewTime)
        // Validate wire limits during review without creating a persistent identity secret.
        _ = try CloudSharingPolicy.project(preview, key: Data(repeating: 0, count: 32))
        sharingReview = CloudSharingReviewRecord(preview: preview, scope: scope, token: token)
        return preview
    }

    /// Only the registered review's frozen events may be uploaded by this confirmation.
    @discardableResult
    func saveSharing(preview: CloudSharingPreview) async -> CloudSource? {
        guard !isBusy else { errorMessage = CloudCopy.error(CloudSharingError.busy); return nil }
        var completed: CloudSource?
        await perform {
            guard let record = self.sharingReview, record.preview.reviewID == preview.reviewID,
                  record.preview.draft == preview.draft, record.preview.interval == preview.interval,
                  self.matchesSession(scope: record.scope, token: record.token),
                  (self.bindings.first { $0.sourceId == preview.draft.id }?.sharingRevision ?? 0) == preview.draft.baseRevision,
                  try CloudUploadScopePolicy.interval(for: preview.draft.range) == record.preview.interval else { throw CloudSharingError.reviewExpired }
            let frozen = record.preview
            var draft = frozen.draft
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = try await self.readUploadSource(draft.id)
            guard self.matchesSession(scope: record.scope, token: record.token),
                  existing?.generation == draft.baseGeneration else { throw CloudSharingError.reviewExpired }
            if let existing { guard existing.ownerId == self.currentUserID, existing.deviceId == self.session?.deviceId else { throw CloudClientError.missingSource } }
            let level = draft.uploadLevel
            if let index = self.bindings.firstIndex(where: { $0.sourceId == draft.id }) {
                self.bindings[index].pendingSharing = draft
                self.bindings[index].pendingRange = draft.range; self.bindings[index].pendingLevel = level
                self.bindings[index].sharingRevision = (self.bindings[index].sharingRevision ?? 0) + 1
                if existing == nil { self.bindings[index].isCreationPending = true }
            } else {
                self.bindings.append(CloudLocalBinding(sourceId: draft.id, calendarId: draft.calendarIDs.sorted().first!, uploadLevel: level,
                    pendingRange: draft.range, pendingLevel: level, isCreationPending: true,
                    calendarIds: draft.calendarIDs, pendingSharing: draft, sharingRevision: 1))
            }
            self.persistBindings()
            let source: CloudSource
            if let existing { source = existing }
            else {
                let calendar = CloudCalendarOption(id: draft.calendarIDs.sorted().first!, title: draft.name, account: "")
                source = try await self.createUploadSource(id: draft.id, calendar: calendar, level: level)
            }
            guard self.matchesSession(scope: record.scope, token: record.token), source.id == draft.id,
                  source.ownerId == self.currentUserID, source.deviceId == self.session?.deviceId else { throw CloudClientError.invalidResponse }
            let updated: CloudSource
            if source.name == draft.name && source.uploadLevel == level { updated = source }
            else { updated = try await self.patchSharingSource(sourceID: source.id, name: draft.name, level: level) }
            guard self.matchesSession(scope: record.scope, token: record.token), updated.id == draft.id,
                  updated.ownerId == source.ownerId, updated.deviceId == source.deviceId,
                  updated.name == draft.name, updated.uploadLevel == level,
                  let index = self.bindings.firstIndex(where: { $0.sourceId == draft.id }) else { throw CloudClientError.invalidResponse }
            self.bindings[index].uploadLevel = level
            self.bindings[index].isCreationPending = false
            self.sources.removeAll { $0.id == updated.id }; self.sources.append(updated)
            self.persistBindings()
            let binding = self.bindings[index]
            let result = try await self.sendSharingSnapshot(frozen, binding: binding, source: updated)
            guard self.matchesSession(scope: record.scope, token: record.token) else { throw CancellationError() }
            self.completeSharingUpload(result, binding: binding, draft: draft)
            self.sharingReview = nil
            self.availability = nil
            self.notice = CloudCopy.text("共享配置已更新。排除的事项不会上传，也不会用于对方查找共同时间。")
            completed = result
        }
        return completed
    }

    private func readSharingEvents(calendarIDs: Set<String>, interval: DateInterval) async throws -> [SourceEventSnapshot] {
        #if DEBUG
        if let read = testSharingEventReader { return try await read(calendarIDs, interval) }
        #endif
        return try await reader.events(calendarIDs: calendarIDs, interval: interval)
    }
    private func patchSharingSource(sourceID: UUID, name: String, level: CloudUploadLevel) async throws -> CloudSource {
        #if DEBUG
        if let patch = testSharingSourcePatcher { return try await patch(sourceID, name, level) }
        #endif
        struct Change: Encodable { let name: String; let uploadLevel: CloudUploadLevel }
        return try await api.request("PATCH", "sources/\(sourceID.uuidString)", body: api.encoded(Change(name: name, uploadLevel: level)))
    }
    private func sendSharingSnapshot(_ preview: CloudSharingPreview, binding: CloudLocalBinding, source: CloudSource) async throws -> CloudSource {
        let scope = homeDisplayScope, token = session?.accessToken
        let key: Data
        #if DEBUG
        if testSharingSnapshotSender != nil { key = Data(repeating: 7, count: 32) }
        else { key = try identityKey() }
        #else
        key = try identityKey()
        #endif
        let events = try CloudSharingPolicy.project(preview, key: key)
        let updated: CloudSource
        #if DEBUG
        if let sender = testSharingSnapshotSender { updated = try await sender(binding, source, events, preview.interval) }
        else { updated = try await sendSharingSnapshotToAPI(source: source, events: events, interval: preview.interval) }
        #else
        updated = try await sendSharingSnapshotToAPI(source: source, events: events, interval: preview.interval)
        #endif
        guard matchesSession(scope: scope, token: token), updated.id == source.id, updated.ownerId == source.ownerId,
              updated.deviceId == source.deviceId, updated.uploadLevel == preview.draft.uploadLevel else { throw CloudClientError.invalidResponse }
        return updated
    }
    private func sendSharingSnapshotToAPI(source: CloudSource, events: [CloudBusyEvent], interval: DateInterval) async throws -> CloudSource {
        let uploadClient = try api
        let snapshot = CloudSnapshot(snapshotId: UUID(), expectedGeneration: source.generation, windowStart: interval.start, windowEnd: interval.end, events: events)
        return try await uploadClient.request("PUT", "sources/\(source.id.uuidString)/snapshot", body: uploadClient.encoded(snapshot))
    }
    private func uploadSharingConfiguration(binding: CloudLocalBinding, source: CloudSource, metadataIsFresh: Bool) async throws {
        let scope = homeDisplayScope, token = session?.accessToken
        guard let configured = binding.pendingSharing ?? binding.sharing else { throw CloudClientError.missingSource }
        var latest = source
        if !metadataIsFresh { guard let refreshed = try await readUploadSource(source.id) else { throw CloudClientError.missingSource }; latest = refreshed }
        let level = configured.uploadLevel
        guard binding.isCreationPending != true, binding.uploadLevel == level, latest.uploadLevel == level,
              latest.name == configured.name else { throw CloudUploadScopeError.updatePending }
        let readTime = Date()
        let interval = try CloudUploadScopePolicy.interval(for: configured.range, now: readTime)
        let snapshots = try await readSharingEvents(calendarIDs: configured.calendarIDs, interval: interval)
        guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
        let preview = try CloudSharingPolicy.preview(draft: configured, snapshots: snapshots, now: readTime)
        let updated = try await sendSharingSnapshot(preview, binding: binding, source: latest)
        guard matchesSession(scope: scope, token: token) else { throw CancellationError() }
        completeSharingUpload(updated, binding: binding, draft: preview.draft)
    }
    private func completeSharingUpload(_ source: CloudSource, binding: CloudLocalBinding, draft: CloudSharingDraft) {
        guard let index = bindings.firstIndex(where: { $0.sourceId == binding.sourceId }) else { return }
        let identityChanged = binding.sharing?.ruleState != draft.ruleState && binding.pendingSharing == nil
        bindings[index].sharing = draft
        bindings[index].calendarIds = draft.calendarIDs
        bindings[index].range = draft.range
        bindings[index].pendingSharing = nil; bindings[index].pendingRange = nil; bindings[index].pendingLevel = nil
        bindings[index].isCreationPending = false
        if identityChanged { bindings[index].sharingRevision = (bindings[index].sharingRevision ?? 0) + 1 }
        sources.removeAll { $0.id == source.id }; sources.append(source)
        persistBindings()
    }
}
