// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/LanguageSettingsView.swift
import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Form {
            Picker(selection: $languageManager.preference) {
                Text("language.system").tag(AppLanguage.system)
                Text("language.zhHans").tag(AppLanguage.zhHans)
                Text("language.en").tag(AppLanguage.en)
            } label: {
                Text("settings.language")
            }
            .pickerStyle(.inline)
        }
        .navigationTitle("settings.language")
    }
}

#Preview {
    LanguageSettingsView()
        .environmentObject(LanguageManager())
}
