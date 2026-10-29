#if DEBUG
import Foundation

/// Explicit UI-test transport: no Apple credentials, Keychain, EventKit writes, or live network.
/// This file is entirely absent from Release builds.
enum CloudSimulatorFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-cloud-signed-in-fixtures") || passwordMode }
    static var passwordMode: Bool { ProcessInfo.processInfo.arguments.contains("-cloud-password-fixtures") }
    static var startsSignedIn: Bool { !passwordMode || scenario == "password-restored" }
    static let endpoint = URL(string: "https://chronograph-ui.invalid/chronograph")!
    static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deviceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let ownSourceID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let firstPeerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let secondPeerID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static var scenario: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-cloud-fixture-scenario"), args.indices.contains(index + 1) else { return "standard" }
        return args[index + 1]
    }
    private static let lock = NSLock()
    private static var secure: [String: Data] = [:]
    static func read(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return secure[key] }
    static func save(_ data: Data, key: String) { lock.lock(); defer { lock.unlock() }; secure[key] = data }
    static func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; secure.removeValue(forKey: key) }
    static func defaults() -> UserDefaults {
        let name = "com.shiyao-zhang.ChronoGraph.cloud-ui." + UUID().uuidString
        let result = UserDefaults(suiteName: name)!
        result.removePersistentDomain(forName: name)
        return result
    }
    static func session() -> CloudSession {
        CloudSession(accessToken: "synthetic-ui-session-not-a-server-token", tokenType: "bearer", expiresAt: Date().addingTimeInterval(86_400),
                     user: CloudUser(id: userID, displayName: "测试用户"), deviceId: deviceID, authProvider: passwordMode ? "password" : "apple")
    }
    static var calendars: [CloudCalendarOption] {
        [CloudCalendarOption(id: "cloud.fixture.work", title: "Fixture Work", account: "Synthetic account"),
         CloudCalendarOption(id: "cloud.fixture.personal", title: "Fixture Personal", account: "Synthetic account")]
    }
    static func events(calendarID: String) -> [SourceEventSnapshot] {
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(36_000)
        if scenario == "sharing-multi-rules" {
            let work = calendarID == "cloud.fixture.work"
            let first = start.addingTimeInterval(work ? 0 : 3600)
            var values = [SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: "same-series-id-across-calendars",
                occurrenceDate: first, isRecurring: true, title: work ? "Work recurring one" : "Personal recurring one",
                startDate: first, endDate: first.addingTimeInterval(3600), location: "Fixture series room", notes: "Fixture series notes",
                timeZoneIdentifier: "Asia/Shanghai", readTimeZoneIdentifier: "Asia/Shanghai", availability: .busy)]
            if work {
                let second = Calendar.current.date(byAdding: .day, value: 1, to: first)!
                values.append(SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: "same-series-id-across-calendars",
                    occurrenceDate: second, isRecurring: true, title: "Work recurring two", startDate: second, endDate: second.addingTimeInterval(3600),
                    location: "Fixture series room", notes: "Fixture series notes", timeZoneIdentifier: "Asia/Shanghai",
                    readTimeZoneIdentifier: "Asia/Shanghai", availability: .busy))
            }
            let standalone = start.addingTimeInterval(work ? 4 * 3600 : 5 * 3600)
            values.append(SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: "same-single-id-across-calendars",
                title: work ? "Work excluded appointment" : "Personal appointment", startDate: standalone, endDate: standalone.addingTimeInterval(3600),
                location: "Fixture private room", notes: "Fixture private notes", timeZoneIdentifier: "Asia/Shanghai",
                readTimeZoneIdentifier: "Asia/Shanghai", availability: .busy))
            return values
        }
        return [SourceEventSnapshot(calendarID: calendarID, calendarItemIdentifier: "private-fixture-event", title: "Private fixture appointment",
            startDate: start, endDate: start.addingTimeInterval(3600), location: "Private fixture location", notes: "Private fixture notes",
            timeZoneIdentifier: "Asia/Shanghai", readTimeZoneIdentifier: "Asia/Shanghai", availability: .busy)]
    }
}

final class CloudSimulatorURLProtocol: URLProtocol {
    private var pendingCompletion: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { CloudSimulatorFixtures.enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Intercept all requests in this explicitly flagged process, reject any other origin.
        guard request.url?.host == "chronograph-ui.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let output = CloudSimulatorBackend.shared.handle(request)
        if CloudSimulatorFixtures.scenario == "logout-delayed", request.httpMethod == "DELETE", request.url?.path.hasSuffix("/auth/session") == true {
            let completion = DispatchWorkItem { [weak self] in self?.deliver(output) }
            pendingCompletion = completion
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 12, execute: completion)
        } else { deliver(output) }
    }
    private func deliver(_ output: (Int, Data)) {
        let response = HTTPURLResponse(url: request.url!, statusCode: output.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !output.1.isEmpty { client?.urlProtocol(self, didLoad: output.1) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { pendingCompletion?.cancel(); pendingCompletion = nil }
}

private final class CloudSimulatorBackend {
    static let shared = CloudSimulatorBackend()
    private let lock = NSLock()
    private var nickname = "测试用户"
    private var sources: [[String: Any]] = []
    private var sharedSources: [[String: Any]] = []
    private var meetings: [[String: Any]] = []
    private var grants: [[String: Any]] = []
    private var feeds: [[String: Any]] = []
    private var pairLinks: [[String: Any]] = []
    private let scenario = CloudSimulatorFixtures.scenario
    private var loggedOut = false
    private var fixtureUsername = "fixture.user"
    private var fixturePassword = "FixturePass123!"
    private var homeEventRequests = 0
    private var homeFullSourceWasRead = false
    private var receivedRemovalAttempts = 0
    private var snapshotRequestsBySource: [String: Int] = [:]
    private var activeDeviceID = CloudSimulatorFixtures.deviceID.uuidString.lowercased()
    private let sourceID = CloudSimulatorFixtures.ownSourceID.uuidString.lowercased()
    private let userID = CloudSimulatorFixtures.userID.uuidString.lowercased()
    private let peerID = CloudSimulatorFixtures.firstPeerID.uuidString.lowercased()
    private let secondID = CloudSimulatorFixtures.secondPeerID.uuidString.lowercased()
    private let deviceID = CloudSimulatorFixtures.deviceID.uuidString.lowercased()
    private init() {
        let coverageStart = Date().addingTimeInterval(-8 * 86_400), coverageEnd = Date().addingTimeInterval(100 * 86_400)
        sources = [["id": sourceID, "owner_id": userID, "device_id": deviceID, "name": "Fixture Cloud Work", "upload_level": "opaque", "generation": 1,
                    "coverage_start": iso(coverageStart), "coverage_end": iso(coverageEnd), "last_synced_at": iso(Date())]]
        sharedSources = [peerSource(id: "66666666-6666-4666-8666-666666666666", owner: peerID, name: "小林", calendar: "林晓工作"),
                         peerSource(id: "77777777-7777-4777-8777-777777777777", owner: peerID, name: "小林", calendar: "林晓生活"),
                         peerSource(id: "88888888-8888-4888-8888-888888888888", owner: secondID, name: "小陈", calendar: "陈晨日程")]
        if scenario.hasPrefix("cloud-home") {
            sharedSources[1]["privacy"] = "partial"
            sharedSources[2]["privacy"] = "full"
            if scenario == "cloud-home-owned" { sources[0]["upload_level"] = "partial" }
            if scenario == "cloud-home-coverage" {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
                for index in sharedSources.indices { sharedSources[index]["coverage_end"] = iso(tomorrow) }
            }
            if scenario == "cloud-home-stale" {
                for index in sharedSources.indices { sharedSources[index]["last_synced_at"] = iso(Date().addingTimeInterval(-48 * 3600)) }
            }
            // Last-owner and last-subscription transitions exercise UIKit's live row bookkeeping.
            if scenario == "cloud-home-remove-singleton" {
                sharedSources = [sharedSources[1]]
            } else if scenario == "cloud-home-remove-two-owners" {
                sharedSources = [sharedSources[1], sharedSources[2]]
            }
        }
        grants = [["user_id": peerID, "privacy": "opaque"]]
        if CloudSimulatorFixtures.passwordMode { sources = []; sharedSources = []; grants = [] }
        if scenario == "host-proposal" || scenario == "host-waiting" || scenario == "confirmed" || scenario == "conflict" {
            var meeting = newMeeting(id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", host: userID, title: "Fixture Hosted Meeting", status: scenario == "confirmed" ? "confirmed" : "proposed")
            if scenario == "host-waiting" { meeting["participants"] = [["user_id": userID, "response": "accepted"], ["user_id": peerID, "response": "pending"]] }
            meetings = [meeting]
        } else if scenario == "guest-proposal" {
            var meeting = newMeeting(id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", host: peerID, title: "Fixture Guest Meeting", status: "proposed")
            meeting["participants"] = [["user_id": peerID, "response": "accepted"], ["user_id": userID, "response": "pending"]]
            meetings = [meeting]
        }
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func peerSource(id: String, owner: String, name: String, calendar: String) -> [String: Any] {
        ["id": id, "owner_id": owner, "owner_name": name, "name": calendar, "privacy": "opaque", "generation": 1,
         "coverage_start": iso(Date().addingTimeInterval(-8 * 86_400)), "coverage_end": iso(Date().addingTimeInterval(100 * 86_400)), "last_synced_at": iso(Date())]
    }
    private func newMeeting(id: String, host: String, title: String, status: String) -> [String: Any] {
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(36_000)
        return ["id": id, "host_id": host, "title": title, "start": iso(start), "end": iso(start.addingTimeInterval(3600)), "timezone": "Asia/Shanghai", "revision": 1,
                "status": status, "updated_at": iso(Date()), "participants": [["user_id": userID, "response": "accepted"], ["user_id": peerID, "response": "accepted"]]]
    }
    private func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func passwordSession() -> (Int, Data) {
        json(["access_token": "synthetic-ui-session-not-a-server-token", "token_type": "bearer", "auth_provider": "password", "expires_at": iso(Date().addingTimeInterval(86_400)),
              "user": ["id": userID, "display_name": nickname], "device_id": activeDeviceID])
    }
    private func json(_ value: Any, status: Int = 200) -> (Int, Data) { (status, (try? JSONSerialization.data(withJSONObject: value)) ?? Data()) }
    private func failure(_ message: String, status: Int) -> (Int, Data) { json(["detail": ["code": "fixture_error", "message": message]], status: status) }
    private func dateQuery(_ name: String, request: URLRequest) -> Date? {
        guard let url = request.url, let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }
    private func homeEvents(sourceID: String, request: URLRequest) -> (Int, Data) {
        homeEventRequests += 1
        if scenario == "cloud-home-offline" { return failure("合成网络故障，请重试。", status: 503) }
        if scenario == "cloud-home-retry", homeEventRequests == 1 { return failure("合成网络故障，请重试。", status: 503) }
        if scenario == "cloud-home-revoked" { return failure("分享授权已撤销。", status: 404) }
        guard let lower = dateQuery("start", request: request), let upper = dateQuery("end", request: request), lower < upper else { return failure("合成日期查询格式错误。", status: 422) }
        let today = Calendar.current.startOfDay(for: Date())
        if scenario == "cloud-home-coverage", upper > Calendar.current.date(byAdding: .day, value: 1, to: today)! {
            return failure("分享来源未覆盖所选日期。", status: 409)
        }
        let owned = sourceID == self.sourceID
        let partial = sourceID == "77777777-7777-4777-8777-777777777777" || (owned && scenario == "cloud-home-owned")
        let full = sourceID == "88888888-8888-4888-8888-888888888888"
        if scenario == "cloud-home-downgrade", full { homeFullSourceWasRead = true }
        let events: [[String: Any]] = (0...1).compactMap { offset in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            let start = Calendar.current.date(byAdding: .hour, value: 10, to: date)!
            let end = start.addingTimeInterval(3600)
            guard start < upper, end > lower else { return nil }
            // Deliberately reuse IDs across sources and send excessive private fields.
            // The app must namespace identity and enforce each source's privacy ceiling.
            return ["id": offset == 0 ? "A0000000-0000-4000-8000-000000000001" : "A0000000-0000-4000-8000-000000000002",
                    "start": iso(start), "end": iso(end), "is_all_day": false, "timezone": TimeZone.current.identifier,
                    "availability": "busy", "title": full ? "Cloud full title" : partial ? (owned ? (offset == 0 ? "Owned cloud today title" : "Owned cloud tomorrow title") : (offset == 0 ? "Cloud visible today title" : "Cloud visible tomorrow title")) : "SECRET_OPAQUE_TITLE",
                    "location": full ? "Cloud visible location" : "SECRET_LOCATION", "notes": full ? "Cloud visible notes" : "SECRET_NOTES"]
        }
        return json(events)
    }
    /// This scenario accepts only the exact reviewed rules. UI assertions cannot
    /// succeed by merely showing the right labels while uploading broader content.
    private func validateMultipleCalendarRules(_ events: [[String: Any]], level: String) -> String? {
        guard level == "full", events.count == 4,
              Set(events.compactMap { $0["id"] as? String }).count == 4 else {
            return "Fixture expects four distinct events from two calendars and one excluded event"
        }
        let full = events.filter { $0["visibility"] as? String == "full" }
        let partial = events.filter { $0["visibility"] as? String == "partial" }
        let opaque = events.filter { $0["visibility"] as? String == "opaque" }
        guard full.count == 1, partial.count == 2, opaque.count == 1,
              full[0]["title"] as? String == "Work recurring one",
              full[0]["location"] as? String == "Fixture series room",
              full[0]["notes"] as? String == "Fixture series notes",
              Set(partial.compactMap { $0["title"] as? String }) == ["Personal recurring one", "Personal appointment"] else {
            return "Fixture event rules did not preserve occurrence, series and calendar boundaries"
        }
        func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
        guard opaque.allSatisfy({ absent($0["title"]) && absent($0["location"]) && absent($0["notes"]) }),
              partial.allSatisfy({ absent($0["location"]) && absent($0["notes"]) }),
              let workSeries = full[0]["series_id"] as? String,
              opaque[0]["series_id"] as? String == workSeries,
              let personalSeries = partial.first(where: { $0["title"] as? String == "Personal recurring one" })?["series_id"] as? String,
              personalSeries != workSeries else {
            return "Fixture detected private fields or a cross-calendar series collision"
        }
        return nil
    }
    func handle(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = (request.url?.path ?? "").replacingOccurrences(of: "/chronograph/v1/", with: "")
        let parts = path.split(separator: "/").map(String.init)
        let data = body(request)
        if path == "auth/options" { return json(["password_enabled": true, "registration_mode": "invite", "password_min_length": 12, "password_max_length": 128]) }
        if path == "auth/password/register", method == "POST" {
            guard data["password"] as? String == "RegistrationPass123!" else { return failure("合成测试密码未完整输入。", status: 422) }
            guard data["invite_code"] as? String == "fixture-invite-valid-code-2026" else { return failure("邀请码无效或已使用。", status: 403) }
            fixtureUsername = data["username"] as? String ?? "fixture.user"
            fixturePassword = data["password"] as? String ?? "FixturePass123!"
            nickname = data["display_name"] as? String ?? fixtureUsername
            activeDeviceID = data["device_id"] as? String ?? deviceID
            loggedOut = false
            return passwordSession()
        }
        if path == "auth/password/login", method == "POST" {
            guard data["username"] as? String == fixtureUsername, data["password"] as? String == fixturePassword else { return failure("用户名或密码不正确。", status: 401) }
            activeDeviceID = data["device_id"] as? String ?? deviceID
            loggedOut = false
            return passwordSession()
        }
        if path == "auth/apple/challenge" {
            return json(["challenge_id": UUID().uuidString, "nonce": "synthetic-fixture-nonce", "expires_at": iso(Date().addingTimeInterval(300))])
        }
        if path == "auth/session", method == "DELETE" {
            if scenario == "logout-offline" { return failure("Fixture server unavailable", status: 503) }
            loggedOut = true; return (204, Data())
        }
        if scenario == "expired" || loggedOut { return failure("Fixture session expired", status: 401) }
        if scenario == "offline" { return failure("Fixture server unavailable", status: 503) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-ui-session-not-a-server-token" else { return failure("Fixture authentication missing", status: 401) }
        if path == "auth/password/change", method == "POST" {
            guard data["current_password"] as? String == fixturePassword else { return failure("当前密码不正确。", status: 403) }
            fixturePassword = data["new_password"] as? String ?? fixturePassword
            return passwordSession()
        }
        if path == "me" {
            if method == "DELETE" { loggedOut = true; return (204, Data()) }
            if method == "PATCH" { nickname = data["display_name"] as? String ?? nickname }
            return json(["id": userID, "display_name": nickname])
        }
        if path == "sources" {
            if method == "GET", scenario == "cloud-home-catalog-offline" {
                return failure("合成日历目录暂时不可用，请重试。", status: 503)
            }
            if method == "POST" {
                let item: [String: Any] = ["id": (data["id"] as? String ?? UUID().uuidString).lowercased(), "owner_id": userID, "device_id": deviceID,
                    "name": data["name"] as? String ?? "Fixture Calendar", "upload_level": data["upload_level"] as? String ?? "opaque", "generation": 0]
                sources.append(item); return json(item, status: 201)
            }
            return json(sources)
        }
        if path == "shared-sources" {
            // Metadata can be read several times during startup. Arm the downgrade
            // only after the full source's events have actually been fetched.
            if scenario == "cloud-home-downgrade", homeFullSourceWasRead,
               let index = sharedSources.firstIndex(where: { ($0["id"] as? String) == "88888888-8888-4888-8888-888888888888" }) {
                sharedSources[index]["privacy"] = "opaque"
            }
            return json(sharedSources)
        }
        if parts.count == 2, parts[0] == "shared-sources", method == "DELETE" {
            receivedRemovalAttempts += 1
            if scenario == "cloud-home-remove-failure", receivedRemovalAttempts == 1 {
                return failure("合成取消订阅失败，请重试。", status: 503)
            }
            sharedSources.removeAll { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }
            return (204, Data())
        }
        if scenario.hasPrefix("cloud-home"), parts.count == 3, parts[0] == "sources", parts[2] == "events", method == "GET",
           (sharedSources.contains(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }) ||
            sources.contains(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() })) {
            return homeEvents(sourceID: parts[1].lowercased(), request: request)
        }
        if path == "device-tasks" { return json([]) }
        if path == "share-links/redeem" {
            guard data["token"] as? String == "fixture-new-person" else { return failure("添加链接已失效或无权访问。", status: 404) }
            let item = peerSource(id: "99999999-9999-4999-8999-999999999999", owner: "99999999-1111-4111-8111-111111111111", name: "新朋友", calendar: "新朋友日程")
            sharedSources.append(item); return json(item)
        }
        if parts.first == "sources", parts.count >= 2, let index = sources.firstIndex(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }) {
            if parts.count == 2, method == "DELETE" { sources.remove(at: index); return (204, Data()) }
            if parts.count == 2, method == "GET" { return json(sources[index]) }
            if parts.count == 2, method == "PATCH" {
                if let name = data["name"] as? String { sources[index]["name"] = name }
                guard let level = data["upload_level"] as? String else { return json(sources[index]) }
                guard ["opaque", "partial", "full"].contains(level) else { return failure("Invalid upload level", status: 422) }
                let rank = ["opaque": 0, "partial": 1, "full": 2]
                let previous = sources[index]["upload_level"] as? String ?? "opaque"
                if rank[level]! < rank[previous]! {
                    for i in grants.indices where (rank[grants[i]["privacy"] as? String ?? "opaque"] ?? 0) > rank[level]! { grants[i]["privacy"] = level }
                    for i in pairLinks.indices where (rank[pairLinks[i]["privacy"] as? String ?? "opaque"] ?? 0) > rank[level]! { pairLinks[i]["privacy"] = level }
                    for i in feeds.indices where (rank[feeds[i]["privacy"] as? String ?? "opaque"] ?? 0) > rank[level]! { feeds[i]["privacy"] = level }
                }
                sources[index]["upload_level"] = level
                sources[index]["generation"] = (sources[index]["generation"] as? Int ?? 0) + 1
                return json(sources[index])
            }
            if parts.last == "snapshot" {
                if scenario == "sharing-hub-create-once" || scenario == "sharing-multi-rules" {
                    snapshotRequestsBySource[parts[1].lowercased(), default: 0] += 1
                }
                let level = sources[index]["upload_level"] as? String ?? "opaque"
                let events = data["events"] as? [[String: Any]] ?? []
                if level == "opaque", events.contains(where: { $0["title"] != nil || $0["location"] != nil || $0["notes"] != nil }) { return failure("Opaque snapshot leaked private fields", status: 422) }
                if level == "partial", events.contains(where: { $0["location"] != nil || $0["notes"] != nil }) { return failure("Partial snapshot leaked private fields", status: 422) }
                if scenario == "sharing-multi-rules", parts[1].lowercased() != sourceID {
                    if let error = validateMultipleCalendarRules(events, level: level) { return failure(error, status: 422) }
                }
                guard data["expected_generation"] as? Int == sources[index]["generation"] as? Int else { return failure("Snapshot generation changed", status: 409) }
                sources[index]["generation"] = (sources[index]["generation"] as? Int ?? 0) + 1
                sources[index]["coverage_start"] = data["window_start"]; sources[index]["coverage_end"] = data["window_end"]; sources[index]["last_synced_at"] = iso(Date())
                return json(sources[index])
            }
            if parts.last == "grants" { return json(grants) }
            if parts.count == 4, parts[2] == "grants", method == "DELETE" { grants.removeAll { ($0["user_id"] as? String)?.lowercased() == parts[3].lowercased() }; return (204, Data()) }
            if parts.last == "feed-links" || parts.last == "share-links" {
                let feed = parts.last == "feed-links"
                if method == "GET" { return json(feed ? feeds : pairLinks) }
                if (scenario == "sharing-hub-create-once" || scenario == "sharing-multi-rules"), parts[1].lowercased() != sourceID,
                   snapshotRequestsBySource[parts[1].lowercased()] != 1 {
                    return failure("Fixture expects exactly one confirmed upload before sharing a new source", status: 409)
                }
                let id = UUID().uuidString.lowercased(), expires = iso(Date().addingTimeInterval(86_400))
                let record: [String: Any] = ["id": id, "privacy": data["privacy"] as? String ?? "opaque", "expires_at": expires, "revoked": false]
                if feed { feeds.append(record); return json(["id": id, "url": "https://chronograph-ui.invalid/chronograph/v1/feeds/fixture-feed.ics", "expires_at": expires], status: 201) }
                pairLinks.append(record); return json(["id": id, "token": "fixture-share", "join_url": "https://chronograph-ui.invalid/chronograph/join/fixture-share", "expires_at": expires], status: 201)
            }
        }
        if (parts.first == "feed-links" || parts.first == "share-links"), parts.count == 2, method == "DELETE" {
            if parts.first == "feed-links", let i = feeds.firstIndex(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }) { feeds[i]["revoked"] = true }
            if parts.first == "share-links", let i = pairLinks.firstIndex(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }) { pairLinks[i]["revoked"] = true }
            return (204, Data())
        }
        if path == "availability/search" {
            if scenario == "stale" { return failure("来源已超过24小时未更新，请先同步日历。", status: 409) }
            if scenario == "no-slots" { return json(["timezone": "Asia/Shanghai", "checked_at": iso(Date()), "windows": []]) }
            let start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(36_000)
            return json(["timezone": "Asia/Shanghai", "checked_at": iso(Date()), "windows": [["start": iso(start), "end": iso(start.addingTimeInterval(7200)), "suggested_start": iso(start), "suggested_end": iso(start.addingTimeInterval(3600))]]])
        }
        if path == "meetings" {
            if method == "POST" {
                var meeting = newMeeting(id: UUID().uuidString, host: userID, title: data["title"] as? String ?? "约时间", status: "proposed")
                if let people = data["participants"] as? [[String: Any]] {
                    meeting["participants"] = people.map { person -> [String: Any] in
                        let id = (person["user_id"] as? String ?? "").lowercased()
                        return ["user_id": id, "response": id == userID ? "accepted" : "pending"]
                    }
                }
                meetings.append(meeting); return json(meeting, status: 201)
            }
            return json(meetings)
        }
        if parts.first == "meetings", parts.count >= 2, let index = meetings.firstIndex(where: { ($0["id"] as? String)?.lowercased() == parts[1].lowercased() }) {
            if parts.count == 3 {
                if scenario == "conflict", parts.last == "confirm" { return failure("日程已出现新的冲突，请重新选择时间。", status: 409) }
                if parts.last == "confirm" { meetings[index]["status"] = "confirmed" }
                if parts.last == "cancel" { meetings[index]["status"] = "cancelled" }
                if parts.last == "response" {
                    var people = meetings[index]["participants"] as? [[String: Any]] ?? []
                    if let p = people.firstIndex(where: { ($0["user_id"] as? String)?.lowercased() == userID }) { people[p]["response"] = data["response"] }
                    meetings[index]["participants"] = people
                }
                meetings[index]["updated_at"] = iso(Date())
            }
            return json(meetings[index])
        }
        return failure("Fixture route not implemented: \(method) \(path)", status: 404)
    }
}
#endif
