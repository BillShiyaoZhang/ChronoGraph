// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Managers/LanguageManager.swift
import Foundation
import SwiftUI

// App supported languages and user preference
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system // follow system
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }

    static let supportedExplicit: [AppLanguage] = [.zhHans, .en]
}

final class LanguageManager: ObservableObject {
    @Published private(set) var effectiveLanguageCode: String = "en"
    @Published private(set) var effectiveLocale: Locale = Locale(identifier: "en")

    @Published var preference: AppLanguage = .system {
        didSet { persistAndRecompute() }
    }

    private let key = "app.language.preference"

    init() {
        load()
        recomputeEffective()
    }

    private func load() {
        if let raw = UserDefaults.standard.string(forKey: key) {
            if raw == AppLanguage.system.rawValue { preference = .system }
            else if let pref = AppLanguage(rawValue: raw) { preference = pref }
        }
    }

    private func persistAndRecompute() {
        UserDefaults.standard.set(preference.rawValue, forKey: key)
        recomputeEffective()
    }

    private func recomputeEffective() {
        switch preference {
        case .system:
            let best = Bundle.main.preferredLocalizations.first ?? "en"
            effectiveLanguageCode = best
            effectiveLocale = Locale(identifier: best)
        case .zhHans, .en:
            effectiveLanguageCode = preference.rawValue
            effectiveLocale = preference.locale ?? Locale(identifier: "en")
        }
        objectWillChange.send()
    }
}