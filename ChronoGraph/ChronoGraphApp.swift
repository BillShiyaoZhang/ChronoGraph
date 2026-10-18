//
//  ChronoGraphApp.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import SwiftUI
import EventKit

@main
@MainActor
struct ChronoGraphApp: App {
    @StateObject private var languageManager = LanguageManager()
    @StateObject private var sharedCalendarManager: SharedCalendarManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let manager = SharedCalendarManager()
        _sharedCalendarManager = StateObject(wrappedValue: manager)
        SharedCalendarBackgroundRegistration.register(manager: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, languageManager.effectiveLocale)
                .environmentObject(languageManager)
                .environmentObject(sharedCalendarManager)
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in
                    sharedCalendarManager.refresh()
                    sharedCalendarManager.requestAutomaticRefresh()
                }
                .task { sharedCalendarManager.foregroundRefresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { sharedCalendarManager.foregroundRefresh() }
                    if phase == .background { sharedCalendarManager.scheduleBackgroundRefresh() }
                }
        }
    }
}
