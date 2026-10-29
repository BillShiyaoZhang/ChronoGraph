import XCTest

/// Home display uses synthetic cloud responses and an injected local event only.
/// No test in this suite reads EventKit or contacts the production service.
final class CloudSharedScheduleUITests: XCTestCase {
    private let owned = "55555555-5555-4555-8555-555555555555"
    private let opaque = "66666666-6666-4666-8666-666666666666"
    private let partial = "77777777-7777-4777-8777-777777777777"
    private let full = "88888888-8888-4888-8888-888888888888"
    private let firstOwner = "22222222-2222-4222-8222-222222222222"
    private let secondOwner = "33333333-3333-4333-8333-333333333333"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            screenshot("Cloud home failure — " + name, app: XCUIApplication())
        }
    }

    @MainActor func testOwnCloudCalendarComesFirstAndDisplaysItsServerProjection() {
        let app = launch("cloud-home-owned")
        openSelection(in: app)
        let own = element("cloud.home.owned." + owned, in: app)
        assertVisible(own, in: app)
        XCTAssertFalse(own.isSelected, "Existing local selections must not silently add cloud copies")
        let received = element("cloud.home.received.group", in: app)
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        XCTAssertLessThan(own.frame.minY, received.frame.minY)
        screenshot("Calendar selection — own and received cloud groups first", app: app)
        own.tap()
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Owned cloud today title"].firstMatch, in: app)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        tap("home.personal.privacy", in: app)
        tap("home.personal.privacy.full", in: app)
        assertNoSecretFields(in: app)
        screenshot("Home — owned cloud projection respects its content ceiling", app: app)
        openSelection(in: app)
        XCTAssertTrue(element("cloud.home.owned." + owned, in: app).isSelected)
    }

    @MainActor func testUnavailableCloudCatalogShowsRetryInsteadOfAnEmptySubscriptionConclusion() {
        let app = launch("cloud-home-catalog-offline")
        openSelection(in: app)
        assertVisible(element("cloud.home.error", in: app), in: app)
        XCTAssertFalse(element("cloud.home.owned.empty", in: app).exists)
        XCTAssertFalse(element("cloud.home.received.empty", in: app).exists)
        let retry = element("cloud.home.retry", in: app)
        assertVisible(retry, in: app)
        XCTAssertTrue(retry.isEnabled)
        screenshot("Calendar selection — unavailable catalog is unknown rather than empty", app: app)
        retry.tap()
        assertVisible(element("cloud.home.error", in: app), in: app)
        XCTAssertFalse(element("cloud.home.received.empty", in: app).exists)
    }

    @MainActor func testReceivedCalendarRemovalRequiresConfirmationAndClearsHomeDisplay() {
        let app = launch()
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        openSelection(in: app)
        tap("cloud.home.manage", in: app)
        tap("cloud.received.remove.open." + partial, in: app)
        XCTAssertTrue(element("cloud.received.remove.form", in: app).waitForExistence(timeout: 5))
        screenshot("Received calendar — explicit unsubscribe review", app: app)
        tap("cloud.received.remove.cancel", in: app)
        assertVisible(element("cloud.received.remove.open." + partial, in: app), in: app)
        tap("cloud.received.remove.open." + partial, in: app)
        tap("cloud.received.remove.confirm", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        XCTAssertFalse(element("cloud.received.remove.open." + partial, in: app).exists)
        assertVisible(element("cloud.received.remove.open." + opaque, in: app), in: app)
        XCTAssertFalse(element("cloud.received.remove.open." + owned, in: app).exists)
        closeReceivedCalendars(in: app)
        waitAbsent(app.staticTexts["Cloud visible today title"].firstMatch)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        openSelection(in: app)
        XCTAssertFalse(element(sourceID(partial), in: app).exists, "Refreshing cannot revive an unsubscribed source")
        assertVisible(element("cloud.home.owned." + owned, in: app), in: app)
        screenshot("Calendar selection — unsubscribe preserves own and other calendars", app: app)
    }

    @MainActor func testFailedUnsubscribeKeepsTheCalendarAvailableForAnExplicitRetry() {
        let app = launch("cloud-home-remove-failure")
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        openSelection(in: app)
        tap("cloud.home.manage", in: app)
        tap("cloud.received.remove.open." + partial, in: app)
        tap("cloud.received.remove.confirm", in: app)
        assertVisible(element("cloud.received.remove.error", in: app), in: app)
        let retry = element("cloud.received.remove.retry", in: app)
        assertVisible(retry, in: app)
        XCTAssertTrue(retry.isEnabled, "A failed request must retain the source so the same confirmed removal can be retried")
        screenshot("Received calendar — failure preserves subscription for retry", app: app)
        retry.tap()
        waitAbsent(element("cloud.received.remove.form", in: app))
        XCTAssertFalse(element("cloud.received.remove.open." + partial, in: app).exists)
        closeReceivedCalendars(in: app)
        waitAbsent(app.staticTexts["Cloud visible today title"].firstMatch)
        openSelection(in: app)
        XCTAssertFalse(element(sourceID(partial), in: app).exists)
    }

    @MainActor func testPickerSwipeCancellationPreservesSelectionThenRemovesLastOwnerAndLastSubscription() {
        let app = launch("cloud-home-remove-two-owners")
        openSelection(in: app)
        select(partial, in: app)
        select(full, in: app)
        XCTAssertTrue(element("cloud.home.received.owner." + firstOwner, in: app).exists)
        XCTAssertTrue(element("cloud.home.received.owner." + secondOwner, in: app).exists)

        openPickerSwipeRemoval(partial, in: app)
        tap("cloud.received.remove.cancel", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        let retained = app.buttons[sourceID(partial)]
        assertVisible(retained, in: app)
        XCTAssertTrue(retained.isSelected, "Cancelling swipe removal must preserve the subscription and its display selection")
        XCTAssertTrue(element("cloud.home.received.owner." + firstOwner, in: app).exists)

        openPickerSwipeRemoval(partial, in: app)
        confirmRemoval(in: app)
        waitAbsent(element(sourceID(partial), in: app))
        waitAbsent(element("cloud.home.received.owner." + firstOwner, in: app))
        let remaining = app.buttons[sourceID(full)]
        assertVisible(remaining, in: app)
        XCTAssertTrue(remaining.isSelected, "Removing one owner's final calendar must preserve another owner's selected row")
        XCTAssertFalse(element("cloud.home.received.empty", in: app).exists)

        openPickerSwipeRemoval(full, in: app)
        confirmRemoval(in: app)
        waitAbsent(element(sourceID(full), in: app))
        waitAbsent(element("cloud.home.received.owner." + secondOwner, in: app))
        assertVisible(element("cloud.home.received.empty", in: app), in: app)
        assertVisible(element("cloud.home.owned." + owned, in: app), in: app)
        screenshot("Picker swipe — last owner and last subscription removed without invalid collection updates", app: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        XCTAssertFalse(app.staticTexts["Cloud visible today title"].exists)
        openSelection(in: app)
        assertVisible(element("cloud.home.received.empty", in: app), in: app)
    }

    @MainActor func testPickerContextMenuCanCancelThenRemoveTheOnlyReceivedCalendar() {
        let app = launch("cloud-home-remove-singleton")
        openSelection(in: app)
        select(partial, in: app)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
        openSelection(in: app)

        openPickerContextRemoval(partial, in: app)
        tap("cloud.received.remove.cancel", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        let retained = app.buttons[sourceID(partial)]
        assertVisible(retained, in: app)
        XCTAssertTrue(retained.isSelected, "Cancelling a context-menu removal must not clear the selected row")

        openPickerContextRemoval(partial, in: app)
        confirmRemoval(in: app)
        waitAbsent(element(sourceID(partial), in: app))
        waitAbsent(element("cloud.home.received.owner." + firstOwner, in: app))
        assertVisible(element("cloud.home.received.empty", in: app), in: app)
        assertVisible(element("cloud.home.owned." + owned, in: app), in: app)
        tap("home.calendars.done", in: app)
        waitAbsent(app.staticTexts["Cloud visible today title"].firstMatch)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        openSelection(in: app)
        assertVisible(element("cloud.home.received.empty", in: app), in: app)
        XCTAssertFalse(element(sourceID(partial), in: app).exists, "Refreshing after the context-menu dismissal cannot restore the removed subscription")
        screenshot("Picker context menu — singleton removal remains empty after foreground refresh", app: app)
    }

    @MainActor func testPickerFullSwipeOnlyRevealsRemovalAndCancellationKeepsTheSingletonSelected() {
        let app = launch("cloud-home-remove-singleton")
        openSelection(in: app)
        select(partial, in: app)
        let button = app.buttons[sourceID(partial)]
        let row = app.cells.containing(.button, identifier: sourceID(partial)).firstMatch
        assertVisible(row, in: app)

        // The cell-wide system gesture crosses the full-swipe threshold. A slow
        // velocity avoids flinging past the row or depending on a short drag's endpoint.
        row.swipeLeft(velocity: .slow)
        XCTAssertEqual(app.state, .runningForeground, "A full swipe must leave the singleton's collection row alive")
        XCTAssertFalse(element("cloud.received.remove.form", in: app).exists,
                       "A full swipe must not invoke confirmation or unsubscribe automatically")
        let action = app.buttons["cloud.received.remove." + partial]
        XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isHittable,
                      "Full swipe must expose the explicit removal action")
        XCTAssertTrue(button.exists && button.isSelected, "Revealing removal must retain the subscription and its display selection")
        XCTAssertTrue(element("cloud.home.received.owner." + firstOwner, in: app).exists)
        screenshot("Picker full swipe — singleton remains selected until explicit action", app: app)

        action.tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element("cloud.received.remove.form", in: app).waitForExistence(timeout: 5))
        tap("cloud.received.remove.cancel", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        assertVisible(button, in: app)
        XCTAssertTrue(button.isSelected, "Cancelling after a full swipe must preserve the selected singleton")
        XCTAssertFalse(element("cloud.home.received.empty", in: app).exists)
        tap("home.calendars.done", in: app)
        assertVisible(app.staticTexts["Cloud visible today title"].firstMatch, in: app)
    }

    @MainActor func testReceivedManagementSwipeCanCancelThenRemoveOwnerSectionsAndTheFinalSubscription() {
        let app = launch("cloud-home-remove-two-owners")
        openSelection(in: app)
        select(partial, in: app)
        tap("cloud.home.manage", in: app)
        openManagementSwipeRemoval(partial, in: app)
        tap("cloud.received.remove.cancel", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        assertVisible(element("cloud.received.remove.open." + partial, in: app), in: app)
        XCTAssertTrue(element("cloud.received.owner." + firstOwner, in: app).exists)

        openManagementSwipeRemoval(partial, in: app)
        confirmRemoval(in: app)
        waitAbsent(element("cloud.received.remove.open." + partial, in: app))
        waitAbsent(element("cloud.received.owner." + firstOwner, in: app))
        assertVisible(element("cloud.received.remove.open." + full, in: app), in: app)

        openManagementSwipeRemoval(full, in: app)
        confirmRemoval(in: app)
        waitAbsent(element("cloud.received.remove.open." + full, in: app))
        waitAbsent(element("cloud.received.owner." + secondOwner, in: app))
        assertVisible(app.staticTexts["还没有收到的日历。粘贴对方的站内添加链接即可接收。"].firstMatch, in: app)
        assertVisible(element("cloud.incoming.token", in: app), in: app)
        screenshot("Received management swipe — final owner section transitions to empty", app: app)
        closeReceivedCalendars(in: app)
        waitAbsent(app.staticTexts["Cloud visible today title"].firstMatch)
        assertVisible(app.staticTexts["Local home event"].firstMatch, in: app)
        openSelection(in: app)
        assertVisible(element("cloud.home.received.empty", in: app), in: app)
        assertVisible(element("cloud.home.owned." + owned, in: app), in: app)
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

    @MainActor private func closeReceivedCalendars(in app: XCUIApplication) {
        let done = element("home.calendars.done", in: app)
        if !(done.exists && done.isHittable) {
            let back = app.navigationBars["收到的日历"].buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        tap("home.calendars.done", in: app)
    }

    @MainActor private func select(_ source: String, in app: XCUIApplication) {
        let item = app.buttons[sourceID(source)]
        assertVisible(item, in: app)
        if !item.isSelected { item.tap() }
    }

    @MainActor private func openPickerSwipeRemoval(_ source: String, in app: XCUIApplication) {
        let button = app.buttons[sourceID(source)]
        assertVisible(button, in: app)
        let row = app.cells.containing(.button, identifier: sourceID(source)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Swipe the calendar's collection row rather than a subview")
        revealRemovalAction("cloud.received.remove." + source, on: row, in: app)
    }

    @MainActor private func openPickerContextRemoval(_ source: String, in app: XCUIApplication) {
        let row = app.buttons[sourceID(source)]
        assertVisible(row, in: app)
        row.press(forDuration: 1.1)
        let action = app.buttons["cloud.received.remove." + source]
        XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isHittable, "Long press must expose the actual context-menu removal action")
        action.tap()
        XCTAssertEqual(app.state, .runningForeground, "Opening context-menu confirmation must not crash while the menu is dismissed")
        XCTAssertTrue(element("cloud.received.remove.form", in: app).waitForExistence(timeout: 5))
    }

    @MainActor private func openManagementSwipeRemoval(_ source: String, in app: XCUIApplication) {
        let button = app.buttons["cloud.received.remove.open." + source]
        assertVisible(button, in: app)
        let row = app.cells.containing(.button, identifier: "cloud.received.remove.open." + source).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Swipe the received-calendar row, not its inline removal button")
        revealRemovalAction("cloud.received.remove.swipe." + source, on: row, in: app)
    }

    @MainActor private func revealRemovalAction(_ id: String, on row: XCUIElement, in app: XCUIApplication) {
        let action = app.buttons[id]
        if !(action.exists && action.isHittable) {
            // A partial swipe exposes the action without relying on full-swipe auto invocation.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isHittable, "The row's swipe action must be visible before opening removal review")
        XCTAssertFalse(element("cloud.received.remove.form", in: app).exists, "A partial swipe must expose the red action without automatically invoking it")
        screenshot("Revealed swipe action before opening confirmation — " + id, app: app)
        action.tap()
        XCTAssertEqual(app.state, .runningForeground, "Opening swipe confirmation must not optimistically delete an unchanged collection row")
        XCTAssertTrue(element("cloud.received.remove.form", in: app).waitForExistence(timeout: 5))
    }

    @MainActor private func confirmRemoval(in app: XCUIApplication) {
        tap("cloud.received.remove.confirm", in: app)
        waitAbsent(element("cloud.received.remove.form", in: app))
        XCTAssertEqual(app.state, .runningForeground, "Removing the final row must leave the presenting list alive")
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
