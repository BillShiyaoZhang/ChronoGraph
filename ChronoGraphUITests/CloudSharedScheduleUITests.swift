import XCTest

/// Home display uses synthetic cloud responses and an injected local event only.
/// No test in this suite reads EventKit or contacts the production service.
final class CloudSharedScheduleUITests: XCTestCase {
    private let opaque = "66666666-6666-4666-8666-666666666666"
    private let partial = "77777777-7777-4777-8777-777777777777"
    private let full = "88888888-8888-4888-8888-888888888888"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            screenshot("Cloud home failure — " + name, app: XCUIApplication())
        }
    }

    @MainActor func testPickerMixesLocalAndReceivedCalendarsWithoutRaisingSharingPermission() {
        let app = launch()
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        openSelection(in: app)
        select(partial, in: app)
        select(opaque, in: app)
        XCTAssertTrue(app.buttons[sourceID(partial)].isSelected)
        XCTAssertTrue(app.buttons[sourceID(opaque)].isSelected)
        screenshot("Home calendar selection — local and received sources", app: app)
        tap("home.calendars.done", in: app)

        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        tap("home.personal.privacy", in: app)
        tap("home.personal.privacy.full", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        assertNoSecretFields(in: app)
        screenshot("Home — cloud permissions remain capped in Full display", app: app)

        choosePreset("last3Days", in: app)
        assertVisible(app.staticTexts["Cloud visible tomorrow title"].firstMatch, in: app)
        assertNoSecretFields(in: app)
        screenshot("Home — received events follow the viewing date range", app: app)

        openSelection(in: app)
        XCTAssertTrue(app.buttons[sourceID(partial)].isSelected)
        tap(sourceID(partial), in: app)
        XCTAssertFalse(app.buttons[sourceID(partial)].isSelected)
        tap("home.calendars.done", in: app)
        waitAbsent(app.staticTexts["Cloud visible today title"].firstMatch)
        waitAbsent(app.staticTexts["Cloud visible tomorrow title"].firstMatch)
    }

    @MainActor func testUncoveredDatesRetainKnownEventsAndExplainIncompleteCoverage() {
        let app = launch("cloud-home-coverage")
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)

        choosePreset("last3Days", in: app)
        let status = element("home.cloud.status." + partial, in: app)
        assertVisible(status, in: app)
        XCTAssertFalse(status.label.isEmpty)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        waitAbsent(app.staticTexts["Cloud visible tomorrow title"].firstMatch)
        assertVisible(app.staticTexts["部分日历信息尚不完整"].firstMatch, in: app)
        XCTAssertFalse(app.staticTexts["无事件"].exists, "Uncovered cloud dates must not appear confirmed empty")
        screenshot("Home — unavailable cloud coverage is explicitly explained", app: app)
    }

    @MainActor func testCloudFailureCanRetryAndLogoutImmediatelyRemovesReceivedData() {
        let app = launch("cloud-home-retry")
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        let status = element("home.cloud.status." + partial, in: app)
        assertVisible(status, in: app)
        XCTAssertFalse(status.label.isEmpty)
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        tap("home.cloud.retry", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        screenshot("Home — retry restores cloud events alongside the local calendar", app: app)

        tap("home.settings", in: app)
        tap("home.cloudWorkspace", in: app)
        tap("cloud.account.open", in: app)
        tap("cloud.logout", in: app)
        XCTAssertTrue(app.textFields["cloud.auth.username"].waitForExistence(timeout: 8))
        let back = app.navigationBars["云端协作"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        tap("home.settings.done", in: app)
        waitAbsent(element("home.cloud.status." + partial, in: app))
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        openSelection(in: app)
        XCTAssertFalse(app.buttons[sourceID(partial)].exists)
        screenshot("Home calendar selection — signed-out cloud sources removed", app: app)
    }

    @MainActor func testRevokedSourceDoesNotRenderCachedOrUnapprovedEvents() {
        let app = launch("cloud-home-revoked")
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        let status = element("home.cloud.status." + partial, in: app)
        assertVisible(status, in: app)
        XCTAssertFalse(status.label.isEmpty)
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        assertNoSecretFields(in: app)
        screenshot("Home — revoked cloud access renders an explicit state", app: app)
    }

    @MainActor func testForegroundPermissionDowngradeDismissesAnOpenFullDetailsSheet() {
        let app = launch("cloud-home-downgrade")
        openSelection(in: app)
        select(full, in: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud full title"].firstMatch, in: app)
        tap("home.personal.privacy", in: app)
        tap("home.personal.privacy.full", in: app)
        let title = app.staticTexts["Cloud full title"].firstMatch
        assertVisible(title, in: app)
        title.tap()
        XCTAssertTrue(app.navigationBars["Cloud full title"].waitForExistence(timeout: 5))
        // Read-only Label/Text leaves can be visible while XCTest reports them
        // non-hittable. They are evidence fields, not interaction targets.
        XCTAssertTrue(app.staticTexts["Cloud visible location"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud visible notes"].firstMatch.waitForExistence(timeout: 5))
        screenshot("Cloud details — currently authorized full fields", app: app)

        // The next metadata request after an actual event read reduces this source
        // to opaque. Foreground refresh must also remove the retained detail model.
        XCUIDevice.shared.press(.home)
        app.activate()
        waitAbsent(app.navigationBars["Cloud full title"])
        waitAbsent(app.staticTexts["Cloud visible notes"].firstMatch)
        XCTAssertFalse(app.staticTexts["Cloud visible location"].exists)
        XCTAssertFalse(app.staticTexts["Cloud full title"].exists)
        assertNoSecretFields(in: app)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        let busy = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "event.title.cloud", "忙碌")).firstMatch
        assertVisible(busy, in: app)
        screenshot("Cloud details — permission downgrade closes stale details", app: app)
    }

    @MainActor private func launch(_ scenario: String = "cloud-home") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-signed-in-fixtures",
            "-cloud-fixture-scenario", scenario, "-app.language.preference", "zh-Hans",
            "-pref.privacyMode", "partial", "-pref.collapseEmptyDays", "NO",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["home.mode"].waitForExistence(timeout: 10))
        return app
    }

    private func sourceID(_ id: String) -> String { "cloud.home.source." + id }

    @MainActor private func openSelection(in app: XCUIApplication) {
        tap("home.mode", in: app)
        tap("home.mode.calendars", in: app)
        XCTAssertTrue(app.buttons["home.calendars.done"].waitForExistence(timeout: 5))
    }

    @MainActor private func select(_ source: String, in app: XCUIApplication) {
        let item = app.buttons[sourceID(source)]
        assertVisible(item, in: app)
        if !item.isSelected { item.tap() }
    }

    @MainActor private func choosePreset(_ value: String, in app: XCUIApplication) {
        tap("home.personal.range", in: app)
        let choice = app.buttons["home.personal.range." + value]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor private func assertNoSecretFields(in app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SECRET_")).count, 0,
                       "A local display setting cannot reveal fields excluded by the source's sharing permission")
    }

    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func tap(_ id: String, in app: XCUIApplication) {
        let item = element(id, in: app)
        assertVisible(item, in: app)
        item.tap()
    }

    @MainActor private func assertVisible(_ item: XCUIElement, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        // Menus animate after their trigger is tapped; scrolling before their
        // items appear dismisses them instead of revealing the target.
        _ = item.waitForExistence(timeout: 5)
        for direction in [true, false] {
            for _ in 0..<7 {
                if item.exists && item.isHittable { return }
                if direction { app.swipeUp() } else { app.swipeDown() }
            }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isHittable, file: file, line: line)
    }

    @MainActor private func waitAbsent(_ item: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: item)
        waitForExpectations(timeout: 8)
    }

    @MainActor private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
