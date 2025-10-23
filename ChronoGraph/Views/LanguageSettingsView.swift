// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/LanguageSettingsView.swift
import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Form {
            Picker(NSLocalizedString("settings.language", comment: "Language"), selection: $languageManager.preference) {
                Text(NSLocalizedString("language.system", comment: "Follow System")).tag(AppLanguage.system)
                Text(NSLocalizedString("language.zhHans", comment: "Simplified Chinese")).tag(AppLanguage.zhHans)
                Text(NSLocalizedString("language.en", comment: "English")).tag(AppLanguage.en)
            }
            .pickerStyle(.inline)
        }
        .navigationTitle(Text("settings.language"))
    }
}

#Preview {
    LanguageSettingsView()
        .environmentObject(LanguageManager())
}
