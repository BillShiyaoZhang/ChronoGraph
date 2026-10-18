import XCTest

final class SharedHomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreatingSharedCalendarRequiresSeparateDataTransferConsent() throws {
        let app = launchWork()
        tap("home.mode", in: app)
        tap("home.mode.addShared", in: app)
        let name = app.textFields["sharing.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let setup = app.staticTexts["sharing.transfer.setup"]
        reveal(setup, in: app)
        XCTAssertTrue(setup.exists)
        XCTAssertFalse(setup.label.isEmpty)
        XCTAssertFalse(app.buttons["sharing.save"].isEnabled)

        let account = element("sharing.account", in: app)
        revealEarlier(account, in: app)
        account.tap()
        tapLabel("Fixture iCloud", in: app)
        let accountConfirmation = app.switches["sharing.account.confirm"]
        reveal(accountConfirmation, in: app)
        enableSwitch(accountConfirmation)
        revealEarlier(name, in: app)
        name.tap()
        name.typeText("Transfer Consent Test")
        tap("sharing.save", in: app)

        // Identifying the account does not authorize uploading calendar contents.
        assertTransferConsentRequired(confirmID: "sharing.review.confirm", in: app)
        tap("sharing.review.back", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        tap("sharing.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.review.confirm", in: app)
        allowTransfer(confirmID: "sharing.review.confirm", in: app)
        screenshot("10 New shared calendar — separate transfer consent", in: app)
        tap("sharing.review.confirm", in: app)
        waitGone(name)
        tap("share.calendar.close", in: app)
        tap("home.mode", in: app)
        let created = app.buttons["home.shared.profile.Transfer Consent Test"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.tap()
        XCTAssertTrue(app.navigationBars["Transfer Consent Test"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testResumingSharedCalendarRequiresConfirmationAndCancelKeepsItPaused() throws {
        let app = launchWork()
        tap("home.settings", in: app)
        tapLabel("Shared Calendars", in: app)
        tap("sharing.profile.10000000-0000-4000-8000-000000000001", in: app)
        let updates = app.buttons["sharing.updates.toggle"]
        waitLabel("Pause Updates", on: updates)
        updates.tap()
        waitLabel("Resume Updates", on: updates)
        XCTAssertFalse(app.buttons["Update Now"].isEnabled)

        updates.tap()
        let alert = app.alerts["Resume Data Transfer and Updates?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture iCloud")).firstMatch.exists)
        XCTAssertTrue(alert.buttons["sharing.resume.confirm"].exists)
        alert.buttons["Cancel"].tap()
        waitGone(alert)
        waitLabel("Resume Updates", on: updates)
        XCTAssertFalse(app.buttons["Update Now"].isEnabled)
    }

    @MainActor
    func testBrowsingChangesNeverRewriteConfirmedSharingRules() throws {
        let app = launchWork()
        choosePreset("last3Days", prefix: "home.shared.range", in: app)
        choosePreset("last14Days", prefix: "home.shared.range", in: app)
        tap("home.shared.privacy", in: app)
        tap("home.shared.privacy.full", in: app)
        addFamilyToLocalBrowse(in: app)
        XCTAssertTrue(element("home.browse.localOnly", in: app).waitForExistence(timeout: 5))
        let familyTitle = app.staticTexts["Fixture family lunch"].firstMatch
        reveal(familyTitle, in: app)
        XCTAssertTrue(app.staticTexts["Not shared · Source not included"].exists)
        screenshot("01 Local browsing — sharing unchanged", in: app)

        tap("home.share", in: app)
        XCTAssertTrue(app.buttons["home.share.image"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.share.calendar"].exists)
        XCTAssertFalse(app.buttons["home.share.edit"].exists)
        XCTAssertFalse(app.buttons["Edit shared content…"].exists)
        screenshot("07 Share menu — image and subscription only", in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        waitGone(app.buttons["home.share.image"])

        openSharingStatus(in: app)
        XCTAssertTrue(app.buttons["sharing.review.back"].waitForExistence(timeout: 5))
        tap("sharing.review.back", in: app)
        tap("sharing.draft.privacy", in: app)
        let hidden = app.buttons["Hidden"].firstMatch
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(hidden.isSelected)
        hidden.tap()
        tap("sharing.draft.range.customize", in: app)
        XCTAssertTrue(app.textFields["sharing.range.futureDays"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["sharing.range.futureDays"].value as? String, "13")
        XCTAssertEqual(app.textFields["sharing.range.pastDays"].value as? String, "0")
        tap("sharing.range.cancel", in: app)
        let workSource = app.buttons["sharing.draft.source.fixture.source.work"]
        let familySource = app.buttons["sharing.draft.source.fixture.source.family"]
        reveal(workSource, in: app)
        XCTAssertTrue(workSource.isSelected)
        reveal(familySource, in: app)
        XCTAssertTrue(familySource.isSelected)
        XCTAssertFalse(element("sharing.draft.source.fixture.target.work", in: app).exists)
        closeDraft(keeping: false, in: app)
        restoreBrowse(in: app)
        assertHomeTitle("Busy", in: app)
        openCustomRange(prefix: "home.shared.range", in: app)
        assertRollingRange(past: "0", future: "7", in: app)
        tap("sharing.range.cancel", in: app)
    }

    @MainActor
    func testCalendarDraftPublishesOnlyAfterExplicitReviewConfirmation() throws {
        let app = launchWork()
        openEditor(in: app)
        chooseDraftPrivacy("full", label: "Full", in: app)
        choosePreset("last3Days", prefix: "sharing.draft.range", in: app)
        closeDraft(keeping: true, in: app)
        restoreBrowse(in: app)
        assertHomeTitle("Busy", in: app)

        openEditor(in: app)
        tap("sharing.draft.privacy", in: app)
        let full = app.buttons["Full"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertTrue(full.isSelected)
        full.tap()
        tap("sharing.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.review.confirm", in: app)
        allowTransfer(confirmID: "sharing.review.confirm", in: app)

        // Consent alone does not publish, and a new review requires fresh consent.
        tap("sharing.review.back", in: app)
        closeDraft(keeping: true, in: app)
        restoreBrowse(in: app)
        assertHomeTitle("Busy", in: app)
        openEditor(in: app)
        tap("sharing.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.review.confirm", in: app)
        allowTransfer(confirmID: "sharing.review.confirm", in: app)
        let confirm = app.buttons["sharing.review.confirm"]
        reveal(confirm, in: app)
        waitEnabled(confirm)
        screenshot("02 Review confirmed rules before publishing", in: app)
        confirm.tap()
        waitGone(app.textFields["sharing.name"])
        restoreBrowse(in: app)
        assertHomeTitle("Fixture private planning", in: app)

        // A new draft starts from the newly confirmed profile and remains independent.
        openEditor(in: app)
        chooseDraftPrivacy("opaque", label: "Hidden", in: app)
        closeDraft(keeping: false, in: app)
        assertHomeTitle("Fixture private planning", in: app)
    }

    @MainActor
    func testBrowseReviewRequiresAMergeChoiceForExistingDrafts() throws {
        let app = launchWork()
        openEditor(in: app)
        chooseDraftPrivacy("full", label: "Full", in: app)
        closeDraft(keeping: true, in: app)
        choosePreset("last3Days", prefix: "home.shared.range", in: app)

        openSharingStatus(in: app)
        let merge = app.buttons.matching(identifier: "sharing.draft.browse.merge").firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sharing.draft.browse.edit"].exists)
        screenshot("08 Existing draft — explicit merge choice", in: app)
        merge.tap()
        tap("sharing.review.back", in: app)

        // Importing local dates keeps the existing visibility draft, without publishing it.
        tap("sharing.draft.privacy", in: app)
        let full = app.buttons["Full"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertTrue(full.isSelected)
        full.tap()
        tap("sharing.draft.range.customize", in: app)
        assertRollingRange(past: "0", future: "2", in: app)
        tap("sharing.range.cancel", in: app)
        tap("sharing.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.review.confirm", in: app)
        allowTransfer(confirmID: "sharing.review.confirm", in: app)
        let confirm = app.buttons["sharing.review.confirm"]
        reveal(confirm, in: app)
        waitEnabled(confirm)
        screenshot("09 Browse changes — confirm before sharing", in: app)
        confirm.tap()
        waitGone(app.textFields["sharing.name"])
        restoreBrowse(in: app)
        assertHomeTitle("Fixture private planning", in: app)
        openCustomRange(prefix: "home.shared.range", in: app)
        assertRollingRange(past: "0", future: "2", in: app)
        tap("sharing.range.cancel", in: app)
    }

    @MainActor
    func testEventDetailsAreReadOnlyUntilReviewAndConfirm() throws {
        let app = launchWork()
        openFirstEvent(in: app)
        XCTAssertTrue(app.staticTexts["sharing.event.original.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sharing.event.save"].exists)
        XCTAssertFalse(element("sharing.event.visibility.full", in: app).exists)
        waitLabel("Busy", on: app.staticTexts["sharing.event.preview.title"])
        tap("sharing.event.cancel", in: app)
        assertHomeTitle("Busy", in: app)

        openFirstEvent(in: app)
        modifyEventToFull(in: app)
        waitLabel("Fixture private planning", on: app.staticTexts["sharing.event.preview.title"])
        tap("sharing.event.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.event.confirm", in: app)
        tap("sharing.review.back", in: app)
        tap("sharing.event.cancel", in: app)
        tapLabel("Discard Draft", in: app)
        assertHomeTitle("Busy", in: app)

        openFirstEvent(in: app)
        modifyEventToFull(in: app)
        tap("sharing.event.save", in: app)
        assertTransferConsentRequired(confirmID: "sharing.event.confirm", in: app)
        allowTransfer(confirmID: "sharing.event.confirm", in: app)
        let confirm = app.buttons["sharing.event.confirm"]
        reveal(confirm, in: app)
        waitEnabled(confirm)
        screenshot("03 Event visibility — review before publishing", in: app)
        confirm.tap()
        waitGone(app.buttons["sharing.event.cancel"])
        assertHomeTitle("Fixture private planning", in: app)
    }

    @MainActor
    func testImageAndSubscriptionSharingDoNotPublishPendingDrafts() throws {
        let app = launchWork()
        openEditor(in: app)
        chooseDraftPrivacy("full", label: "Full", in: app)
        closeDraft(keeping: true, in: app)
        addFamilyToLocalBrowse(in: app)

        shareAction("Share image", in: app)
        let scopes = app.segmentedControls["share.image.scope"]
        XCTAssertTrue(scopes.waitForExistence(timeout: 5))
        XCTAssertTrue(scopes.buttons.element(boundBy: 0).isSelected)
        XCTAssertTrue(element("share.image.preview", in: app).waitForExistence(timeout: 20))
        screenshot("04 Image preview — confirmed content by default", in: app)
        scopes.buttons.element(boundBy: 1).tap()
        let count = app.staticTexts["share.image.unsharedCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.contains("1"))
        tap("share.image.close", in: app)
        waitGone(scopes)

        shareAction("Send subscription link", in: app)
        XCTAssertTrue(element("share.calendar.draftNotice", in: app).waitForExistence(timeout: 5))
        let textField = app.textFields["share.calendar.link.input"]
        let input = textField.waitForExistence(timeout: 1) ? textField : app.textViews["share.calendar.link.input"]
        reveal(input, in: app)
        input.tap()
        input.typeText("webcal://calendar.example.com/fixture.ics")
        tap("share.calendar.keyboard.done", in: app)
        tap("share.calendar.link.save", in: app)
        let savedURL = app.staticTexts["share.calendar.link.savedURL"]
        waitLabel("webcal://calendar.example.com/fixture.ics", on: savedURL)
        XCTAssertFalse(app.textFields["share.calendar.link.input"].exists)
        XCTAssertFalse(app.textViews["share.calendar.link.input"].exists)
        XCTAssertFalse(element("share.calendar.link.paste", in: app).exists)
        XCTAssertFalse(app.buttons["share.calendar.link.save"].exists)
        let send = app.buttons["share.calendar.link.send"]
        waitEnabled(send)
        tap("share.calendar.close", in: app)
        waitGone(savedURL)

        shareAction("Send subscription link", in: app)
        waitLabel("webcal://calendar.example.com/fixture.ics", on: savedURL)
        XCTAssertFalse(app.textFields["share.calendar.link.input"].exists)
        XCTAssertFalse(app.textViews["share.calendar.link.input"].exists)
        waitEnabled(send)

        tap("share.calendar.link.change", in: app)
        let changedField = app.textFields["share.calendar.link.input"]
        let changedInput = changedField.waitForExistence(timeout: 1) ? changedField : app.textViews["share.calendar.link.input"]
        XCTAssertTrue(changedInput.waitForExistence(timeout: 5))
        XCTAssertFalse(send.exists)
        changedInput.tap()
        changedInput.typeText("changed")
        tap("share.calendar.keyboard.done", in: app)
        tap("share.calendar.link.cancelEdit", in: app)
        waitLabel("webcal://calendar.example.com/fixture.ics", on: savedURL)
        waitEnabled(send)
        XCTAssertTrue(element("share.calendar.draftNotice", in: app).exists)
        send.tap()
        let systemShare = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(systemShare.waitForExistence(timeout: 10))
        let close = app.buttons["header.closeButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        screenshot("05 Subscription link — system share only", in: app)
        close.tap()
        waitGone(systemShare)
        restoreBrowse(in: app)
        assertHomeTitle("Busy", in: app)
    }

    @MainActor
    func testCustomDateRangeUsesTheSameControlsWithoutCrossingBrowseContexts() throws {
        let app = launchWork()
        openCustomRange(prefix: "home.shared.range", in: app)
        replaceNumber("sharing.range.pastDays", with: "1", in: app)
        replaceNumber("sharing.range.futureDays", with: "2", in: app)
        tap("sharing.range.save", in: app)
        waitGone(app.buttons["sharing.range.save"])
        XCTAssertTrue(element("home.browse.localOnly", in: app).waitForExistence(timeout: 5))

        openCustomRange(prefix: "home.shared.range", in: app)
        assertRollingRange(past: "1", future: "2", in: app)
        selectFixedRange(in: app)
        screenshot("06 Custom dates — common rolling and fixed controls", in: app)
        tap("sharing.range.cancel", in: app)

        // The status entry proposes the local range, but cancelling never publishes it.
        openEditor(in: app)
        tap("sharing.draft.range.customize", in: app)
        assertRollingRange(past: "1", future: "2", in: app)
        tap("sharing.range.cancel", in: app)
        closeDraft(keeping: false, in: app)

        tap("home.mode", in: app)
        tap("home.mode.personal", in: app)
        openCustomRange(prefix: "home.personal.range", in: app)
        let mode = app.segmentedControls["sharing.range.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons.element(boundBy: 0).tap()
        replaceNumber("sharing.range.pastDays", with: "3", in: app)
        replaceNumber("sharing.range.futureDays", with: "4", in: app)
        tap("sharing.range.save", in: app)
        waitGone(app.buttons["sharing.range.save"])

        openCustomRange(prefix: "home.personal.range", in: app)
        assertRollingRange(past: "3", future: "4", in: app)
        selectFixedRange(in: app)
        tap("sharing.range.save", in: app)
        waitGone(app.buttons["sharing.range.save"])

        tap("home.mode", in: app)
        tap("home.shared.profile.Work", in: app)
        openCustomRange(prefix: "home.shared.range", in: app)
        assertRollingRange(past: "1", future: "2", in: app)
        tap("sharing.range.cancel", in: app)

        tap("home.mode", in: app)
        tap("home.mode.personal", in: app)
        openCustomRange(prefix: "home.personal.range", in: app)
        XCTAssertTrue(app.segmentedControls["sharing.range.mode"].buttons.element(boundBy: 1).isSelected)
        XCTAssertTrue(element("sharing.range.start", in: app).exists)
        XCTAssertTrue(element("sharing.range.end", in: app).exists)
        tap("sharing.range.cancel", in: app)
    }

    @MainActor
    private func launchWork() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-app.language.preference", "en",
                               "-pref.privacyMode", "partial", "-pref.collapseEmptyDays", "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("home.mode", in: app)
        tap("home.shared.profile.Work", in: app)
        assertHomeTitle("Busy", in: app)
        return app
    }

    @MainActor
    private func choosePreset(_ preset: String, prefix: String, in app: XCUIApplication) {
        if prefix == "sharing.draft.range" {
            centerFormControl(element(prefix, in: app), in: app)
        }
        tap(prefix, in: app)
        let choice = app.buttons.matching(identifier: "\(prefix).\(preset)").firstMatch
        // A menu animates in after its trigger is tapped. Scrolling to search for
        // its items before they appear can immediately dismiss that menu.
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        waitEnabled(choice)
        choice.tap()
    }

    @MainActor
    private func centerFormControl(_ item: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if item.exists {
                let frame = item.frame
                let safeArea = app.frame.insetBy(dx: 0, dy: app.frame.height * 0.2)
                if item.isHittable && safeArea.contains(frame) { return }
                let needsUpwardScroll = frame.midY > safeArea.midY
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: needsUpwardScroll ? 0.7 : 0.4))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: needsUpwardScroll ? 0.45 : 0.65))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                list.swipeUp()
            }
        }
        XCTAssertTrue(item.exists && item.isHittable, file: file, line: line)
        XCTAssertTrue(app.frame.insetBy(dx: 0, dy: app.frame.height * 0.2).contains(item.frame),
                      "Form menus must be fully visible before opening them.", file: file, line: line)
    }

    @MainActor
    private func openCustomRange(prefix: String, in app: XCUIApplication) {
        choosePreset("custom", prefix: prefix, in: app)
        XCTAssertTrue(app.segmentedControls["sharing.range.mode"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertRollingRange(past: String, future: String, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let mode = app.segmentedControls["sharing.range.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(mode.buttons.element(boundBy: 0).isSelected, file: file, line: line)
        waitValue(past, on: app.textFields["sharing.range.pastDays"], file: file, line: line)
        waitValue(future, on: app.textFields["sharing.range.futureDays"], file: file, line: line)
    }

    @MainActor
    private func selectFixedRange(in app: XCUIApplication) {
        let mode = app.segmentedControls["sharing.range.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(element("sharing.range.start", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("sharing.range.end", in: app).exists)
        XCTAssertFalse(app.textFields["sharing.range.futureDays"].exists)
    }

    @MainActor
    private func replaceNumber(_ id: String, with value: String, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        reveal(field, in: app, file: file, line: line)
        // Select the entire numeric token; deleting at an unknown caret can prepend digits.
        field.doubleTap()
        let menuSelectAll = app.menuItems["Select All"].firstMatch
        let buttonSelectAll = app.buttons["Select All"].firstMatch
        if menuSelectAll.exists { menuSelectAll.tap() }
        else if buttonSelectAll.exists { buttonSelectAll.tap() }
        field.typeText(value)
        waitValue(value, on: field, file: file, line: line)
    }

    @MainActor
    private func restoreBrowse(in app: XCUIApplication) {
        tap("home.mode", in: app)
        tap("home.browse.restore", in: app)
    }

    @MainActor
    private func addFamilyToLocalBrowse(in app: XCUIApplication) {
        tap("home.settings", in: app)
        tap("home.shared.sources", in: app)
        let family = app.buttons["browse.sources.fixture.source.family"]
        reveal(family, in: app)
        if !family.isSelected { family.tap() }
        XCTAssertTrue(family.isSelected)
        XCTAssertFalse(element("browse.sources.fixture.target.work", in: app).exists)
        XCTAssertFalse(element("browse.sources.fixture.target.family", in: app).exists)
        let back = app.navigationBars["Calendars"].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
        tap("home.settings.done", in: app)
    }

    @MainActor
    private func shareAction(_ title: String, in app: XCUIApplication) {
        tap("home.share", in: app)
        tap(title == "Share image" ? "home.share.image" : "home.share.calendar", in: app)
    }

    @MainActor
    private func openEditor(in app: XCUIApplication) {
        openSharingStatus(in: app)
        let back = app.buttons["sharing.review.back"]
        if back.waitForExistence(timeout: 1) { tap("sharing.review.back", in: app) }
        XCTAssertTrue(app.textFields["sharing.name"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openSharingStatus(in app: XCUIApplication) {
        let status = app.buttons["home.sharing.status"]
        for _ in 0..<8 {
            if status.exists && status.isHittable {
                status.tap()
                return
            }
            app.scrollViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isHittable)
        status.tap()
    }

    @MainActor
    private func chooseDraftPrivacy(_ value: String, label: String, in app: XCUIApplication) {
        tap("sharing.draft.privacy", in: app)
        let byID = element("sharing.draft.privacy.\(value)", in: app)
        let choice = byID.waitForExistence(timeout: 1) ? byID : app.buttons[label].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor
    private func closeDraft(keeping: Bool, in app: XCUIApplication) {
        tap("sharing.draft.cancel", in: app)
        tapLabel(keeping ? "Keep Draft" : "Discard Draft", in: app)
        waitGone(app.textFields["sharing.name"])
    }

    @MainActor
    private func openFirstEvent(in app: XCUIApplication) {
        let title = app.staticTexts["home.shared.event.title"].firstMatch
        reveal(title, in: app)
        title.tap()
    }

    @MainActor
    private func modifyEventToFull(in app: XCUIApplication) {
        tap("sharing.event.modify", in: app)
        let byID = element("sharing.event.visibility.full", in: app)
        let full = byID.waitForExistence(timeout: 1) ? byID : app.buttons["Full"].firstMatch
        reveal(full, in: app)
        full.tap()
    }

    @MainActor
    private func assertHomeTitle(_ title: String, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let item = app.staticTexts["home.shared.event.title"].firstMatch
        waitLabel(title, on: item, file: file, line: line)
    }

    @MainActor
    private func assertTransferConsentRequired(confirmID: String, in app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        for id in ["sharing.transfer.destination", "sharing.transfer.fields", "sharing.transfer.ongoing"] {
            let disclosure = app.staticTexts.matching(identifier: id).firstMatch
            reveal(disclosure, in: app, file: file, line: line)
            XCTAssertTrue(disclosure.exists, file: file, line: line)
            XCTAssertFalse(disclosure.label.isEmpty, file: file, line: line)
        }
        let consent = app.switches.matching(identifier: "sharing.transfer.confirm").firstMatch
        reveal(consent, in: app, file: file, line: line)
        waitValue("0", on: consent, file: file, line: line)
        let confirm = app.buttons[confirmID]
        reveal(confirm, in: app, file: file, line: line)
        XCTAssertFalse(confirm.isEnabled, "Publishing requires explicit data-transfer consent.", file: file, line: line)
    }

    @MainActor
    private func allowTransfer(confirmID: String, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let consent = app.switches.matching(identifier: "sharing.transfer.confirm").firstMatch
        // The confirmation button may be below the switch on smaller screens.
        revealEarlier(consent, in: app, file: file, line: line)
        enableSwitch(consent, file: file, line: line)
        let confirm = app.buttons[confirmID]
        reveal(confirm, in: app, file: file, line: line)
        waitEnabled(confirm)
    }

    @MainActor
    private func enableSwitch(_ item: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        waitValue("0", on: item, file: file, line: line)
        XCTAssertTrue(item.isHittable, file: file, line: line)
        // SwiftUI can expose the full labeled row as the switch's AX frame.
        // Hit the trailing control rather than the center of the label.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitValue("1", on: item, file: file, line: line)
    }

    @MainActor
    private func revealEarlier(_ item: XCUIElement, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if item.exists && item.isHittable { return }
            app.collectionViews.firstMatch.swipeDown()
        }
        reveal(item, in: app, file: file, line: line)
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(identifier: id).firstMatch
        return button.exists ? button : app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func tap(_ id: String, in app: XCUIApplication) {
        let item = element(id, in: app)
        // Form/List rows may not exist in the accessibility tree until scrolled onscreen.
        reveal(item, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        waitEnabled(item)
        item.tap()
    }

    @MainActor
    private func tapLabel(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    private func reveal(_ item: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if item.exists && item.isHittable { return }
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(item.isHittable, file: file, line: line)
    }

    @MainActor
    private func waitValue(_ value: String, on item: XCUIElement,
                           file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", value), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func waitLabel(_ label: String, on item: XCUIElement,
                           file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    private func waitEnabled(_ item: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    @MainActor
    private func waitGone(_ item: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    @MainActor
    private func screenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
