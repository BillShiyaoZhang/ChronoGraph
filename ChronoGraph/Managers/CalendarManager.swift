//
//  CalendarManager.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
@preconcurrency import EventKit
import SwiftUI

@MainActor
final class CalendarManager: ObservableObject {
    private let eventStore = EKEventStore()
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
    }
    
    @Published var events: [CalendarEvent] = []
    @Published var calendars: [EKCalendar] = []
    @Published var selectedCalendars: Set<String> = [] { didSet { saveSelectedCalendars() } }
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var selectedDateRange = DateRange.today
    @Published var privacyMode: PrivacyMode = .partial
    @Published var isLoading = false
    
    // MARK: - Authorization helpers (centralized)
    var isAuthorizedForRead: Bool {
        if #available(iOS 17.0, *) { return authorizationStatus == .fullAccess } else { return authorizationStatus == .authorized }
    }
    
    var isWriteOnly: Bool {
        if #available(iOS 17.0, *) { return authorizationStatus == .writeOnly } else { return false }
    }
    
    var isDeniedOrRestricted: Bool {
        if #available(iOS 17.0, *) { return authorizationStatus == .denied } else { return authorizationStatus == .denied || authorizationStatus == .restricted }
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
    
    init() {
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
                if startTS > 0, endTS > 0 {
                    let start = Date(timeIntervalSince1970: startTS)
                    let endExclusive = Date(timeIntervalSince1970: endTS)
                    selectedDateRange = .custom(start: start, endExclusive: endExclusive)
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
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorizedForRead {
            loadCalendars()
            loadEvents()
        }
    }
    
    private func saveSelectedCalendars() {
        UserDefaults.standard.set(Array(selectedCalendars), forKey: PrefKeys.selectedCalendars)
    }
    
    private func loadCalendars() {
        let previousSelection = selectedCalendars // persisted or current
        calendars = eventStore.calendars(for: .event)
        let allIds = Set(calendars.map { $0.calendarIdentifier })
        if previousSelection.isEmpty {
            // First launch or nothing persisted: default to all
            selectedCalendars = allIds
        } else {
            let intersected = previousSelection.intersection(allIds)
            selectedCalendars = intersected.isEmpty ? allIds : intersected
        }
    }
    
    func loadEvents() {
        guard isAuthorizedForRead else { return }
        isLoading = true
        let token = UUID()
        currentLoadToken = token
        let interval = selectedDateRange.dateInterval
        let selectedCalendarObjects = calendars.filter { selectedCalendars.contains($0.calendarIdentifier) }
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
            let predicate = context.store.predicateForEvents(
                withStart: context.interval.start,
                end: context.interval.end,
                calendars: context.calendars
            )
            let ekEvents = context.store.events(matching: predicate)
            let mapped = ekEvents.map { CalendarEvent(from: $0) }
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
    
    func updateDateRange(_ range: DateRange) {
        selectedDateRange = range
        let ud = UserDefaults.standard
        switch range {
        case .today, .last3Days, .last7Days, .last14Days:
            ud.set(range.identifier, forKey: PrefKeys.dateRange)
            // Clear any old custom persistence to avoid stale values
            ud.removeObject(forKey: PrefKeys.customStart)
            ud.removeObject(forKey: PrefKeys.customEndExclusive)
        case .custom(let start, let endExclusive):
            ud.set("custom", forKey: PrefKeys.dateRange)
            ud.set(start.timeIntervalSince1970, forKey: PrefKeys.customStart)
            ud.set(endExclusive.timeIntervalSince1970, forKey: PrefKeys.customEndExclusive)
        }
        loadEvents()
    }
    
    func updatePrivacyMode(_ mode: PrivacyMode) {
        privacyMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PrefKeys.privacyMode)
    }
}
