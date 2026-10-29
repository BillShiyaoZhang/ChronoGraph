import Foundation
import CryptoKit

/// Wire models deliberately contain only fields accepted by the cloud upload contract.
enum CloudUploadLevel: String, Codable, CaseIterable, Identifiable {
    case opaque, partial, full
    var id: String { rawValue }
    var label: String {
        switch self { case .opaque: return CloudCopy.text("仅忙闲"); case .partial: return CloudCopy.text("标题与时间"); case .full: return CloudCopy.text("标题、地点与备注") }
    }
}

struct CloudUser: Codable, Identifiable { let id: UUID; let displayName: String }
struct CloudChallenge: Decodable { let challengeId: UUID; let nonce: String; let expiresAt: Date }
struct CloudSession: Codable {
    let accessToken: String
    let tokenType: String
    let expiresAt: Date
    let user: CloudUser
    let deviceId: UUID
    let authProvider: String?
    var usesPassword: Bool { authProvider == "password" }
    func canRestore(appleSignInAvailable: Bool) -> Bool { usesPassword || ((authProvider == nil || authProvider == "apple") && appleSignInAvailable) }
    init(accessToken: String, tokenType: String, expiresAt: Date, user: CloudUser, deviceId: UUID, authProvider: String? = nil) {
        self.accessToken = accessToken; self.tokenType = tokenType; self.expiresAt = expiresAt
        self.user = user; self.deviceId = deviceId; self.authProvider = authProvider
    }
}

/// Passwords are sent exactly as entered; only the public username is canonicalized.
enum CloudPasswordPolicy {
    static func matches(_ value: String, _ confirmation: String) -> Bool {
        value.utf8.elementsEqual(confirmation.utf8)
    }
    static func username(_ value: String) throws -> String {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...32).contains(canonical.utf8.count), canonical.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [46, 95, 45].contains($0) }) else { throw CloudClientError.invalidUsername }
        return canonical
    }
    static func validate(_ value: String) throws {
        guard (12...128).contains(value.unicodeScalars.count), value.utf8.count <= 512 else { throw CloudClientError.invalidPassword }
    }
}
struct CloudSource: Codable, Identifiable {
    let id: UUID
    let ownerId: UUID
    let deviceId: UUID
    let name: String
    let uploadLevel: CloudUploadLevel
    let generation: Int
    let coverageStart: Date?
    let coverageEnd: Date?
    let lastSyncedAt: Date?
}
struct CloudBusyEvent: Codable, Identifiable {
    let id: UUID
    let seriesId: UUID?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let timezone: String
    let availability: String
    let title: String?
    let location: String?
    let notes: String?
    var visibility: CloudUploadLevel? = nil
}
struct CloudSnapshot: Encodable {
    let snapshotId: UUID
    let expectedGeneration: Int
    let windowStart: Date
    let windowEnd: Date
    let events: [CloudBusyEvent]
}
struct CloudLocalBinding: Codable {
    let sourceId: UUID
    let calendarId: String
    var uploadLevel: CloudUploadLevel
    /// Device-local scheduling preference; nil keeps existing installations uploading.
    var isPaused: Bool? = nil
    /// Last successfully applied range. Legacy bindings retain the original 7/90 rolling window.
    var range: SharedCalendarRange? = nil
    /// Persist a confirmed change before sending it; retries must never restore an older, wider window.
    var pendingRange: SharedCalendarRange? = nil
    /// Complete confirmed intent is saved before either source creation or a level PATCH.
    var pendingLevel: CloudUploadLevel? = nil
    var isCreationPending: Bool? = nil
    var calendarIds: Set<String>? = nil
    var sharing: CloudSharingDraft? = nil
    var pendingSharing: CloudSharingDraft? = nil
    var sharingRevision: Int? = nil
    var effectiveCalendarIDs: Set<String> { pendingSharing?.calendarIDs ?? sharing?.calendarIDs ?? calendarIds ?? [calendarId] }
    var hasPendingScope: Bool { pendingRange != nil || pendingLevel != nil || isCreationPending == true || pendingSharing != nil }
    var confirmedRange: SharedCalendarRange { sharing?.range ?? range ?? .rolling() }
    var uploadRange: SharedCalendarRange { pendingSharing?.range ?? pendingRange ?? confirmedRange }
}

enum CloudEndpointPolicy {
    static func validated(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw CloudClientError.invalidEndpoint }
        parts.scheme = "https"
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let result = parts.url else { throw CloudClientError.invalidEndpoint }
        return result
    }
}

enum CloudJSON {
    /// Python datetime stores microseconds. Keep the same precision at both wire
    /// boundaries so short, valid EventKit intervals do not become zero-length.
    static func normalizedDate(_ value: Date) -> Date {
        let micros = (value.timeIntervalSince1970 * 1_000_000).rounded()
        guard micros.isFinite else { return value }
        return Date(timeIntervalSince1970: micros / 1_000_000)
    }
    static func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.keyEncodingStrategy = .convertToSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        result.dateEncodingStrategy = .custom { value, encoder in
            let timestamp = normalizedDate(value).timeIntervalSince1970
            // Match Python datetime's year range before any floating-point to Int
            // conversion. Non-finite and extreme dates must fail without trapping.
            guard timestamp.isFinite, timestamp >= -62_135_596_800, timestamp < 253_402_300_800 else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                    debugDescription: "Date is outside the supported cloud range"))
            }
            var seconds = floor(timestamp)
            var micros = Int(((timestamp - seconds) * 1_000_000).rounded())
            if micros == 1_000_000 { seconds += 1; micros = 0 }
            let base = formatter.string(from: Date(timeIntervalSince1970: seconds))
            guard base.count == 20, base.hasSuffix("Z") else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                    debugDescription: "Date is outside the supported cloud range"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(String(base.dropLast()) + String(format: ".%06dZ", micros))
        }
        return result
    }
    static func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        result.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            // ISO8601DateFormatter truncates fractions on some OS versions. Parse
            // the whole second and zone first, then add the decimal independently.
            var whole = value
            var fraction: TimeInterval = 0
            if let dot = value.firstIndex(of: ".") {
                let start = value.index(after: dot)
                var end = start
                while end < value.endIndex, ("0"..."9").contains(value[end]) { end = value.index(after: end) }
                let digits = value[start..<end]
                guard !digits.isEmpty, digits.count <= 9, let number = Double("0." + digits) else {
                    throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Expected an ISO8601 date")
                }
                whole = String(value[..<dot]) + value[end...]
                fraction = number
            }
            guard let date = formatter.date(from: whole) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Expected an ISO8601 date")
            }
            return date.addingTimeInterval(fraction)
        }
        return result
    }
}

struct CloudSharedSource: Codable, Identifiable {
    let id: UUID
    let ownerId: UUID
    let ownerName: String
    let name: String
    let privacy: CloudUploadLevel
    let generation: Int
    let coverageStart: Date?
    let coverageEnd: Date?
    let lastSyncedAt: Date?
}
struct CloudParticipant: Codable, Identifiable, Equatable {
    let userId: UUID
    var sourceIds: [UUID]
    var id: UUID { userId }
}
struct CloudAvailabilityRequest: Encodable {
    let participants: [CloudParticipant]
    let windowStart: Date
    let windowEnd: Date
    let durationMinutes: Int
    let timezone: String
    let dailyStart: String
    let dailyEnd: String
}
struct CloudCandidate: Decodable, Identifiable {
    let start: Date
    let end: Date
    let suggestedStart: Date
    let suggestedEnd: Date
    var id: Date { suggestedStart }
}
struct CloudAvailability: Decodable {
    let timezone: String
    let checkedAt: Date
    let windows: [CloudCandidate]
}
struct CloudMeetingMember: Codable, Identifiable {
    let userId: UUID
    let response: String
    var id: UUID { userId }
}
struct CloudMeeting: Codable, Identifiable {
    let id: UUID
    let hostId: UUID
    let title: String
    let start: Date
    let end: Date
    let timezone: String
    let revision: Int
    let status: String
    let participants: [CloudMeetingMember]
    let updatedAt: Date
}
struct CloudShareLink: Decodable { let id: UUID; let token: String; let joinUrl: URL; let expiresAt: Date }
struct CloudFeedLink: Decodable { let id: UUID; let url: URL }

struct CloudDeviceTask: Decodable {
    let id: UUID
    let meetingId: UUID
    let revision: Int
    let action: String
}
struct CloudAccessRecord: Decodable {
    let id: UUID?
    let userId: UUID?
    let privacy: CloudUploadLevel
    let expiresAt: Date?
    let revoked: Bool?
    var identifier: UUID { id ?? userId ?? UUID() }
}

struct CloudCreateMeeting: Codable {
    var requestId: UUID
    let title: String
    let start: Date
    let end: Date
    let timezone: String
    let participants: [CloudParticipant]
    func samePayload(as other: CloudCreateMeeting) -> Bool {
        title == other.title && start == other.start && end == other.end && timezone == other.timezone && participants == other.participants
    }
}

/// One installation may log into several accounts without reusing a server-owned device UUID.
enum CloudDeviceIdentityPolicy {
    static func storageKey(endpoint: String, appleUserID: String) throws -> String {
        let canonical = try CloudEndpointPolicy.validated(endpoint).absoluteString
        guard !appleUserID.isEmpty else { throw CloudClientError.signIn }
        let value = canonical + "\u{0}" + appleUserID
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cloud.device.v1." + digest
    }
}

extension CloudDeviceIdentityPolicy {
    static func storageKey(endpoint: String, passwordUsername: String) throws -> String {
        let canonical = try CloudEndpointPolicy.validated(endpoint).absoluteString
        let username = try CloudPasswordPolicy.username(passwordUsername)
        let value = canonical + "\u{0}password\u{0}" + username
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cloud.device.v2." + digest
    }
}

/// Uses the same explicit preference as LanguageManager for labels outside SwiftUI Text.
/// Dynamic strings must follow the app language rather than the device's system language.
enum CloudCopy {
    static var locale: Locale {
        let preference = UserDefaults.standard.string(forKey: "app.language.preference") ?? "system"
        let code = preference == "system" ? (Bundle.main.preferredLocalizations.first ?? "en") : preference
        return Locale(identifier: code.lowercased().hasPrefix("zh") ? "zh-Hans" : "en")
    }
    static func text(_ key: String) -> String {
        let code = locale.identifier
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Cloud")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

extension CloudCopy {
    static func error(_ error: Error) -> String {
        guard let cloud = error as? CloudClientError else { return error.localizedDescription }
        switch cloud {
        case .invalidDisplayName: return text("请输入1至100个字符的昵称。")
        case .invalidEndpoint: return text("请输入不含账号、查询参数或片段的 HTTPS 服务器地址。")
        case .invalidResponse: return text("服务器返回了无法识别的数据。")
        case .http(let code, let message): return format("服务器请求失败（%d）：%@", code, text(message))
        case .keychain: return text("无法安全保存登录信息。")
        case .signIn: return text("登录未完成或已失效，请重新登录。")
        case .cloudLoginUnavailable: return text("此版本未启用 Apple 登录，请使用账号密码登录。")
        case .invalidUsername: return text("用户名需为3至32位英文字母、数字、点、下划线或短横线。")
        case .invalidPassword: return text("密码需为12至128个字符。空格也属于密码，请原样输入。")
        case .passwordMismatch: return text("两次输入的密码不一致。")
        case .missingInvite: return text("请输入管理员提供的邀请码。")
        case .permission: return text("请先在系统设置中允许完整日历访问。")
        case .missingSource: return text("所选日历已不可用，请重新确认云同步来源。")
        case .coverage: return text("没有足够的日历覆盖范围，请先同步来源。")
        case .noSources: return text("请明确选择用于云端忙闲的日历。")
        case .invalidEventTime: return text("某条日程的起止时间无效，尚未上传此来源。请在原日历中调整后再同步。")
        case .uploadFieldLimit(let field, let maximum): return format("某条日程的%@超过服务器允许的%d个字符，尚未上传此来源。请先调整原日程，或选择较少详情的上传级别。", text(field), maximum)
        }
    }
}


enum CloudUploadScopeError: Error, LocalizedError {
    case rangeTooLong, updatePending, reviewChanged
    var errorDescription: String? {
        switch self {
        case .rangeTooLong: return CloudCopy.text("云端上传日期范围最多180天。请调整日期后再确认。")
        case .updatePending: return CloudCopy.text("请先成功更新已确认的上传设置，再创建分享链接。")
        case .reviewChanged: return CloudCopy.text("上传范围已变更。请关闭此页，重新核对日历、日期与字段后再创建链接。")
        }
    }
}

enum CloudUploadScopePolicy {
    static func requiresUpdate(source: CloudSource, binding: CloudLocalBinding, level: CloudUploadLevel, range: SharedCalendarRange) -> Bool {
        level != source.uploadLevel || binding.uploadLevel != source.uploadLevel || range != binding.uploadRange
            || binding.hasPendingScope || source.coverageStart == nil || source.coverageEnd == nil
    }
    /// The existing snapshot API replaces one complete window and accepts at most 180 elapsed days.
    static func interval(for range: SharedCalendarRange, now: Date = Date()) throws -> DateInterval {
        let interval = try range.dateInterval(now: now)
        guard interval.duration > 0, interval.duration <= 180 * 86_400 else { throw CloudUploadScopeError.rangeTooLong }
        return interval
    }
}
