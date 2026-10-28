import Foundation
import CryptoKit

/// Wire models deliberately contain only fields accepted by the cloud upload contract.
enum CloudUploadLevel: String, Codable, CaseIterable, Identifiable {
    case opaque, partial, full
    var id: String { rawValue }
    var label: String {
        switch self { case .opaque: return "仅忙闲"; case .partial: return "忙闲和标题"; case .full: return "标题、地点和备注" }
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
