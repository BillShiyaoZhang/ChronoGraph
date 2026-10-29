import XCTest

#if DEBUG
/// Both entry points must expose the shipped policy before any cloud account exists.
final class PrivacyPolicyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEnglishPolicyFromSettings() {
        assertPolicy(language: "en", fromRegistration: false)
    }

    @MainActor func testChinesePolicyFromSettings() {
        assertPolicy(language: "zh-Hans", fromRegistration: false)
    }

    @MainActor func testEnglishPolicyBeforeCloudRegistration() {
        assertPolicy(language: "en", fromRegistration: true)
    }

    @MainActor func testChinesePolicyBeforeCloudRegistration() {
        assertPolicy(language: "zh-Hans", fromRegistration: true)
    }

    @MainActor private func assertPolicy(language: String, fromRegistration: Bool) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-password-fixtures",
            "-cloud-fixture-scenario", "password-fresh",
            "-app.language.preference", language,
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "en" ? "en_US" : "zh_CN"
        ]
        app.launch()
        defer { app.terminate() }

        tap("home.settings", in: app)
        let entryID: String
        if fromRegistration {
            tap("home.cloudWorkspace", in: app)
            tap("cloud.auth.showRegister", in: app)
            entryID = "cloud.auth.privacyPolicy"
        } else {
            entryID = "home.privacyPolicy"
        }
        tap(entryID, in: app)

        let content = app.scrollViews["privacy.policy.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[language == "en" ? "Privacy Policy" : "隐私政策"].exists)
        let opening = language == "en"
            ? "ChronoGraph processes calendar selection"
            : "ChronoGraph 在设备上处理日历筛选"
        let paragraph = content.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", opening)).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "The selected language's bundled policy must be readable")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Privacy policy — \(language) — \(fromRegistration ? "registration" : "settings")"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        tap("privacy.policy.done", in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(element(entryID, in: app).exists, "Done returns to the entry point")
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        _ = target.waitForExistence(timeout: 2)
        // Switching to registration focuses its first field. A full-window swipe
        // can land on the iPhone keyboard rather than scroll the lazy Form.
        if identifier == "cloud.auth.privacyPolicy", app.keyboards.firstMatch.exists {
            let done = app.buttons["cloud.auth.keyboard.done"]
            if done.exists && done.isHittable { done.tap() }
        }
        for _ in 0..<12 {
            if target.exists && target.isHittable { break }
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(target.exists, "Missing control: \(identifier)")
        XCTAssertTrue(target.isHittable, "Control is not visible: \(identifier)")
        target.tap()
    }
}
#endif
