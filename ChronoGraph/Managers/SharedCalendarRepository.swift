import Foundation
import SwiftData

@Model
final class SharedCalendarStateRecord {
    @Attribute(.unique) var key: String
    var payload: Data

    init(key: String = "shared-calendar-state-v1", payload: Data) {
        self.key = key
        self.payload = payload
    }
}

/// One local SwiftData transaction stores profiles, identities, overrides, mappings, and write intents.
/// CloudKit is explicitly disabled: EventKit alone transports already-published calendar events.
@MainActor
final class SharedCalendarRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let stateKey = "shared-calendar-state-v1"

    init(inMemory: Bool = false, storageDirectory: URL? = nil) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let fileManager = FileManager.default
            var directory = try storageDirectory ?? fileManager.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SharedCalendars", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // A restored device must not silently begin maintaining an existing public calendar.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            #if os(iOS)
            // Scheduled work remains possible after the first unlock, including while locked.
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: directory.path)
            #endif
            let storeURL = directory.appendingPathComponent("shared-calendars.store")
            configuration = ModelConfiguration("SharedCalendars", url: storeURL, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: SharedCalendarStateRecord.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func load() throws -> SharedCalendarState {
        guard let record = try context.fetch(FetchDescriptor<SharedCalendarStateRecord>()).first(where: { $0.key == stateKey }) else {
            return SharedCalendarState()
        }
        return try JSONDecoder().decode(SharedCalendarState.self, from: record.payload)
    }

    func save(_ state: SharedCalendarState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(state)
        do {
            if let record = try context.fetch(FetchDescriptor<SharedCalendarStateRecord>()).first(where: { $0.key == stateKey }) {
                record.payload = payload
            } else {
                context.insert(SharedCalendarStateRecord(payload: payload))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
