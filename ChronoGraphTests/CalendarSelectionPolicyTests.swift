import Foundation
import Testing
@testable import ChronoGraph

struct CalendarSelectionPolicyTests {
    private let ordinaryIDs: Set<String> = ["work", "personal"]
    private let managedIDs: Set<String> = ["shared", "renamed-shared"]
    private var availableIDs: Set<String> { ordinaryIDs.union(managedIDs) }

    @Test func knownIdentitySurvivesRenamingAndPrefixFindsUnrecordedCopies() {
        let calendars = [
            CalendarSelectionPolicy.Item(id: "work", title: "Work"),
            CalendarSelectionPolicy.Item(id: "shared", title: "ChronoGraph · Family"),
            CalendarSelectionPolicy.Item(id: "renamed-shared", title: "Owner renamed this calendar")
        ]
        #expect(CalendarSelectionPolicy.managedCalendarIDs(in: calendars, knownIDs: ["renamed-shared"]) == managedIDs)
    }

    @Test func firstUseAndSelectAllChooseOnlyOrdinaryCalendars() {
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: nil, availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: true) == ordinaryIDs)
        #expect(CalendarSelectionPolicy.defaultSelection(availableIDs: availableIDs, managedIDs: managedIDs) == ordinaryIDs)
        #expect(CalendarSelectionPolicy.defaultSelection(availableIDs: managedIDs, managedIDs: managedIDs).isEmpty)
    }

    @Test func explicitlyEmptySelectionStaysEmpty() {
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: [], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: false).isEmpty)
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: [], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: true).isEmpty)
    }

    @Test func unavailableSourcesNeverExpandSelection() {
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: ["missing"], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: false).isEmpty)
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: ["work", "missing"], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: false) == ["work"])
    }

    @Test func migrationRemovesOldSharedCopiesWithoutChangingOtherChoices() {
        let legacy: Set<String> = ["work", "shared", "renamed-shared"]
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: legacy, availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: true) == ["work"])
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: ["shared"], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: true).isEmpty)
    }

    @Test func explicitSharedCopySelectionSurvivesLaterLoadsAndRenaming() {
        let explicit: Set<String> = ["work", "renamed-shared"]
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: explicit, availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: false) == explicit)
        // A newly created copy is available, but is never added to a saved selection automatically.
        #expect(CalendarSelectionPolicy.restoredSelection(savedSelection: ["work"], availableIDs: availableIDs,
            managedIDs: managedIDs, removeLegacyManagedSelection: false) == ["work"])
    }

    @MainActor @Test func disabledCalendarLoadingKeepsFixturesInMemoryWithoutRefreshingAuthorization() async {
        let manager = CalendarManager(loadsCalendars: false)
        #expect(manager.authorizationStatus == .notDetermined)
        #expect(manager.selectedCalendars.isEmpty)
        let fixture = CalendarEvent(id: "fixture", title: "Fixture event", startDate: Date(timeIntervalSince1970: 0),
                                    endDate: Date(timeIntervalSince1970: 3600), calendar: "Fixture calendar")
        manager.authorizationStatus = .fullAccess
        manager.events = [fixture]
        manager.refreshAuthorizationStatus()
        manager.loadEvents()
        await manager.requestCalendarAccess()
        manager.toggleCalendarSelection("fixture-calendar")
        manager.updatePrivacyMode(.opaque)
        manager.updateDateRange(.last7Days)
        #expect(manager.authorizationStatus == .fullAccess)
        #expect(manager.events == [fixture])
        #expect(manager.calendars.isEmpty)
        #expect(manager.selectedCalendars == ["fixture-calendar"])
        #expect(manager.privacyMode == .opaque)
        #expect(manager.selectedDateRange == .last7Days)
    }
}
