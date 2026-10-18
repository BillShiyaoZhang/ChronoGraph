import Foundation

/// Ordinary viewing may include a shared copy explicitly; automatic selection never adds one.
enum CalendarSelectionPolicy {
    static let managedCalendarIDsDefaultsKey = "sharing.managedCalendarIDs"
    static let legacySelectionMigrationDefaultsKey = "pref.managedCalendarSelectionMigrated.v1"
    static let managedCalendarNamePrefix = "ChronoGraph · "

    struct Item: Equatable, Sendable {
        var id: String
        var title: String
    }

    static func managedCalendarIDs(in calendars: [Item], knownIDs: Set<String>) -> Set<String> {
        knownIDs.union(calendars.lazy.filter { $0.title.hasPrefix(managedCalendarNamePrefix) }.map(\.id))
    }

    static func defaultSelection(availableIDs: Set<String>, managedIDs: Set<String>) -> Set<String> {
        availableIDs.subtracting(managedIDs)
    }

    /// A missing preference means first use. An explicitly saved empty set remains empty.
    /// Missing source IDs never cause a fallback to a broader set of calendars.
    static func restoredSelection(savedSelection: Set<String>?, availableIDs: Set<String>,
                                  managedIDs: Set<String>, removeLegacyManagedSelection: Bool) -> Set<String> {
        guard let savedSelection else { return defaultSelection(availableIDs: availableIDs, managedIDs: managedIDs) }
        let availableSelection = savedSelection.intersection(availableIDs)
        return removeLegacyManagedSelection ? availableSelection.subtracting(managedIDs) : availableSelection
    }
}
