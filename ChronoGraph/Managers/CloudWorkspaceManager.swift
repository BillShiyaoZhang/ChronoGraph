import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit

@MainActor
final class CloudWorkspaceManager: ObservableObject {
    @Published private(set) var endpoint = ""
    @Published private(set) var session: CloudSession?
    @Published private(set) var challenge: CloudChallenge?
    @Published private(set) var sources: [CloudSource] = []
    @Published private(set) var sharedSources: [CloudSharedSource] = []
    @Published private(set) var selectedSharedSourceIDs: Set<UUID> = []
    @Published private(set) var meetings: [CloudMeeting] = []
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

    var appleSignInAvailable: Bool {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { return !CloudSimulatorFixtures.passwordMode }
        #endif
        return CloudBuildConfiguration.appleSignInEnabled
    }
    var currentUserID: UUID? { session?.user.id }
    var homeDisplayScope: String? { currentUserID.map { endpoint + "." + $0.uuidString } }
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
            else { self.notice = "服务器地址已保存。" }
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
            errorMessage = CloudClientError.cloudLoginUnavailable.localizedDescription
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
            errorMessage = CloudClientError.cloudLoginUnavailable.localizedDescription
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
            self.notice = "已登录。请添加你明确允许上传的日历。"
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
            self.notice = "密码已更新，其他设备需要重新登录。"
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
        notice = "已退出本机，正在撤销服务器会话…"
        var remoteFailure: Error?
        do { _ = try await revocation?.send("DELETE", "auth/session") }
        catch {
            if case CloudClientError.http(let status, _) = error, status == 401 { /* Already invalid. */ }
            else { remoteFailure = error }
        }
        notice = remoteFailure == nil ? "已退出此设备。" : "已退出本机；未能确认服务器会话撤销，请稍后重新登录并检查其他会话。"
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
            self.notice = "昵称已保存，获得授权的人将看到此昵称。"
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
            self.notice = "云端账号已删除。系统日历和已保存的日程仍保留。"
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
    func refresh() async { await perform { try await self.reload() } }
    private func reload() async throws {
        guard session != nil else { return }
        try await validateAppleSession()
        let user: CloudUser = try await api.request("GET", "me")
        try persistCurrentUser(user)
        sources = try await api.request("GET", "sources")
        sharedSources = try await api.request("GET", "shared-sources")
        pruneDisplaySelection()
        meetings = try await api.request("GET", "meetings")
        await reconcileCalendarTasks()
    }
    func loadCalendars() async {
        await perform { self.calendars = try await self.reader.inventory() }
    }
    func enableCalendar(_ calendar: CloudCalendarOption, level: CloudUploadLevel) async {
        await perform {
            guard !self.bindings.contains(where: { $0.calendarId == calendar.id }) else { return }
            struct Create: Encodable { let id: UUID; let name: String; let uploadLevel: CloudUploadLevel; let deviceId: UUID }
            let id = UUID()
            let source: CloudSource = try await self.api.request("POST", "sources", body: self.api.encoded(Create(id: id, name: calendar.title, uploadLevel: level, deviceId: try self.stableDeviceID())))
            self.bindings.append(CloudLocalBinding(sourceId: source.id, calendarId: calendar.id, uploadLevel: level))
            self.persistBindings()
            self.sources.append(source)
            try await self.upload(sourceID: source.id)
        }
    }
    func sync() async {
        await perform {
            guard !self.bindings.isEmpty else { throw CloudClientError.noSources }
            try await self.reload()
            for binding in self.bindings { try Task.checkCancellation(); try await self.upload(sourceID: binding.sourceId) }
            self.lastAutomaticSync = Date()
            self.availability = nil
            self.notice = "已上传所选日历的允许字段。未向他人自动开放访问。"
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
    private func upload(sourceID: UUID) async throws {
        guard let binding = bindings.first(where: { $0.sourceId == sourceID }),
              let source = sources.first(where: { $0.id == sourceID }) else { throw CloudClientError.missingSource }
        guard binding.uploadLevel == source.uploadLevel else { throw CloudClientError.http(409, "云端上传范围已改变，请删除本机绑定并重新审阅授权。") }
        let interval = CloudSnapshotProjection.window()
        let original = try await reader.events(calendarID: binding.calendarId, interval: interval)
        let key = try identityKey()
        let projected = try original.map { try CloudSnapshotProjection.project($0, sourceID: sourceID, level: binding.uploadLevel, key: key) }
        let snapshot = CloudSnapshot(snapshotId: UUID(), expectedGeneration: source.generation,
                                     windowStart: interval.start, windowEnd: interval.end, events: projected)
        let updated: CloudSource = try await api.request("PUT", "sources/\(sourceID.uuidString)/snapshot", body: api.encoded(snapshot))
        sources.removeAll { $0.id == updated.id }; sources.append(updated)
    }
    func createShareLink(_ source: CloudSource) async -> CloudShareLink? {
        var result: CloudShareLink?
        await perform {
            struct Create: Encodable { let privacy: CloudUploadLevel }
            result = try await self.api.request("POST", "sources/\(source.id.uuidString)/share-links", body: self.api.encoded(Create(privacy: source.uploadLevel)))
        }
        return result
    }
    func createFeedLink(_ source: CloudSource) async -> CloudFeedLink? {
        var result: CloudFeedLink?
        await perform {
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
            let _: CloudSharedSource = try await self.api.request("POST", "share-links/redeem", body: self.api.encoded(Redeem(token: token)))
            try await self.reload(); self.availability = nil
        }
    }
    func search(selectedPeople: Set<UUID>, days: Int, duration: Int, dailyStart: String, dailyEnd: String) async {
        await perform {
            guard let userID = self.currentUserID else { throw CloudClientError.signIn }
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
            let result: CloudAvailability = try await self.api.request("POST", "availability/search", body: self.api.encoded(request))
            self.lastParticipants = participants; self.availability = result
        }
    }
    func propose(_ candidate: CloudCandidate, title: String) async {
        await perform {
            guard !self.lastParticipants.isEmpty else { throw CloudClientError.coverage }
            var request = CloudCreateMeeting(requestId: UUID(), title: title, start: candidate.suggestedStart, end: candidate.suggestedEnd,
                timezone: self.availability?.timezone ?? TimeZone.current.identifier, participants: self.lastParticipants)
            let pendingKey = self.namespace + ".pendingMeeting." + (self.currentUserID?.uuidString ?? "none")
            if let data = CloudSecureStore.read(pendingKey), let pending = try? CloudJSON.decoder().decode(CloudCreateMeeting.self, from: data), pending.samePayload(as: request) {
                request.requestId = pending.requestId
            }
            let body = try self.api.encoded(request)
            try CloudSecureStore.save(body, key: pendingKey)
            let _: CloudMeeting = try await self.api.request("POST", "meetings", body: body)
            CloudSecureStore.remove(pendingKey)
            try await self.reload(); self.notice = "邀约已保存，等待参与者回应。"
        }
    }
    func meetingAction(_ meeting: CloudMeeting, action: String, response: String? = nil) async {
        await perform {
            struct Action: Encodable { let revision: Int; let response: String? }
            let _: CloudMeeting = try await self.api.request("POST", "meetings/\(meeting.id.uuidString)/\(action)", body: self.api.encoded(Action(revision: meeting.revision, response: response)))
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
            throw CloudClientError.http(409, "约定已经改期或取消，请刷新后重试。")
        }
        try await calendarWriter.save(current, calendarID: calendarID, namespace: calendarNamespace)
        // The external calendar write cannot be atomic with a backend transaction. Recheck and converge.
        let after: CloudMeeting = try await api.request("GET", "meetings/\(displayed.id.uuidString)")
        if after.status != "confirmed" || after.revision != current.revision {
            _ = try await calendarWriter.reconcile(after, namespace: calendarNamespace)
            throw CloudClientError.http(409, "保存期间约定发生变化，已核对本机日程。请刷新邀约。")
        }
        try await acknowledgeCalendarWrite(current)
    }
    func removeCalendarProjection(_ meeting: CloudMeeting) async throws {
        let current: CloudMeeting = try await api.request("GET", "meetings/\(meeting.id.uuidString)")
        guard current.status != "confirmed" else { throw CloudClientError.http(409, "约定当前仍已定档，未移除日程。") }
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
            calendarSyncStatus = failures > 0 ? "\(failures)份本机日程需要检查（权限、网络或手动更改）；未强制覆盖。" : waiting > 0 ? "\(waiting)个约定等待你选择日历保存。" : "已核对本机日历写回状态。"
        } catch { calendarSyncStatus = "暂未能核对日历写回任务；原日程保持不变。" }
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
            throw CloudClientError.http(401, "Apple 登录授权已改变，请重新登录。")
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
    func toggleSharedSourceDisplay(_ id: UUID) {
        guard session != nil, sharedSources.contains(where: { $0.id == id }) else { return }
        if selectedSharedSourceIDs.contains(id) { selectedSharedSourceIDs.remove(id) }
        else { selectedSharedSourceIDs.insert(id) }
        persistDisplaySelection()
    }
    func selectAllSharedSourcesForDisplay() {
        selectedSharedSourceIDs = Set(sharedSources.map(\.id)); persistDisplaySelection()
    }
    func clearSharedSourceDisplay() { selectedSharedSourceIDs = []; persistDisplaySelection() }
    private func persistDisplaySelection() {
        guard session != nil else { return }
        defaults.set(selectedSharedSourceIDs.map(\.uuidString).sorted(), forKey: displaySelectionKey)
    }
    private func pruneDisplaySelection() {
        selectedSharedSourceIDs.formIntersection(Set(sharedSources.map(\.id)))
        persistDisplaySelection()
    }
    /// A separate reader keeps home browsing independent of upload/coordination commands.
    func refreshSharedSourcesForDisplay() async throws {
        guard let scope = homeDisplayScope else { return }
        let request = UUID()
        homeSourcesRequestID = request
        let reader = try api
        let values: [CloudSharedSource] = try await reader.request("GET", "shared-sources")
        guard homeSourcesRequestID == request, homeDisplayScope == scope, !Task.isCancelled else { throw CancellationError() }
        sharedSources = values
        pruneDisplaySelection()
    }
    func fetchSharedEvents(source: CloudSharedSource, interval: DateInterval) async throws -> [CloudBusyEvent] {
        guard let scope = homeDisplayScope, sharedSources.contains(where: { $0.id == source.id }) else { throw CloudClientError.signIn }
        let reader = try api
        func timestamp(_ value: Date) throws -> String {
            try JSONDecoder().decode(String.self, from: CloudJSON.encoder().encode(value))
        }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "start", value: try timestamp(interval.start)),
                            URLQueryItem(name: "end", value: try timestamp(interval.end))]
        let values: [CloudBusyEvent] = try await reader.request("GET", "sources/\(source.id.uuidString)/events?" + (query.percentEncodedQuery ?? ""))
        guard homeDisplayScope == scope else { throw CancellationError() }
        return values
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
            errorMessage = error.localizedDescription
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
