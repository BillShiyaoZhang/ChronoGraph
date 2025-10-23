//
//  ChronoGraphApp.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import SwiftUI

@main
struct ChronoGraphApp: App {
    @StateObject private var languageManager = LanguageManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, languageManager.effectiveLocale)
                .environmentObject(languageManager)
        }
    }
}
