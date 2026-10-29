//
//  CalendarManager.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
@preconcurrency import EventKit
import SwiftUI

/// A long event can appear in adjacent query windows; calendar identities remain separate.
struct CalendarEventQueryIdentity: Hashable {
    let calendarID: String
    let eventID: String
    let start: Date
    let end: Date
}

@MainActor
final class CalendarManager: ObservableObject {
    private lazy var eventStore = EKEventStore()
    private let loadsCalendars: Bool
    // Cancellation token for async loads
    private var currentLoadToken = UUID()
    
    // Persistence keys
    private struct PrefKeys {
        static let privacyMode = "pref.privacyMode"
        static let dateRange = "pref.dateRange"
        static let selectedCalendars = "pref.selectedCalendars"
        // Custom date range persistence
        static let customStart = "pref.customRange.start"
        static let customEndExclusive = "pref.customRange.endExclusive"
        static let customTimeZone = "pref.customRange.timeZone"
    }
    
    @Published var events: [CalendarEvent] = []
    @Published var calendars: [EKCalendar] = []
    @Published private(set) var managedCalendarIDs: Set<String> = []
    @Published var selectedCalendars: Set<String> = [] { didSet { saveSelectedCalendars() } }
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var selectedDateRange = DateRange.today
    @Published private(set) var selectedDateRangeTimeZoneIdentifier = TimeZone.current.identifier
    @Published var privacyMode: PrivacyMode = .partial
    @Published var isLoading = false

    /// All ordinary viewing calendars remain available, but bulk selection excludes shared copies.
    var defaultCalendarIDs: Set<String> {
        CalendarSelectionPolicy.defaultSelection(availableIDs: Set(calendars.map(\.calendarIdentifier)),
                                                 managedIDs: managedCalendarIDs)
    }
    
    // MARK: - Authorization helpers (centralized)
    var isAuthorizedForRead: Bool {
        if #available(iOS 17.0, *) { return authorizationStatus == .fullAccess } else { return authorizationStatus == .authorized }
    }
    
    var isWriteOnly: Bool {
        if #available(iOS 17.0, *) { return authorizationStatus == .writeOnly } else { return false }
    }
    
    var isDeniedOrRestricted: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }
    
    enum DateRange: Hashable, Equatable {
        case today
        case last3Days
        case last7Days
        case last14Days
        // end is exclusive (start of the day after the selected end-date)
        case custom(start: Date, endExclusive: Date)
        
        // Presets for UI menus/popovers
        static var presets: [DateRange] { [.today, .last3Days, .last7Days, .last14Days] }
        
        // Identifier for persistence
        var identifier: String {
            switch self {
            case .today: return "today"
            case .last3Days: return "last3Days"
            case .last7Days: return "last7Days"
            case .last14Days: return "last14Days"
            case .custom: return "custom"
            }
        }
        
        var localizedName: String {
            switch self {
            case .today: return NSLocalizedString("dateRange.today", comment: "Today")
            case .last3Days: return NSLocalizedString("dateRange.last3Days", comment: "Last 3 days")
            case .last7Days: return NSLocalizedString("dateRange.last7Days", comment: "Last 7 days")
            case .last14Days: return NSLocalizedString("dateRange.last14Days", comment: "Last 14 days")
            case .custom: return NSLocalizedString("dateRange.custom", comment: "Custom")
            }
        }
        
        // SwiftUI-friendly key that follows Environment(\.locale)
        var localizedKey: LocalizedStringKey {
            switch self {
            case .today: return LocalizedStringKey("dateRange.today")
            case .last3Days: return LocalizedStringKey("dateRange.last3Days")
            case .last7Days: return LocalizedStringKey("dateRange.last7Days")
            case .last14Days: return LocalizedStringKey("dateRange.last14Days")
            case .custom: return LocalizedStringKey("dateRange.custom")
            }
        }
        
        var dateInterval: DateInterval {
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            switch self {
            case .today:
                let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
                return DateInterval(start: todayStart, end: end)
            case .last3Days:
                let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart
                return DateInterval(start: todayStart, end: end)
            case .last7Days:
                let end = cal.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart
                return DateInterval(start: todayStart, end: end)
            case .last14Days:
                let end = cal.date(byAdding: .day, value: 14, to: todayStart) ?? todayStart
                return DateInterval(start: todayStart, end: end)
            case .custom(let start, let endExclusive):
                return DateInterval(start: start, end: endExclusive)
            }
        }
        
        static func migrateLegacy(raw: String) -> DateRange? {
            switch raw {
            case "今天": return .today
            case "三天": return .last3Days
            case "一周": return .last7Days
            case "两周": return .last14Days
            default: return nil
            }
        }
    }
    
    init(loadsCalendars: Bool = true) {
        self.loadsCalendars = loadsCalendars
        guard loadsCalendars else { return }
        loadPreferences()
        refreshAuthorizationStatus()
    }
    
    private func loadPreferences() {
        let ud = UserDefaults.standard
        if let rawMode = ud.string(forKey: PrefKeys.privacyMode) {
            if let m = PrivacyMode(rawValue: rawMode) {
                privacyMode = m
            } else if let m = PrivacyMode.migrateLegacy(raw: rawMode) {
                privacyMode = m
                ud.set(m.rawValue, forKey: PrefKeys.privacyMode)
            }
        }
        if let rawRange = ud.string(forKey: PrefKeys.dateRange) {
            switch rawRange {
            case "today": selectedDateRange = .today
            case "last3Days": selectedDateRange = .last3Days
            case "last7Days": selectedDateRange = .last7Days
            case "last14Days": selectedDateRange = .last14Days
            case "custom":
                let startTS = ud.double(forKey: PrefKeys.customStart)
                let endTS = ud.double(forKey: PrefKeys.customEndExclusive)
                let zone = ud.string(forKey: PrefKeys.customTimeZone) ?? TimeZone.current.identifier
                if startTS > 0, endTS > 0,
                   (try? SharedCalendarRange.fixed(start: Date(timeIntervalSince1970: startTS),
                       endExclusive: Date(timeIntervalSince1970: endTS), timeZoneIdentifier: zone).dateInterval()) != nil {
                    let start = Date(timeIntervalSince1970: startTS)
                    let endExclusive = Date(timeIntervalSince1970: endTS)
                    selectedDateRange = .custom(start: start, endExclusive: endExclusive)
                    selectedDateRangeTimeZoneIdentifier = zone
                } else {
                    selectedDateRange = .today
                    ud.set("today", forKey: PrefKeys.dateRange)
                }
            default:
                if let r = DateRange.migrateLegacy(raw: rawRange) {
                    selectedDateRange = r
                    ud.set(r.identifier, forKey: PrefKeys.dateRange)
                }
            }
        }
        if let stored = ud.array(forKey: PrefKeys.selectedCalendars) as? [String] {
            selectedCalendars = Set(stored)
        }
    }
    
    func requestCalendarAccess() async {
        guard loadsCalendars else { return }
        do {
            // Use the new iOS 17+ API for requesting calendar access
            if #available(iOS 17.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                await MainActor.run {
                    self.authorizationStatus = granted ? .fullAccess : .denied
                    if granted {
                        self.loadCalendars()
                        self.loadEvents()
                    }
                }
            } else {
                // Fallback for iOS 16 and earlier
                let granted = try await eventStore.requestAccess(to: .event)
                await MainActor.run {
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.loadCalendars()
                        self.loadEvents()
                    }
                }
            }
        } catch {
            print("Calendar access request failed: \(error)")
            await MainActor.run {
                self.authorizationStatus = .denied
            }
        }
    }
    
    func refreshAuthorizationStatus() {
        guard loadsCalendars else { return }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorizedForRead {
            loadCalendars()
            loadEvents()
        } else {
            currentLoadToken = UUID()
            events = []
            calendars = []
            isLoading = false
        }
    }
    
    private func saveSelectedCalendars() {
        guard loadsCalendars else { return }
        UserDefaults.standard.set(Array(selectedCalendars), forKey: PrefKeys.selectedCalendars)
    }
    
    private func loadCalendars() {
        let defaults = UserDefaults.standard
        let savedSelection = defaults.object(forKey: PrefKeys.selectedCalendars) == nil ? nil : selectedCalendars
        calendars = eventStore.calendars(for: .event)
        let knownIDs = Set(defaults.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? [])
        managedCalendarIDs = CalendarSelectionPolicy.managedCalendarIDs(in: calendars.map {
            CalendarSelectionPolicy.Item(id: $0.calendarIdentifier, title: $0.title)
        }, knownIDs: knownIDs)
        let migrationKey = CalendarSelectionPolicy.legacySelectionMigrationDefaultsKey
        selectedCalendars = CalendarSelectionPolicy.restoredSelection(savedSelection: savedSelection,
            availableIDs: Set(calendars.map(\.calendarIdentifier)), managedIDs: managedCalendarIDs,
            removeLegacyManagedSelection: !defaults.bool(forKey: migrationKey))
        // Only old automatic choices are removed. Subsequent manual selections survive reloads.
        defaults.set(true, forKey: migrationKey)
    }

    func selectAllDefaultCalendars() {
        selectedCalendars = defaultCalendarIDs
        loadEvents()
    }
    
    func loadEvents() {
        guard loadsCalendars, isAuthorizedForRead else { return }
        isLoading = true
        let token = UUID()
        currentLoadToken = token
        let interval = selectedDateRange.dateInterval
        let selectedCalendarObjects = calendars.filter { selectedCalendars.contains($0.calendarIdentifier) }
        guard !selectedCalendarObjects.isEmpty else {
            events = []
            isLoading = false
            return
        }
        let store = eventStore
        struct CalendarFetchContext: @unchecked Sendable {
            let store: EKEventStore
            let interval: DateInterval
            let calendars: [EKCalendar]
            let token: UUID
        }
        let context = CalendarFetchContext(store: store, interval: interval, calendars: selectedCalendarObjects, token: token)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // EventKit truncates a single predicate to four years. Fetch bounded windows
            // so a supported multi-year selection does not silently omit later events.
            var mapped: [CalendarEvent] = []
            var seen = Set<CalendarEventQueryIdentity>()
            var start = context.interval.start
            while start < context.interval.end {
                let end = min(start.addingTimeInterval(366 * 86_400), context.interval.end)
                let predicate = context.store.predicateForEvents(withStart: start, end: end, calendars: context.calendars)
                for event in context.store.events(matching: predicate) {
                    let identity = CalendarEventQueryIdentity(calendarID: event.calendar.calendarIdentifier,
                        eventID: event.eventIdentifier ?? event.calendarItemIdentifier, start: event.startDate, end: event.endDate)
                    if seen.insert(identity).inserted { mapped.append(CalendarEvent(from: event)) }
                }
                start = end
            }
            let sorted = mapped.sorted { a, b in
                if a.startDate != b.startDate { return a.startDate < b.startDate }
                if a.endDate != b.endDate { return a.endDate < b.endDate }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentLoadToken == context.token else { return }
                self.events = sorted
                self.isLoading = false
            }
        }
    }
    
    func toggleCalendarSelection(_ calendarId: String) {
        if selectedCalendars.contains(calendarId) {
            selectedCalendars.remove(calendarId)
        } else {
            selectedCalendars.insert(calendarId)
        }
        loadEvents()
    }
    
    func updateDateRange(_ range: DateRange, timeZoneIdentifier: String = TimeZone.current.identifier) {
        if case .custom(let start, let end) = range {
            guard (try? SharedCalendarRange.fixed(start: start, endExclusive: end,
                timeZoneIdentifier: timeZoneIdentifier).dateInterval()) != nil else { return }
            selectedDateRangeTimeZoneIdentifier = timeZoneIdentifier
        } else {
            selectedDateRangeTimeZoneIdentifier = TimeZone.current.identifier
        }
        selectedDateRange = range
        guard loadsCalendars else { return }
        let ud = UserDefaults.standard
        switch range {
        case .today, .last3Days, .last7Days, .last14Days:
            ud.set(range.identifier, forKey: PrefKeys.dateRange)
            // Clear any old custom persistence to avoid stale values
            ud.removeObject(forKey: PrefKeys.customStart)
            ud.removeObject(forKey: PrefKeys.customEndExclusive)
            ud.removeObject(forKey: PrefKeys.customTimeZone)
        case .custom(let start, let endExclusive):
            ud.set("custom", forKey: PrefKeys.dateRange)
            ud.set(start.timeIntervalSince1970, forKey: PrefKeys.customStart)
            ud.set(endExclusive.timeIntervalSince1970, forKey: PrefKeys.customEndExclusive)
            ud.set(timeZoneIdentifier, forKey: PrefKeys.customTimeZone)
        }
        loadEvents()
    }
    
    func updatePrivacyMode(_ mode: PrivacyMode) {
        privacyMode = mode
        guard loadsCalendars else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: PrefKeys.privacyMode)
    }
}
