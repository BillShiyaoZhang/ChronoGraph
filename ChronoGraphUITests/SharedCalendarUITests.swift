import XCTest

final class SharedCalendarUITests: XCTestCase {
    /// Run on an isolated simulator without an iCloud account. The DEBUG launch
    /// flag uses in-memory sharing configuration, so saved profiles cannot write
    /// to a pre-existing destination. Calendar access is requested when needed.
    @MainActor
    func testSharedCalendarEntryAndUnconfiguredAccount() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app.language.preference", "en", "-pref.privacyMode", "partial", "-sharing-ui-testing"]
        app.launch()

        let settings = app.buttons["Settings"]
        if !settings.waitForExistence(timeout: 3) {
            let requestAccess = app.buttons["Grant access"]
            XCTAssertTrue(requestAccess.waitForExistence(timeout: 5), "The isolated simulator must allow requesting Calendar access.")
            requestAccess.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let fullAccess = springboard.buttons["Allow Full Access"]
            if fullAccess.waitForExistence(timeout: 5) {
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
        XCTAssertTrue(app.staticTexts["Show title and time"].exists)
        XCTAssertFalse(app.staticTexts["privacy.partial.desc"].exists)
        attachScreenshot(app, named: "Shared Calendar — Creation Form")
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
