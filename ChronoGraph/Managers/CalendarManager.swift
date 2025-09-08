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
    
    enum DateRange: String, CaseIterable {
        case today = "今天"
        case last3Days = "三天"
        case last7Days = "一周"
        case last14Days = "两周"
        
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
            }
        }
    }
    
    init() {
        loadPreferences()
        refreshAuthorizationStatus()
    }
    
    private func loadPreferences() {
        let ud = UserDefaults.standard
        if let rawMode = ud.string(forKey: PrefKeys.privacyMode), let m = PrivacyMode(rawValue: rawMode) { privacyMode = m }
        if let rawRange = ud.string(forKey: PrefKeys.dateRange), let r = DateRange(rawValue: rawRange) { selectedDateRange = r }
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
        UserDefaults.standard.set(range.rawValue, forKey: PrefKeys.dateRange)
        loadEvents()
    }
    
    func updatePrivacyMode(_ mode: PrivacyMode) {
        privacyMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PrefKeys.privacyMode)
    }
}
