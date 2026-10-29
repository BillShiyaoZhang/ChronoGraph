import XCTest

final class CloudWorkspaceUITests: XCTestCase {
    @MainActor
    func testPersonalTeamBuildSavesEndpointWithoutStartingAppleLogin() throws {
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_EXPECT_LOCAL_SIGNING"] == "1" else {
            throw XCTSkip("Run explicitly against the default Personal Team configuration.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-app.language.preference", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        app.buttons["home.cloudWorkspace"].tap()
        XCTAssertTrue(app.textFields["cloud.auth.username"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["cloud.auth.password"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cloud.login.unavailable").firstMatch.exists)
        let server = app.textFields["cloud.server"]
        server.tap()
        server.typeText("https://signing-test.invalid/chronograph")
        app.buttons["cloud.configure"].tap()
        let notice = app.descendants(matching: .any).matching(identifier: "cloud.notice").firstMatch
        for _ in 0..<4 where !notice.exists { app.swipeUp() }
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Server address saved"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cloud.error").firstMatch.exists)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Personal Team — password login available without Apple entitlement"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
            attachment.name = "Cloud connection failure — " + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    @MainActor
    func testCloudIsOptionalAndRejectsAnInsecureEndpointBeforeConnecting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-app.language.preference", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        let cloud = app.buttons["home.cloudWorkspace"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        cloud.tap()
        let server = app.textFields["cloud.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        server.typeText("http://example.invalid")
        app.buttons["cloud.configure"].tap()
        let endpointError = app.descendants(matching: .any).matching(identifier: "cloud.error").firstMatch
        XCTAssertTrue(endpointError.waitForExistence(timeout: 5))
        XCTAssertTrue(endpointError.label.contains("Enter an HTTPS server address without credentials, query parameters, or a fragment."))
        XCTAssertFalse(app.buttons["cloud.upload.confirm"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Cloud workspace — optional HTTPS connection"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class CloudSignedInWorkspaceUITests: XCTestCase {
    private let own = "55555555-5555-4555-8555-555555555555"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let secondPeer = "33333333-3333-4333-8333-333333333333"
    private let me = "11111111-1111-4111-8111-111111111111"
    private let hosted = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let guest = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            screenshot("Cloud failure — " + name, XCUIApplication())
        }
    }

    @MainActor func testWorkspaceKeepsCoordinationVisibleAndSeparatesManagementPages() {
        let app = launch()
        for id in ["cloud.find.open", "cloud.uploads.open", "cloud.received.open", "cloud.account.open"] {
            expectVisible(button(id, in: app), in: app)
        }
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        XCTAssertFalse(app.textFields["cloud.incoming.token"].exists)
        XCTAssertFalse(app.buttons["cloud.source.add"].exists)
        tap("cloud.account.open", in: app)
        expectVisible(app.textFields["cloud.nickname"], in: app)
        XCTAssertFalse(app.textFields["cloud.incoming.token"].exists)
        XCTAssertFalse(app.buttons["cloud.source.add"].exists)
        screenshot("Cloud workspace — coordination and separate account management", app)
    }

    @MainActor func testSourceUploadStartsOpaqueAndConsentResetsWhenScopeChanges() {
        let app = launch(page: "cloud.uploads.open")
        tap("cloud.source.add", in: app)
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        // UIKit can expose the toolbar wrapper as enabled even when its SwiftUI
        // button is disabled. Verify that touching it cannot open a review.
        element("cloud.sharing.review", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(element("cloud.sharing.review.list", in: app).waitForExistence(timeout: 1))
        selectUploadCalendar("cloud.fixture.work", in: app)
        assertUploadLevelSelected("仅忙闲", in: app)
        reviewUpload(in: app)
        let confirm = button("cloud.upload.confirm", in: app)
        let consent = app.switches["cloud.upload.consent"]
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertTrue(element("cloud.upload.independentRules", in: app).exists)
        setOn(consent, in: app)
        XCTAssertTrue(confirm.isEnabled)
        tap("cloud.sharing.review.back", in: app)
        selectUploadCalendar("cloud.fixture.personal", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        setOn(consent, in: app)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.partial", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(confirm.isEnabled)
        screenshot("Cloud upload — separate review and scope consent", app)
    }

    @MainActor func testExistingUploadLevelRequiresFreshConsentAndCancellationKeepsTheOldLevel() {
        let app = launch(page: "cloud.uploads.open")
        let sourceID = uploadFixtureCalendar(in: app)
        tap("cloud.source.open." + sourceID, in: app)
        tap("cloud.source.level.edit", in: app)
        assertUploadLevelSelected("仅忙闲", in: app)
        XCTAssertFalse(element("cloud.source.level.confirm", in: app).exists)
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.partial", in: app)
        reviewUpload(in: app)
        let consent = app.switches["cloud.upload.consent"]
        let confirm = button("cloud.source.level.confirm", in: app)
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(confirm.isEnabled)
        setOn(consent, in: app)
        XCTAssertTrue(confirm.isEnabled)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.full", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(confirm.isEnabled)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.source.level.cancel", in: app)

        tap("cloud.source.level.edit", in: app)
        assertUploadLevelSelected("仅忙闲", in: app,
                                  message: "Cancelling an edit must preserve the confirmed default content")
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.partial", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        setOn(consent, in: app)
        tap("cloud.source.level.confirm", in: app)
        waitGone(confirm)

        tap("cloud.source.level.edit", in: app)
        assertUploadLevelSelected("标题与时间", in: app)
        XCTAssertFalse(element("cloud.source.level.confirm", in: app).exists)
        screenshot("Cloud content rules — cancellation and confirmed update", app)
        tap("cloud.source.level.cancel", in: app)
    }

    @MainActor func testUploadPauseAndResumeRequireConfirmationAndCancellationKeepsTheState() {
        let app = launch(page: "cloud.uploads.open")
        let sourceID = uploadFixtureCalendar(in: app)
        tap("cloud.source.open." + sourceID, in: app)
        tap("cloud.source.pause", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "不会撤销他人的访问")).firstMatch.exists)
        dismissDialog(cancel: "cloud.source.pause.cancel", confirming: "cloud.source.pause.confirm", in: app)
        XCTAssertTrue(button("cloud.source.pause", in: app).exists)
        XCTAssertFalse(button("cloud.source.resume", in: app).exists)

        tap("cloud.source.pause", in: app)
        tap("cloud.source.pause.confirm", in: app)
        expectVisible(button("cloud.source.resume", in: app), in: app)
        XCTAssertFalse(button("cloud.source.pause", in: app).exists)
        for id in ["cloud.source.share", "cloud.source.feed", "cloud.source.access." + sourceID] {
            expectVisible(element(id, in: app), in: app)
        }

        tap("cloud.source.resume", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "chronograph-ui.invalid")).firstMatch.exists)
        dismissDialog(cancel: "cloud.source.resume.cancel", confirming: "cloud.source.resume.confirm", in: app)
        XCTAssertTrue(button("cloud.source.resume", in: app).exists)
        XCTAssertFalse(button("cloud.source.pause", in: app).exists)
        tap("cloud.source.resume", in: app)
        tap("cloud.source.resume.confirm", in: app)
        expectVisible(button("cloud.source.pause", in: app), in: app)
        XCTAssertFalse(button("cloud.source.resume", in: app).exists)
        waitLabel("已恢复此设备上传", on: element("cloud.notice", in: app), in: app)
        screenshot("Cloud uploads — explicit pause and resume, cancellation preserves state", app)
    }

    @MainActor func testOpaqueUploadAndSourceDeletionRequireExplicitActions() {
        let app = launch(page: "cloud.uploads.open")
        tap("cloud.source.add", in: app)
        selectUploadCalendar("cloud.fixture.work", in: app)
        reviewUpload(in: app)
        let consent = app.switches["cloud.upload.consent"]
        setOn(consent, in: app)
        tap("cloud.upload.confirm", in: app)
        let source = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "cloud.source.name.", "Fixture Work")).firstMatch
        expectVisible(source, in: app)
        XCTAssertFalse(app.staticTexts["Private fixture appointment"].exists)
        let id = String(source.identifier.dropFirst("cloud.source.name.".count))
        screenshot("Cloud source — opaque snapshot uploaded", app)
        tap("cloud.source.open." + id, in: app)
        tap("cloud.source.delete", in: app)
        dismissDialog(cancel: "cloud.source.delete.cancel", confirming: "cloud.source.delete.confirm", in: app)
        XCTAssertTrue(button("cloud.source.delete", in: app).exists)
        tap("cloud.source.delete", in: app)
        tap("cloud.source.delete.confirm", in: app)
        waitGone(source)
    }

    @MainActor func testNicknameEditAndAccountDeletionCancellationPreserveAccount() {
        let app = launch(page: "cloud.account.open")
        replace(app.textFields["cloud.nickname"], with: "Simulator User", in: app)
        tap("cloud.nickname.save", in: app)
        waitLabel("昵称已保存", on: element("cloud.notice", in: app), in: app)
        tap("cloud.account.delete", in: app)
        XCTAssertTrue(button("cloud.account.delete.confirm", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Apple 登录授权请单独管理")).firstMatch.exists)
        screenshot("Cloud account — deletion confirmation before cancellation", app)
        dismissDialog(cancel: "cloud.account.delete.cancel", confirming: "cloud.account.delete.confirm", in: app)
        let nickname = app.textFields["cloud.nickname"]
        reveal(nickname, in: app)
        XCTAssertEqual(nickname.value as? String, "Simulator User")
        screenshot("Cloud account — nickname and destructive confirmation", app)
    }

    @MainActor func testConfirmedAccountDeletionReturnsToConnectionAndRemovesCloudViews() {
        let app = launch(page: "cloud.account.open")
        tap("cloud.account.delete", in: app)
        tap("cloud.account.delete.confirm", in: app)
        expectVisible(app.textFields["cloud.server"], in: app)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        XCTAssertFalse(app.buttons["cloud.source.add"].exists)
        waitLabel("云端账号已删除", on: element("cloud.notice", in: app), in: app)
        screenshot("Cloud account — deleted without touching native calendars", app)
    }

    @MainActor func testOfflineLogoutAlwaysRemovesLocalSession() {
        let app = launch("logout-offline", page: "cloud.account.open")
        tap("cloud.logout", in: app)
        expectVisible(app.textFields["cloud.server"], in: app)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        XCTAssertFalse(app.buttons["cloud.source.add"].exists)
        waitLabel("已退出本机", on: element("cloud.notice", inForm: "cloud.workspace.form", in: app), in: app)
        screenshot("Cloud logout — local session cleared despite server failure", app)
    }

    @MainActor func testLocalLogoutFinishesBeforeDelayedServerRevocation() {
        let app = launch("logout-delayed", page: "cloud.account.open")
        tap("cloud.logout", in: app)
        XCTAssertTrue(app.textFields["cloud.server"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        let notice = element("cloud.notice", inForm: "cloud.workspace.form", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 2))
        XCTAssertTrue(notice.label.contains("正在撤销服务器会话"), "The local connection screen must appear while the deliberately delayed DELETE is still pending")
        screenshot("Cloud logout — local account gone while server revocation is pending", app)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "已退出此设备"), evaluatedWith: notice)
        waitForExpectations(timeout: 20)
        screenshot("Cloud logout — delayed server revocation completed", app)
    }

    @MainActor func testGrantRevocationRemovesRecipient() {
        let app = launch(page: "cloud.uploads.open")
        tap("cloud.source.open." + own, in: app)
        tap("cloud.source.access." + own, in: app)
        XCTAssertTrue(app.navigationBars["分享授权"].waitForExistence(timeout: 5))
        tap("cloud.access.revoke." + peer, in: app)
        expectVisible(app.staticTexts["暂无记录"], in: app)
        XCTAssertFalse(app.buttons["cloud.access.revoke." + peer].exists)
        screenshot("Cloud sharing — recipient grant revoked", app)
    }

    @MainActor func testPublicFeedWarnsAboutLinkAccessAndCanBeRevoked() {
        let app = launch(page: "cloud.uploads.open")
        tap("cloud.source.open." + own, in: app)
        tap("cloud.source.feed", in: app)
        tap("cloud.link.create", in: app)
        XCTAssertTrue(app.navigationBars["公开订阅链接"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "任何持有此链接的人")).firstMatch.exists)
        screenshot("Cloud public feed — explicit bearer-link warning", app)
        tap("cloud.feed.revoke", in: app)
        tap("cloud.source.access." + own, in: app)
        XCTAssertTrue(app.navigationBars["分享授权"].waitForExistence(timeout: 5))
        tap("cloud.access.kind", in: app)
        app.buttons["订阅链接"].firstMatch.tap()
        expectVisible(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已撤销")).firstMatch, in: app)
    }

    @MainActor func testIncomingLinkValidationAndSuccessfulPersonAddition() {
        let app = launch(page: "cloud.received.open")
        let token = app.textFields["cloud.incoming.token"]
        replace(token, with: "invalid-fixture-link", in: app)
        tap("cloud.incoming.add", in: app)
        waitLabel("添加链接已失效", on: element("cloud.error", in: app), in: app)
        replace(token, with: "https://chronograph-ui.invalid/chronograph/join/fixture-new-person", in: app)
        tap("cloud.incoming.add", in: app)
        expectVisible(app.staticTexts["新朋友 · 新朋友日程"], in: app)
        reveal(token, in: app)
        XCTAssertEqual(token.value as? String, "粘贴添加链接或令牌")
        screenshot("Cloud people — accepted explicit incoming link", app)
    }

    @MainActor func testPeopleGroupingCandidateInvalidationAndCreatingAnInvitation() {
        let app = launch()
        openFind(in: app)
        XCTAssertEqual(app.switches.matching(identifier: "cloud.find.person." + peer).count, 1)
        XCTAssertEqual(app.switches.matching(identifier: "cloud.find.person." + secondPeer).count, 1)
        expectVisible(button("cloud.find.search", in: app), in: app)
        XCTAssertFalse(button("cloud.find.search", in: app).isEnabled)
        setOn(app.switches["cloud.find.person." + peer], in: app)
        tap("cloud.find.search", in: app)
        expectVisible(button("cloud.find.candidate", in: app), in: app)
        tap("cloud.find.duration", in: app); app.buttons["30分钟"].firstMatch.tap()
        XCTAssertFalse(app.buttons["cloud.find.candidate"].exists)
        tap("cloud.find.search", in: app)
        expectVisible(button("cloud.find.candidate", in: app), in: app)
        replace(app.textFields["cloud.find.title"], with: "Simulator Proposal", in: app)
        screenshot("Cloud availability — grouped people and candidate", app)
        tap("cloud.find.candidate", in: app)
        tap("cloud.find.propose", in: app)
        let proposed = app.staticTexts["Simulator Proposal"]
        expectVisible(proposed, in: app); proposed.tap()
        expectVisible(button("cloud.meeting.confirm", in: app), in: app)
        XCTAssertFalse(button("cloud.meeting.confirm", in: app).isEnabled, "Creating a proposal cannot invent another person's acceptance")
        screenshot("Cloud invitation — newly proposed and waiting for others", app)
    }

    @MainActor func testHostConfirmationAndCancellationHaveSeparateCalendarState() {
        let app = launch("host-proposal")
        tap("cloud.meeting.open." + hosted, in: app)
        tap("cloud.meeting.confirm", in: app)
        expectVisible(button("cloud.meeting.calendar", in: app), in: app)
        screenshot("Cloud invitation — all accepted and host finalized", app)
        tap("cloud.meeting.cancelConfirmed", in: app)
        expectVisible(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已取消 · 第1版")).firstMatch, in: app)
        XCTAssertFalse(app.buttons["cloud.meeting.calendar"].exists)
        XCTAssertFalse(app.buttons["cloud.meeting.confirm"].exists)
        screenshot("Cloud invitation — cancellation preserves explicit calendar handling", app)
    }

    @MainActor func testHostCannotConfirmBeforeAllParticipantsReply() {
        let app = launch("host-waiting")
        tap("cloud.meeting.open." + hosted, in: app)
        let confirm = button("cloud.meeting.confirm", in: app)
        expectVisible(confirm, in: app)
        XCTAssertFalse(confirm.isEnabled)
        tap("cloud.meeting.cancel", in: app)
        expectVisible(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已取消 · 第1版")).firstMatch, in: app)
    }

    @MainActor func testGuestCanRespondWithoutHostControls() {
        let app = launch("guest-proposal")
        tap("cloud.meeting.open." + guest, in: app)
        XCTAssertFalse(app.buttons["cloud.meeting.confirm"].exists)
        XCTAssertFalse(app.buttons["cloud.meeting.cancel"].exists)
        tap("cloud.meeting.accept", in: app)
        waitLabel("已同意", on: app.staticTexts["cloud.meeting.response." + me], in: app)
        tap("cloud.meeting.tentative", in: app)
        waitLabel("待定", on: app.staticTexts["cloud.meeting.response." + me], in: app)
        tap("cloud.meeting.decline", in: app)
        waitLabel("不方便", on: app.staticTexts["cloud.meeting.response." + me], in: app)
        screenshot("Cloud guest — versioned response and host-only controls", app)
    }

    @MainActor func testNewConflictDuringConfirmationDoesNotFinalize() {
        let app = launch("conflict")
        tap("cloud.meeting.open." + hosted, in: app)
        tap("cloud.meeting.confirm", in: app)
        waitLabel("新的冲突", on: element("cloud.error", in: app), in: app)
        XCTAssertFalse(app.buttons["cloud.meeting.calendar"].exists)
        XCTAssertTrue(button("cloud.meeting.confirm", in: app).exists)
        screenshot("Cloud conflict — server rejection keeps proposal unfinalized", app)
    }

    @MainActor func testStaleCalendarDataIsNotDisplayedAsEveryoneFree() {
        let app = launch("stale")
        openFind(in: app)
        setOn(app.switches["cloud.find.person." + peer], in: app)
        tap("cloud.find.search", in: app)
        waitLabel("超过24小时", on: element("cloud.error", inForm: "cloud.find.form", in: app), in: app)
        XCTAssertFalse(app.buttons["cloud.find.candidate"].exists)
        screenshot("Cloud availability — stale source blocks false-free result", app)
    }

    @MainActor func testNoCommonSlotsProvidesAnExplicitEmptyState() {
        let app = launch("no-slots")
        openFind(in: app)
        setOn(app.switches["cloud.find.person." + peer], in: app)
        tap("cloud.find.search", in: app)
        expectVisible(app.staticTexts["没有符合条件的时间。请缩短时长或调整日期、时段。"], in: app)
        XCTAssertFalse(app.buttons["cloud.find.candidate"].exists)
        screenshot("Cloud availability — no common slot", app)
    }

    @MainActor func testExpiredSessionReturnsToConnectionAndClearsSignedInViews() {
        let app = launch("expired", expectSignedIn: false)
        expectVisible(app.textFields["cloud.server"], in: app)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        XCTAssertFalse(app.buttons["cloud.source.add"].exists)
        screenshot("Cloud expired session — signed-in data cleared", app)
    }

    @MainActor func testServerFailureRetainsSessionAndShowsRecoverableError() {
        let app = launch("offline", page: "cloud.account.open")
        waitLabel("Fixture server unavailable", on: element("cloud.error", inForm: "cloud.account.form", in: app), in: app)
        expectVisible(app.textFields["cloud.nickname"], in: app)
        let accountNavigation = app.navigationBars["账号与服务器"]
        let back = accountNavigation.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
        waitGone(accountNavigation)
        tap("cloud.refresh", in: app)
        waitLabel("Fixture server unavailable", on: element("cloud.error", inForm: "cloud.workspace.form", in: app), in: app)
        screenshot("Cloud network failure — recoverable without false logout", app)
    }

    @MainActor private func launch(_ scenario: String = "standard", expectSignedIn: Bool = true, page: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-signed-in-fixtures", "-cloud-fixture-scenario", scenario,
            "-app.language.preference", "zh-Hans", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        tap("home.settings", in: app)
        tap("home.cloudWorkspace", in: app)
        expectVisible(expectSignedIn ? button("cloud.account.open", in: app) : app.textFields["cloud.server"], in: app)
        if let page, expectSignedIn { tap(page, in: app) }
        return app
    }
    @MainActor private func openFind(in app: XCUIApplication) {
        tap("cloud.find.open", in: app)
        XCTAssertTrue(app.navigationBars["找时间"].waitForExistence(timeout: 5))
        expectVisible(app.switches["cloud.find.person." + peer], in: app)
    }
    @MainActor private func selectUploadCalendar(_ id: String, in app: XCUIApplication) {
        tap("cloud.sharing.sources", in: app)
        tap("cloud.upload.calendar." + id, in: app)
        tap("cloud.sharing.sources.done", in: app)
    }
    @MainActor private func reviewUpload(in app: XCUIApplication) {
        tap("cloud.sharing.review", in: app)
        let consent = app.switches["cloud.upload.consent"]
        XCTAssertTrue(element("cloud.sharing.review.list", in: app).waitForExistence(timeout: 8))
        reveal(consent, in: app)
        XCTAssertTrue(consent.exists && consent.isHittable)
    }
    @MainActor private func uploadFixtureCalendar(in app: XCUIApplication) -> String {
        tap("cloud.source.add", in: app)
        selectUploadCalendar("cloud.fixture.work", in: app)
        reviewUpload(in: app)
        setOn(app.switches["cloud.upload.consent"], in: app)
        tap("cloud.upload.confirm", in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "cloud.source.open.", "Fixture Work")).firstMatch
        expectVisible(row, in: app)
        XCTAssertTrue(row.identifier.hasPrefix("cloud.source.open."))
        return String(row.identifier.dropFirst("cloud.source.open.".count))
    }
    @MainActor private func assertUploadLevelSelected(_ title: String, in app: XCUIApplication,
                                                     message: String = "The picker must retain the confirmed upload level",
                                                     file: StaticString = #filePath, line: UInt = #line) {
        tap("cloud.upload.level", in: app)
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(choice.isSelected, message, file: file, line: line)
        choice.tap()
    }
    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "identifier ==[c] %@", id)).firstMatch }
    @MainActor private func element(_ id: String, inForm formID: String, in app: XCUIApplication) -> XCUIElement {
        let form = app.descendants(matching: .any).matching(identifier: formID).firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "The current cloud page must expose its own form: \(formID)")
        return form.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func button(_ id: String, in app: XCUIApplication) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", id)).firstMatch }
    @MainActor private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        if !target.exists { _ = target.waitForExistence(timeout: 1) }
        reveal(target, in: app)
        XCTAssertTrue(target.exists, "Missing control: \(id)")
        if !target.isEnabled {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: target)
            waitForExpectations(timeout: 5)
        }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func expectVisible(_ target: XCUIElement, in app: XCUIApplication) {
        if !target.exists { _ = target.waitForExistence(timeout: 1) }
        reveal(target, in: app, maxSwipes: 3)
        XCTAssertTrue(target.exists, "Expected cloud content is missing: \(target.identifier) \(target.label)")
    }
    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        func band() -> (CGFloat, CGFloat) {
            let navigationBottom = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.frame.maxY ?? (app.frame.minY + 64)
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 40
            return (navigationBottom + 12, max(navigationBottom + 60, keyboardTop))
        }
        func ready() -> Bool {
            guard target.exists && target.isHittable else { return false }
            let id = target.identifier
            let overlayActions = ["cloud.account.delete.confirm", "cloud.source.delete.confirm", "cloud.find.propose"]
            if id == "home.settings" || overlayActions.contains(id) { return true }
            if !id.isEmpty && app.navigationBars.descendants(matching: .any).matching(identifier: id).firstMatch.exists { return true }
            let (top, bottom) = band()
            return target.frame.midY >= top && target.frame.midY <= bottom
        }
        func drag(_ delta: CGFloat) {
            let (top, bottom) = band()
            let height = bottom - top
            let bounded = max(-height * 0.45, min(height * 0.45, delta))
            let startY = top + height * (bounded > 0 ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.6, dy: startY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.6, dy: startY + bounded - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        if ready() { return }
        for searchDirection: CGFloat in [-1, 1] {
            for _ in 0..<maxSwipes {
                let (top, bottom) = band()
                if target.exists && target.frame.height > 0 {
                    let midpoint = target.frame.midY
                    if midpoint < top || midpoint > bottom { drag((top + bottom) / 2 - midpoint) }
                    else { drag(searchDirection * (bottom - top) * 0.3) }
                } else { drag(searchDirection * (bottom - top) * 0.45) }
                if ready() { return }
            }
        }
        XCTAssertTrue(ready(), "Cloud content did not enter the unobscured viewport")
    }
    @MainActor private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        if !field.exists { _ = field.waitForExistence(timeout: 1) }; reveal(field, in: app)
        XCTAssertTrue(field.exists)
        let old = field.value as? String ?? ""
        let existing = old == field.placeholderValue ? "" : old
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // Opening the keyboard can move this Form row. Empty fields need no cursor adjustment.
        if !existing.isEmpty {
            reveal(field, in: app)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
        XCTAssertEqual(field.value as? String, text, "The intended text must reach the field before its action runs")
        let done = app.buttons["cloud.auth.keyboard.done"]
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.firstMatch.exists { field.typeText("\n") }
        if app.keyboards.firstMatch.exists {
            guard let navigationBar = app.navigationBars.allElementsBoundByAccessibilityElement.first(where: { $0.isHittable }) else {
                XCTFail("No visible navigation bar is available to dismiss field editing"); return
            }
            navigationBar.tap()
        }
        if app.keyboards.firstMatch.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            waitForExpectations(timeout: 3)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Editing must finish before scrolling or invoking the field's action")
        XCTAssertEqual(field.value as? String, text)
    }
    @MainActor private func setOn(_ control: XCUIElement, in app: XCUIApplication) {
        reveal(control, in: app)
        if control.value as? String != "1" {
            // SwiftUI exposes the whole labeled row as the switch's AX frame.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            if control.value as? String != "1" {
                expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: control)
                waitForExpectations(timeout: 5)
            }
        }
        XCTAssertEqual(control.value as? String, "1")
    }
    @MainActor private func waitGone(_ target: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        waitForExpectations(timeout: 8)
    }
    @MainActor private func dismissDialog(cancel: String, confirming: String, in app: XCUIApplication) {
        let destructiveControl = element(confirming, in: app)
        XCTAssertTrue(destructiveControl.exists, "Only dismiss a confirmed, currently presented dialog")
        let cancelControl = element(cancel, in: app)
        if cancelControl.exists && cancelControl.isHittable { cancelControl.tap() }
        else {
            // A confirmation popover can omit its role-cancel button. The top navigation
            // area is outside this presented dialog; never tap near its destructive action.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).tap()
        }
        waitGone(destructiveControl)
    }
    @MainActor private func waitLabel(_ text: String, on target: XCUIElement, in app: XCUIApplication) {
        if !target.exists { _ = target.waitForExistence(timeout: 1) }
        reveal(target, in: app, maxSwipes: 3)
        if !target.label.contains(text) {
            expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: target)
            waitForExpectations(timeout: 8)
        }
    }
    @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
