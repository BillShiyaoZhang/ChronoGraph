import Foundation
import Security

// No HTTP exception, credential URL, or automatic redirect to another origin is permitted.
enum CloudClientError: LocalizedError {
    case invalidDisplayName, invalidEndpoint, invalidResponse, http(Int, String), keychain(OSStatus), signIn, permission, missingSource, coverage, noSources
    case invalidEventTime, uploadFieldLimit(String, Int), cloudLoginUnavailable, invalidUsername, invalidPassword, passwordMismatch, missingInvite
    var errorDescription: String? {
        switch self {
        case .invalidDisplayName: return "请输入1至100个字符的昵称。"
        case .invalidEndpoint: return "请输入不含账号、查询参数或片段的 HTTPS 服务器地址。"
        case .invalidResponse: return "服务器返回了无法识别的数据。"
        case .http(let code, let message): return "服务器请求失败（\(code)）：\(message)"
        case .keychain: return "无法安全保存登录信息。"
        case .signIn: return "登录未完成或已失效，请重新登录。"
        case .cloudLoginUnavailable: return "此版本未启用 Apple 登录，请使用账号密码登录。"
        case .invalidUsername: return "用户名需为3至32位英文字母、数字、点、下划线或短横线。"
        case .invalidPassword: return "密码需为12至128个字符。空格也属于密码，请原样输入。"
        case .passwordMismatch: return "两次输入的密码不一致。"
        case .missingInvite: return "请输入管理员提供的邀请码。"
        case .permission: return "请先在系统设置中允许完整日历访问。"
        case .missingSource: return "所选日历已不可用，请重新确认云同步来源。"
        case .coverage: return "没有足够的日历覆盖范围，请先同步来源。"
        case .noSources: return "请明确选择用于云端忙闲的日历。"
        case .invalidEventTime: return "某条日程的起止时间无效，尚未上传此来源。请在原日历中调整后再同步。"
        case .uploadFieldLimit(let field, let maximum): return "某条日程的\(field)超过服务器允许的\(maximum)个字符，尚未上传此来源。请先调整原日程，或选择较少详情的上传级别。"
        }
    }
}

/// Validation responses can contain rejected input, private event text and
/// exception context. Only known path components/types become user-facing text.
enum CloudValidationFeedback {
    static let fallback = "请求内容未通过服务器校验，请更新App后重试。"

    private struct Response: Decodable { let detail: Detail }
    private struct Detail: Decodable { let code: String?; let issues: [Issue]? }
    private struct Issue: Decodable { let loc: [Part]; let type: String }
    private enum Part: Decodable, Equatable {
        case key(String), index(Int), unknown
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .key(value) }
            else if let value = try? container.decode(Int.self) { self = .index(value) }
            else { self = .unknown }
        }
    }
    private struct Field {
        let label: String
        let maximum: Int?
    }
    private static let eventFields: [String: Field] = [
        "id": Field(label: "标识", maximum: nil), "series_id": Field(label: "重复系列标识", maximum: nil),
        "start": Field(label: "开始时间", maximum: nil), "end": Field(label: "结束时间", maximum: nil),
        "is_all_day": Field(label: "全天标记", maximum: nil), "timezone": Field(label: "时区", maximum: nil),
        "availability": Field(label: "忙闲状态", maximum: nil), "title": Field(label: "标题", maximum: 500),
        "location": Field(label: "地点", maximum: 1000), "notes": Field(label: "备注", maximum: 10_000)
    ]
    private static let requestFields: [String: Field] = [
        "name": Field(label: "日历名称", maximum: 120), "events": Field(label: "日程列表", maximum: nil),
        "snapshot_id": Field(label: "同步请求标识", maximum: nil), "expected_generation": Field(label: "同步版本", maximum: nil),
        "window_start": Field(label: "同步开始时间", maximum: nil), "window_end": Field(label: "同步结束时间", maximum: nil),
        "device_id": Field(label: "设备标识", maximum: nil), "device_name": Field(label: "设备名称", maximum: 100),
        "username": Field(label: "用户名", maximum: 32), "password": Field(label: "密码", maximum: 128),
        "current_password": Field(label: "当前密码", maximum: 128), "new_password": Field(label: "新密码", maximum: 128),
        "invite_code": Field(label: "邀请码", maximum: 200), "display_name": Field(label: "昵称", maximum: 100),
        "timezone": Field(label: "时区", maximum: nil), "upload_level": Field(label: "上传范围", maximum: nil)
    ]

    static func message(from data: Data) -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return fallback }
        switch response.detail.code {
        case "upload_scope_violation": return "上传字段超出了当前授权范围，请重新检查此日历的上传设置。"
        case "source_limit": return "此账号的云端日历来源已达到上限，请检查已有来源。"
        case "invalid_request": break
        default: return fallback
        }
        var messages: [String] = []
        for issue in (response.detail.issues ?? []).prefix(20) {
            if let message = describe(issue), !messages.contains(message) { messages.append(message) }
            if messages.count == 3 { break }
        }
        return messages.isEmpty ? fallback : messages.joined(separator: "；")
    }

    private static func describe(_ issue: Issue) -> String? {
        guard issue.loc.first == .key("body") || issue.loc.first == .key("query") else { return nil }
        if issue.loc == [.key("body")], issue.type == "value_error" {
            return "请求的日期范围、重复标识或时间格式未通过校验，请检查后重试。"
        }
        let field: Field
        let prefix: String
        if issue.loc.count == 3, issue.loc[1] == .key("events"), case .index(let index) = issue.loc[2],
           (0..<20_000).contains(index), issue.type == "value_error" {
            return "第\(index + 1)条日程的结束时间必须晚于开始时间。"
        } else if issue.loc.count == 4, issue.loc[1] == .key("events"), case .index(let index) = issue.loc[2],
                  (0..<20_000).contains(index), case .key(let key) = issue.loc[3], let known = eventFields[key] {
            field = known; prefix = "第\(index + 1)条日程的"
        } else if issue.loc.count == 2, case .key(let key) = issue.loc[1], let known = requestFields[key] {
            field = known; prefix = ""
        } else { return nil }
        let label = prefix + field.label
        switch issue.type {
        case "missing": return "缺少\(label)，请更新App后重试。"
        case "string_too_long":
            return field.maximum.map { "\(label)超过\($0)个字符。" } ?? "\(label)内容过长。"
        case "string_too_short": return "\(label)内容过短。"
        case "too_long": return "\(label)超出服务器上限，已停止本次上传，请联系管理员。"
        case "datetime_parsing", "datetime_from_date_parsing", "datetime_type", "timezone_aware":
            return "\(label)格式无效或缺少时区信息。"
        case "uuid_parsing", "uuid_type": return "\(label)格式无效，请重新同步。"
        case "literal_error", "enum", "value_error", "greater_than_equal", "less_than_equal", "int_parsing", "bool_parsing":
            return "\(label)不符合服务器要求，请更新App后重试。"
        default: return nil
        }
    }
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The deployment URL must point directly to the API; never forward bearer tokens on redirects.
        completionHandler(nil)
    }
}

final class CloudAPIClient {
    let baseURL: URL
    var accessToken: String?
    private let session: URLSession
    init(baseURL: URL, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        #if DEBUG
        if CloudSimulatorFixtures.enabled { configuration.protocolClasses = [CloudSimulatorURLProtocol.self] }
        #endif
        session = URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, authenticated: Bool = true) async throws -> T {
        let data = try await send(method, path, body: body, authenticated: authenticated)
        return try CloudJSON.decoder().decode(T.self, from: data)
    }
    func send(_ method: String, _ path: String, body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let resource = baseURL.appendingPathComponent("v1").appendingPathComponent(String(pieces[0]))
        var parts = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
        if pieces.count == 2 { parts.percentEncodedQuery = String(pieces[1]) }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if authenticated {
            guard let accessToken else { throw CloudClientError.signIn }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 422 { throw CloudClientError.http(422, CloudValidationFeedback.message(from: data)) }
            struct Failure: Decodable { let detail: String? }
            // Structured validation payloads and HTML are not echoed into the UI or logs.
            let structured = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (structured?["detail"] as? [String: Any])?["message"] as? String
            let detail = message ?? (try? CloudJSON.decoder().decode(Failure.self, from: data).detail) ?? "请检查登录、权限和服务器状态后重试。"
            throw CloudClientError.http(response.statusCode, String(detail.prefix(240)))
        }
        return data
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data { try CloudJSON.encoder().encode(value) }
}

struct CloudSecureStore {
    private static let service = "com.shiyao-zhang.ChronoGraph.cloud"
    static func read(_ key: String) -> Data? {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { return CloudSimulatorFixtures.read(key) }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess else { return nil }
        return output as? Data
    }
    static func save(_ data: Data, key: String) throws {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { CloudSimulatorFixtures.save(data, key: key); return }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(addition as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw CloudClientError.keychain(inserted) }
        } else if status != errSecSuccess { throw CloudClientError.keychain(status) }
    }
    static func remove(_ key: String) {
        #if DEBUG
        if CloudSimulatorFixtures.enabled { CloudSimulatorFixtures.remove(key); return }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
