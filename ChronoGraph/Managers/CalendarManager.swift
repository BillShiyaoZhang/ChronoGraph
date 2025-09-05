//
//  CalendarManager.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
import EventKit
import SwiftUI

@MainActor
final class CalendarManager: ObservableObject {
    private let eventStore = EKEventStore()
    
    @Published var events: [CalendarEvent] = []
    @Published var calendars: [EKCalendar] = []
    @Published var selectedCalendars: Set<String> = []
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
        case tomorrow = "明天"
        case thisWeek = "本周"
        case nextWeek = "下周"
        case custom = "自定义"
        
        var dateInterval: DateInterval {
            let calendar = Calendar.current
            let now = Date()
            
            switch self {
            case .today:
                let startOfDay = calendar.startOfDay(for: now)
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                return DateInterval(start: startOfDay, end: endOfDay)
                
            case .tomorrow:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                let startOfDay = calendar.startOfDay(for: tomorrow)
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                return DateInterval(start: startOfDay, end: endOfDay)
                
            case .thisWeek:
                if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
                    return week
                } else {
                    let start = calendar.startOfDay(for: now)
                    let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
                    return DateInterval(start: start, end: end)
                }
                
            case .nextWeek:
                let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: now) ?? now
                if let week = calendar.dateInterval(of: .weekOfYear, for: nextWeek) {
                    return week
                } else {
                    let start = calendar.startOfDay(for: nextWeek)
                    let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
                    return DateInterval(start: start, end: end)
                }
                
            case .custom:
                return DateInterval(start: now, duration: 86400) // Default to 1 day
            }
        }
    }
    
    init() {
        refreshAuthorizationStatus()
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
    
    private func loadCalendars() {
        let previousSelection = selectedCalendars
        calendars = eventStore.calendars(for: .event)
        let allIds = Set(calendars.map { $0.calendarIdentifier })
        // Preserve previous selection; default to all only if nothing selected yet
        if previousSelection.isEmpty {
            selectedCalendars = allIds
        } else {
            selectedCalendars = previousSelection.intersection(allIds)
            if selectedCalendars.isEmpty { selectedCalendars = allIds }
        }
    }
    
    func loadEvents() {
        guard isAuthorizedForRead else { return }
        isLoading = true

        let interval = selectedDateRange.dateInterval
        let selectedCalendarObjects = calendars.filter { selectedCalendars.contains($0.calendarIdentifier) }

        let predicate = eventStore.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: selectedCalendarObjects
        )

        let ekEvents = eventStore.events(matching: predicate)
        let mapped = ekEvents.map { CalendarEvent(from: $0) }
        // Stable deterministic sort: startDate, then endDate, then title
        events = mapped.sorted { a, b in
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            if a.endDate != b.endDate { return a.endDate < b.endDate }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        isLoading = false
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
        loadEvents()
    }
    
    func updatePrivacyMode(_ mode: PrivacyMode) {
        privacyMode = mode
    }
}
