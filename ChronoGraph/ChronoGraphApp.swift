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
    @StateObject private var workspace: SharingWorkspace
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let manager = SharedCalendarManager()
        _sharedCalendarManager = StateObject(wrappedValue: manager)
        #if DEBUG
        let isTesting = ProcessInfo.processInfo.arguments.contains("-sharing-home-fixtures") || ProcessInfo.processInfo.arguments.contains("-sharing-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        let isTesting = false
        #endif
        _workspace = StateObject(wrappedValue: SharingWorkspace(defaults: isTesting ? nil : .standard))
        SharedCalendarBackgroundRegistration.register(manager: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, languageManager.effectiveLocale)
                .environmentObject(languageManager)
                .environmentObject(sharedCalendarManager)
                .environmentObject(workspace)
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
