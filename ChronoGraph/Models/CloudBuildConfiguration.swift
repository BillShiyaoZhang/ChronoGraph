import Foundation

/// Keep runtime login availability paired with the opt-in signing entitlement.
enum CloudBuildConfiguration {
    static var appleSignInEnabled: Bool {
        appleSignInEnabled(value: Bundle.main.object(forInfoDictionaryKey: "ChronoGraphAppleSignInEnabled"))
    }

    static func appleSignInEnabled(value: Any?) -> Bool {
        // Xcode selects the entitlement file using the same exact YES/NO setting.
        // Unknown or unexpanded build settings must not enable an unsigned capability.
        (value as? String) == "YES"
    }
}
