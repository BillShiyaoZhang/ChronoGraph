import XCTest

/// Exercises the same home entry points used for both sharing channels.
/// Every cloud request is intercepted by the explicitly enabled synthetic transport.
final class UnifiedSharingUITests: XCTestCase {
    private let ownSource = "55555555-5555-4555-8555-555555555555"
    private let guestMeeting = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let hostedMeeting = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let me = "11111111-1111-4111-8111-111111111111"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
            attachment.name = "Unified sharing failure — " + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testOverviewHubOffersBothChannelsAndExistingCloudCalendarSharesWithoutUploadingAgain() {
        let app = launch()
        openHub(in: app)
        for id in ["share.calendar.profile.Work", "share.calendar.profile.Family",
                   "share.calendar.cloud.profile." + ownSource, "share.calendar.create", "share.calendar.cloud.open"] {
            reveal(element(id, in: app), in: app)
            XCTAssertTrue(element(id, in: app).exists, "Both existing calendars and both creation channels must be reachable from the hub: \(id)")
        }
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)

        tap("share.calendar.create", in: app)
        let accountDraft = app.textFields["sharing.name"]
        XCTAssertTrue(accountDraft.waitForExistence(timeout: 5))
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        tap("sharing.draft.cancel", in: app)
        waitGone(accountDraft)

        openHub(in: app)
        tap("share.calendar.profile.Work", in: app)
        XCTAssertTrue(element("share.calendar.close", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("share.calendar.hub.close", in: app).exists)
        XCTAssertTrue(app.staticTexts["Work"].firstMatch.exists)
        tap("share.calendar.close", in: app)

        openHub(in: app)
        tap("share.calendar.cloud.profile." + ownSource, in: app)
        XCTAssertTrue(element("cloud.source.share", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("cloud.source.share", in: app).isHittable, "The frequent sharing action should be visible before the scope details")
        let feed = element("cloud.source.feed", in: app)
        reveal(feed, in: app)
        XCTAssertTrue(feed.exists && feed.isHittable)
        XCTAssertTrue(feed.isEnabled)
        XCTAssertFalse(element("cloud.upload.calendar.cloud.fixture.work", in: app).exists)
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        tap("cloud.source.share", in: app)
        let createLink = element("cloud.link.create", in: app)
        reveal(createLink, in: app)
        XCTAssertTrue(createLink.exists && createLink.isHittable)
        XCTAssertFalse(element("cloud.link.share", in: app).exists, "Opening a link method must not create sharing access before confirmation")
        tap("cloud.link.create", in: app)
        tap("cloud.link.share", in: app)
        assertSystemLinkShare(host: "chronograph-ui.invalid", in: app)
    }

    @MainActor func testCurrentICloudCalendarKeepsDirectLinkSharingAndOffersTheHubSeparately() {
        let app = launch()
        tap("home.mode", in: app)
        tap("home.shared.profile.Work", in: app)
        tap("home.share", in: app)
        tap("home.share.calendar", in: app)
        XCTAssertTrue(element("share.calendar.close", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("share.calendar.hub.close", in: app).exists)
        let input = element("share.calendar.link.input", in: app)
        reveal(input, in: app)
        input.tap()
        input.typeText("webcal://calendar.example.com/unified-sharing-fixture.ics")
        tap("share.calendar.keyboard.done", in: app)
        tap("share.calendar.link.save", in: app)
        let savedSend = element("share.calendar.link.send", in: app)
        reveal(savedSend, in: app)
        XCTAssertTrue(savedSend.exists && savedSend.isHittable)
        tap("share.calendar.close", in: app)

        tap("home.share", in: app)
        tap("home.share.calendar", in: app)
        XCTAssertTrue(element("share.calendar.link.send", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("share.calendar.link.send", in: app).isHittable, "A saved link should be ready to send on the first screen")
        XCTAssertFalse(element("share.calendar.link.input", in: app).exists)
        XCTAssertFalse(element("share.calendar.hub.close", in: app).exists)
        tap("share.calendar.link.send", in: app)
        assertSystemLinkShare(host: "calendar.example.com", in: app)

        tap("home.share", in: app)
        tap("home.share.otherMethods", in: app)
        XCTAssertTrue(element("share.calendar.hub.close", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("share.calendar.profile.Work", in: app).exists)
        reveal(element("share.calendar.cloud.open", in: app), in: app)
        XCTAssertTrue(element("share.calendar.cloud.open", in: app).exists)
    }

    @MainActor func testServerCreationRequiresFreshConsentForSourcesDatesAndFieldsAndCancelCreatesNothing() {
        let app = launch()
        chooseRange("last3Days", prefix: "home.personal.range", in: app)
        openHub(in: app)
        tap("share.calendar.cloud.open", in: app)
        XCTAssertTrue(element("cloud.upload.cancel", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        // UIKit can expose the toolbar wrapper as enabled even when its SwiftUI
        // button is disabled. Verify that touching it cannot open a review.
        element("cloud.sharing.review", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(element("cloud.sharing.review.list", in: app).waitForExistence(timeout: 1))
        selectUploadCalendar("cloud.fixture.work", in: app)
        tap("cloud.upload.level", in: app)
        let opaque = element("cloud.upload.level.opaque", in: app)
        XCTAssertTrue(opaque.waitForExistence(timeout: 5))
        XCTAssertTrue(opaque.isSelected)
        opaque.tap()
        tap("cloud.upload.range.customize", in: app)
        XCTAssertEqual(app.textFields["sharing.range.pastDays"].value as? String, "0")
        XCTAssertEqual(app.textFields["sharing.range.futureDays"].value as? String, "2")
        tap("sharing.range.cancel", in: app)
        reviewUpload(in: app)
        let consent = app.switches["cloud.upload.consent"]
        XCTAssertEqual(consent.value as? String, "0")
        assertUploadConfirmation(enabled: false, in: app)
        setConsent(consent, in: app)
        assertUploadConfirmation(enabled: true, in: app)
        tap("cloud.sharing.review.back", in: app)
        chooseRange("last14Days", prefix: "cloud.upload.range", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        assertUploadConfirmation(enabled: false, in: app)
        setConsent(consent, in: app)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.partial", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        assertUploadConfirmation(enabled: false, in: app)
        setConsent(consent, in: app)
        tap("cloud.sharing.review.back", in: app)
        selectUploadCalendar("cloud.fixture.personal", in: app)
        reviewUpload(in: app)
        XCTAssertEqual(consent.value as? String, "0")
        assertUploadConfirmation(enabled: false, in: app)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.cancel", in: app)
        tap("cloud.sharing.close", in: app)
        XCTAssertTrue(element("share.calendar.hub.close", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("share.calendar.cloud.profile." + ownSource, in: app).exists)
        let createdSource = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@)",
            "share.calendar.cloud.profile.", "Fixture Work", "Fixture Personal", "Shared calendar")).firstMatch
        XCTAssertFalse(createdSource.exists, "Cancelling an upload draft must not create a server source")
    }

    @MainActor func testConfirmedServerCreationUploadsOnceAndContinuesToSharingWithTheChosenRange() {
        let app = launch(scenario: "sharing-hub-create-once")
        chooseRange("last3Days", prefix: "home.personal.range", in: app)
        openHub(in: app)
        tap("share.calendar.cloud.open", in: app)
        selectUploadCalendar("cloud.fixture.work", in: app)

        tap("cloud.upload.level", in: app)
        let opaque = element("cloud.upload.level.opaque", in: app)
        XCTAssertTrue(opaque.waitForExistence(timeout: 5))
        XCTAssertTrue(opaque.isSelected, "A new server source starts with availability only")
        opaque.tap()
        tap("cloud.upload.range.customize", in: app)
        XCTAssertEqual(app.textFields["sharing.range.pastDays"].value as? String, "0")
        XCTAssertEqual(app.textFields["sharing.range.futureDays"].value as? String, "2")
        tap("sharing.range.cancel", in: app)
        reviewUpload(in: app)
        let consent = app.switches["cloud.upload.consent"]
        reveal(consent, in: app)
        XCTAssertEqual(consent.value as? String, "0")
        setConsent(consent, in: app)
        tap("cloud.upload.confirm", in: app)

        let share = element("cloud.source.share", in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 10), "A completed upload must dismiss the editor and open the new source's sharing methods")
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.navigationBars["Fixture Work"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        XCTAssertFalse(element("cloud.upload.range.pending", in: app).exists)
        XCTAssertFalse(app.staticTexts["Private fixture appointment"].exists)

        tap("cloud.source.level.edit", in: app)
        tap("cloud.upload.range.customize", in: app)
        XCTAssertEqual(app.textFields["sharing.range.pastDays"].value as? String, "0")
        XCTAssertEqual(app.textFields["sharing.range.futureDays"].value as? String, "2", "Successful creation must persist the confirmed three-day upload range")
        tap("sharing.range.cancel", in: app)
        tap("cloud.source.level.cancel", in: app)
        tap("cloud.source.share", in: app)
        tap("cloud.link.create", in: app)
        let completedLink = element("cloud.link.share", in: app)
        reveal(completedLink, in: app)
        XCTAssertTrue(completedLink.exists && completedLink.isHittable,
                      "This fixture rejects link creation unless the newly created source received exactly one snapshot; opening settings or sharing methods must not upload again")
        XCTAssertFalse(element("cloud.error", in: app).exists)
    }

    @MainActor func testHomePendingInvitationOpensDetailsAndDisappearsAfterResponding() {
        let app = launch(scenario: "guest-proposal")
        let pending = element("home.invitations", in: app)
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertEqual(pending.value as? String, "1")
        tap("home.invitations", in: app)
        let list = element("cloud.invitations.list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let meetingID = "cloud.meeting.open." + guestMeeting
        XCTAssertTrue(element(meetingID, in: app).waitForExistence(timeout: 5))
        // The manager's focused reader test verifies that this refresh performs no upload.
        // This path also checks that refreshing preserves the pending invitation and entry route.
        list.swipeDown()
        tap(meetingID, in: app)
        XCTAssertTrue(element("cloud.meeting.accept", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("cloud.meeting.confirm", in: app).exists)
        tap("cloud.meeting.accept", in: app)
        let response = app.staticTexts["cloud.meeting.response." + me]
        waitLabel("Accepted", on: response)
        let details = app.navigationBars["Invitation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.buttons.element(boundBy: 0).tap()
        tap("cloud.invitations.done", in: app)
        waitGone(list)
        waitGone(pending)
        XCTAssertTrue(element("home.share", in: app).exists)
    }

    @MainActor func testHomeHostInvitationOpensSentDetailsAndDisappearsAfterFinalizing() {
        let app = launch(scenario: "host-proposal")
        let action = element("home.invitations", in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertEqual(action.value as? String, "1", "A host must see the invitation that is ready for final confirmation")
        tap("home.invitations", in: app)
        let list = element("cloud.invitations.list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let sent = element("cloud.invitations.sent", in: app)
        reveal(sent, in: app)
        XCTAssertTrue(sent.exists && sent.isHittable)
        XCTAssertFalse(element("cloud.invitations.pending", in: app).exists, "The host's finalization task belongs to sent invitations, not guest responses")
        tap("cloud.meeting.open." + hostedMeeting, in: app)
        let confirm = element("cloud.meeting.confirm", in: app)
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        XCTAssertTrue(confirm.isEnabled, "Both fixture participants have accepted, so the host can finalize")
        tap("cloud.meeting.confirm", in: app)
        let saveToCalendar = element("cloud.meeting.calendar", in: app)
        reveal(saveToCalendar, in: app)
        XCTAssertTrue(saveToCalendar.exists && saveToCalendar.isHittable)
        XCTAssertFalse(confirm.exists, "A finalized invitation must not offer another finalization action")
        // Calendar saving remains an explicit separate action; this test never opens it.
        let details = app.navigationBars["Invitation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.buttons.element(boundBy: 0).tap()
        tap("cloud.invitations.done", in: app)
        waitGone(list)
        waitGone(action)
        XCTAssertTrue(element("home.share", in: app).exists)
    }

    @MainActor private func launch(scenario: String = "standard") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-signed-in-fixtures",
                               "-cloud-fixture-scenario", scenario, "-app.language.preference", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element("home.share", in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func openHub(in app: XCUIApplication) {
        tap("home.share", in: app)
        tap("home.share.calendar", in: app)
        XCTAssertTrue(element("share.calendar.hub.close", in: app).waitForExistence(timeout: 5))
    }

    @MainActor private func chooseRange(_ preset: String, prefix: String, in app: XCUIApplication) {
        tap(prefix, in: app)
        let choice = element(prefix + "." + preset, in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
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

    @MainActor private func setConsent(_ consent: XCUIElement, in app: XCUIApplication) {
        reveal(consent, in: app)
        if consent.value as? String != "1" {
            consent.switches.firstMatch.exists ? consent.switches.firstMatch.tap() : consent.tap()
        }
        XCTAssertEqual(consent.value as? String, "1")
    }

    @MainActor private func assertUploadConfirmation(enabled: Bool, in app: XCUIApplication, message: String = "Upload confirmation must match the current scope consent") {
        let confirm = element("cloud.upload.confirm", in: app)
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.exists && confirm.isHittable, "The confirmation must be reachable after reviewing the complete upload scope")
        XCTAssertEqual(confirm.isEnabled, enabled, message)
    }

    @MainActor private func assertSystemLinkShare(host: String, in app: XCUIApplication) {
        let share = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        let link = share.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "The system sheet must receive the selected calendar's actual link")
        let headerClose = app.buttons["header.closeButton"].firstMatch
        let systemClose = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "关闭"))
            .allElementsBoundByAccessibilityElement.first(where: { $0.isHittable })
        if headerClose.exists && headerClose.isHittable {
            headerClose.tap()
        } else if let systemClose {
            systemClose.tap()
        } else {
            // Native ShareLink can anchor a popover to its button. A title-area tap
            // outside that popover dismisses it without activating another action.
            let frame = share.frame
            let navigation = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: {
                let point = CGPoint(x: $0.frame.midX, y: $0.frame.midY)
                return !$0.frame.isEmpty && !frame.contains(point)
            })
            let outside: CGPoint?
            if let navigation {
                outside = CGPoint(x: navigation.frame.midX, y: navigation.frame.midY)
            } else if frame.minY > app.frame.minY + 80 {
                outside = CGPoint(x: app.frame.midX, y: frame.minY - 24)
            } else { outside = nil }
            if let outside {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: outside.x - app.frame.minX, dy: outside.y - app.frame.minY)).tap()
            }
            // A near-full-screen presentation instead supports pulling down from its top edge.
            if share.exists && share.frame.height >= app.frame.height * 0.75 {
                for _ in 0..<2 where share.exists {
                    let handle = share.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                    let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
                    handle.press(forDuration: 0.05, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.1)
                }
            }
        }
        waitGone(share)
    }

    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier ==[c] %@", id)).firstMatch
    }

    @MainActor private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        if !target.exists { _ = target.waitForExistence(timeout: 5) }
        reveal(target, in: app)
        XCTAssertTrue(target.exists && target.isHittable, "Missing visible control: \(id)")
        XCTAssertTrue(target.isEnabled, "Control should be enabled: \(id)")
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        func ready() -> Bool {
            guard target.exists && target.isHittable else { return false }
            if target.identifier.hasPrefix("home.") || target.identifier.hasSuffix(".close") || target.identifier.hasSuffix(".cancel") { return true }
            if !target.identifier.isEmpty && app.navigationBars.descendants(matching: .any).matching(identifier: target.identifier).firstMatch.exists { return true }
            let top = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.frame.maxY ?? app.frame.minY + 64
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 10 : app.frame.maxY - 40
            return target.frame.midY >= top + 10 && target.frame.midY <= bottom
        }
        if ready() { return }
        for direction: CGFloat in [-1, 1] {
            for _ in 0..<6 {
                if ready() { return }
                let top = app.frame.minY + app.frame.height * 0.25
                let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 20 : app.frame.minY + app.frame.height * 0.78
                let height = max(80, bottom - top)
                let delta: CGFloat
                if target.exists && target.frame.height > 0 { delta = max(-height * 0.5, min(height * 0.5, (top + bottom) / 2 - target.frame.midY)) }
                else { delta = direction * height * 0.5 }
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.6, dy: delta < 0 ? bottom : top))
                let end = start.withOffset(CGVector(dx: 0, dy: delta))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
    }

    @MainActor private func waitGone(_ target: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        waitForExpectations(timeout: 10)
    }

    @MainActor private func waitLabel(_ label: String, on target: XCUIElement) {
        expectation(for: NSPredicate(format: "label CONTAINS %@", label), evaluatedWith: target)
        waitForExpectations(timeout: 10)
    }
}
