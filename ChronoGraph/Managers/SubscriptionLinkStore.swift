import Foundation

enum SubscriptionLinkError: Error, LocalizedError, Equatable {
    case invalidURL, missingTarget, storageUnavailable

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidURL: key = "share.calendar.link.invalid"
        case .missingTarget: key = "share.calendar.link.missingTarget"
        case .storageUnavailable: key = "share.calendar.link.storage"
        }
        return NSLocalizedString(key, comment: "Calendar subscription link error")
    }
}

/// User-provided links only. This store never fetches a URL or changes calendar configuration.
@MainActor
final class SubscriptionLinkStore {
    private struct Record: Codable {
        var profileID: UUID
        var targetCalendarID: String
        var url: URL
    }

    private let storageURL: URL?
    private var records: [Record]

    #if DEBUG
    static let preview = SubscriptionLinkStore(memoryRecords: [])
    #endif

    private init(memoryRecords: [Record]) {
        storageURL = nil
        records = memoryRecords
    }

    init(inMemory: Bool = false, storageDirectory: URL? = nil) throws {
        if inMemory {
            storageURL = nil
            records = []
            return
        }
        do {
            let fileManager = FileManager.default
            var directory = try storageDirectory ?? fileManager.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SharedCalendars", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            #if os(iOS)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: directory.path)
            #endif
            let url = directory.appendingPathComponent("subscription-links.json")
            storageURL = url
            if fileManager.fileExists(atPath: url.path) {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
            } else {
                records = []
            }
        } catch {
            throw SubscriptionLinkError.storageUnavailable
        }
    }

    nonisolated static func validatedURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["webcal", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              components.user == nil, components.password == nil else {
            throw SubscriptionLinkError.invalidURL
        }
        components.scheme = scheme
        guard let url = components.url else { throw SubscriptionLinkError.invalidURL }
        return url
    }

    /// Seeing a different target invalidates the old binding, even if that target later reappears.
    func link(for profile: SharedCalendarProfile) throws -> URL? {
        try reloadRecords()
        let filtered = records.filter {
            $0.profileID != profile.id || $0.targetCalendarID == profile.targetCalendarID
        }
        if filtered.count != records.count { try replaceRecords(filtered) }
        guard let target = profile.targetCalendarID, !target.isEmpty else { return nil }
        guard let record = records.first(where: { $0.profileID == profile.id && $0.targetCalendarID == target }) else { return nil }
        return try Self.validatedURL(record.url.absoluteString)
    }

    @discardableResult
    func save(_ text: String, for profile: SharedCalendarProfile) throws -> URL {
        guard let target = profile.targetCalendarID, !target.isEmpty, !profile.pendingDeletion else {
            throw SubscriptionLinkError.missingTarget
        }
        let url = try Self.validatedURL(text)
        try reloadRecords()
        var updated = records.filter { $0.profileID != profile.id }
        updated.append(Record(profileID: profile.id, targetCalendarID: target, url: url))
        try replaceRecords(updated)
        return url
    }

    private func reloadRecords() throws {
        guard let storageURL else { return }
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: storageURL))
            } else {
                records = []
            }
        } catch {
            throw SubscriptionLinkError.storageUnavailable
        }
    }

    private func replaceRecords(_ updated: [Record]) throws {
        if let storageURL {
            do {
                let data = try JSONEncoder().encode(updated)
                #if os(iOS)
                try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: storageURL, options: .atomic)
                #endif
            } catch {
                throw SubscriptionLinkError.storageUnavailable
            }
        }
        records = updated
    }
}
