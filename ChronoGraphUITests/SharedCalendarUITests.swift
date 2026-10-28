import XCTest

final class SharedCalendarUITests: XCTestCase {
    /// Run on an isolated simulator without an iCloud account. The DEBUG launch
    /// flag uses in-memory sharing configuration, so saved profiles cannot write
    /// to a pre-existing destination. Calendar access is requested when needed.
    @MainActor
    func testSharedCalendarEntryAndUnconfiguredAccount() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app.language.preference", "en", "-pref.privacyMode", "partial", "-sharing-ui-testing"]
        app.launch()

        let settings = app.buttons["Settings"]
        // Settings remains available before authorization, so its presence cannot
        // tell us whether the native first-access flow has been exercised.
        let requestAccess = app.buttons["Grant access"]
        if requestAccess.waitForExistence(timeout: 3) {
            attachScreenshot(app, named: "Calendar — Native first-access screen")
            requestAccess.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let fullAccess = springboard.buttons["Allow Full Access"]
            if fullAccess.waitForExistence(timeout: 5) {
                attachScreenshot(springboard, named: "Calendar — Native full-access permission")
                fullAccess.tap()
            } else {
                let applicationAlert = app.alerts.buttons["Allow Full Access"]
                XCTAssertTrue(applicationAlert.waitForExistence(timeout: 5), "The system must offer full Calendar access on the isolated simulator.")
                applicationAlert.tap()
            }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let sharing = app.buttons["Shared Calendars"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        sharing.tap()

        let create = app.buttons["sharing.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share your schedule"].exists)
        attachScreenshot(app, named: "Shared Calendars — Empty State")
        create.tap()

        let name = app.textFields["sharing.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["sharing.save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)
        let privacyDescription = app.staticTexts["Show only time blocks, hide all details"]
        for _ in 0..<6 where !privacyDescription.exists { app.swipeUp() }
        XCTAssertTrue(privacyDescription.exists)
        XCTAssertFalse(app.staticTexts["privacy.opaque.desc"].exists)
        attachScreenshot(app, named: "Shared Calendar — Creation Form")
        for _ in 0..<6 where !name.isHittable { app.swipeDown() }
        name.tap()
        name.typeText("Smoke Test Calendar")
        XCTAssertFalse(save.isEnabled, "A name alone must not bypass destination-account selection and confirmation.")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
