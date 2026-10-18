import XCTest

final class SharedHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSharedHomeVisibilityAndRangeStayWithTheirProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-app.language.preference", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        selectProfile("Work", in: app)

        let title = app.staticTexts["home.shared.event.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertNotEqual(title.label, "Fixture private planning")
        XCTAssertFalse(app.staticTexts["Fixture private planning"].exists,
                       "The shared list must render the sanitized title.")
        reveal(title, in: app)
        attachScreenshot("01 Shared home — opaque visibility", from: app)
        title.tap()

        let original = app.staticTexts["sharing.event.original.title"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(original.label, "Fixture private planning")
        let fullByIdentifier = element("sharing.event.visibility.full", in: app)
        // Native inline Picker rows may replace child identifiers when bridging to UIKit.
        // The fixture run forces English, so its exposed system button label is a stable fallback.
        let full = fullByIdentifier.waitForExistence(timeout: 2) ? fullByIdentifier : app.buttons["Full"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        full.tap()
        let publishedPreview = app.staticTexts["sharing.event.preview.title"]
        waitForLabel("Fixture private planning", on: publishedPreview)
        for _ in 0..<3 where !publishedPreview.isHittable { app.swipeUp() }
        XCTAssertTrue(publishedPreview.isHittable)
        attachScreenshot("02 Event detail — Full live preview", from: app)
        let visibilitySave = app.buttons["sharing.event.save"]
        waitUntilEnabled(visibilitySave)
        visibilitySave.tap()
        waitUntilGone(visibilitySave)
        waitForLabel("Fixture private planning", on: title)

        // A nonrecurring event's saved override must not masquerade as a series default.
        // Choosing inheritance previews Work's opaque policy; cancelling keeps the saved Full override.
        title.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let inheritByIdentifier = element("sharing.event.visibility.inherit", in: app)
        let inherit = inheritByIdentifier.waitForExistence(timeout: 2)
            ? inheritByIdentifier : app.buttons["Use inherited setting"].firstMatch
        XCTAssertTrue(inherit.waitForExistence(timeout: 5))
        inherit.tap()
        waitForLabel("Busy", on: publishedPreview)
        let cancelVisibility = app.buttons["sharing.event.cancel"]
        waitUntilEnabled(cancelVisibility)
        cancelVisibility.tap()
        waitUntilGone(cancelVisibility)
        waitForLabel("Fixture private planning", on: title)

        // Capture Family's fixed dates before changing Work's rolling window.
        selectProfile("Family", in: app)
        waitForLabel("Fixture family lunch", on: title)
        openRange(in: app)
        let fixedStart = app.datePickers["sharing.range.start"]
        let fixedEnd = app.datePickers["sharing.range.end"]
        XCTAssertTrue(fixedStart.waitForExistence(timeout: 5))
        XCTAssertTrue(fixedEnd.exists)
        let originalFamilyStart = String(describing: fixedStart.value)
        let originalFamilyEnd = String(describing: fixedEnd.value)
        app.buttons["sharing.range.cancel"].tap()
        waitUntilGone(app.buttons["sharing.range.cancel"])

        selectProfile("Work", in: app)
        waitForLabel("Fixture private planning", on: title)
        openRange(in: app)
        let futureDays = app.textFields["sharing.range.futureDays"]
        XCTAssertTrue(futureDays.waitForExistence(timeout: 5))
        XCTAssertEqual(futureDays.value as? String, "7")
        replaceText(in: futureDays, with: "0", app: app)
        attachScreenshot("03 Work range — zero future days before saving", from: app)
        let rangeSave = app.buttons["sharing.range.save"]
        waitUntilEnabled(rangeSave)
        rangeSave.tap()
        waitUntilGone(rangeSave)
        waitUntilGone(title)

        selectProfile("Family", in: app)
        waitForLabel("Fixture family lunch", on: title)
        openRange(in: app)
        XCTAssertTrue(fixedStart.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: fixedStart.value), originalFamilyStart)
        XCTAssertEqual(String(describing: fixedEnd.value), originalFamilyEnd)
        XCTAssertFalse(futureDays.exists, "Family must retain its fixed range.")
        app.buttons["sharing.range.cancel"].tap()
        waitUntilGone(app.buttons["sharing.range.cancel"])

        selectProfile("Work", in: app)
        waitUntilGone(title)
        openRange(in: app)
        XCTAssertTrue(futureDays.waitForExistence(timeout: 5))
        XCTAssertEqual(futureDays.value as? String, "0")
    }

    @MainActor
    func testSharedSourcesSaveOnlyToCurrentProfileAndExcludeManagedCalendars() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-app.language.preference", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        selectProfile("Work", in: app)

        openSources(in: app)
        let workSource = app.buttons["sharing.sources.source.fixture.source.work"]
        let familySource = app.buttons["sharing.sources.source.fixture.source.family"]
        XCTAssertTrue(workSource.waitForExistence(timeout: 5))
        XCTAssertTrue(workSource.isSelected)
        XCTAssertFalse(familySource.isSelected)
        assertManagedSourcesAreAbsent(in: app)
        familySource.tap()
        XCTAssertTrue(familySource.isSelected)
        saveSources(in: app)

        let titles = app.staticTexts.matching(identifier: "home.shared.event.title")
        XCTAssertTrue(titles.element(boundBy: 1).waitForExistence(timeout: 10))
        XCTAssertEqual(titles.count, 2)
        XCTAssertFalse(app.staticTexts["Fixture family lunch"].exists,
                       "Work's opaque policy must also apply to its newly selected source.")
        reveal(titles.element(boundBy: 1), in: app)
        titles.element(boundBy: 1).tap()
        let original = app.staticTexts["sharing.event.original.title"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(original.label, "Fixture family lunch")
        let cancelDetail = app.buttons["sharing.event.cancel"]
        cancelDetail.tap()
        waitUntilGone(cancelDetail)

        openSources(in: app)
        XCTAssertTrue(workSource.waitForExistence(timeout: 5))
        XCTAssertTrue(workSource.isSelected)
        XCTAssertTrue(familySource.isSelected)
        saveSources(in: app)

        selectProfile("Family", in: app)
        waitForLabel("Fixture family lunch", on: titles.firstMatch)
        openSources(in: app)
        XCTAssertTrue(workSource.waitForExistence(timeout: 5))
        XCTAssertFalse(workSource.isSelected, "Saving Work's sources must not change Family's sources.")
        XCTAssertTrue(familySource.isSelected)
        assertManagedSourcesAreAbsent(in: app)
        saveSources(in: app)
    }

    @MainActor
    func testToolbarViewSwitchKeepsPersonalPrivacyAndSharedOverrideIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-app.language.preference", "en",
                               "-pref.privacyMode", "partial", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertEqual(app.segmentedControls.count, 0)
        selectProfile("Work", in: app)

        let mode = app.buttons["home.mode"]
        let privacy = app.buttons["home.shared.privacy"]
        let range = app.buttons["home.shared.range"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        XCTAssertTrue(range.exists)
        XCTAssertTrue(mode.isHittable && privacy.isHittable && range.isHittable)
        XCTAssertEqual(mode.frame.midY, privacy.frame.midY, accuracy: 12)
        XCTAssertEqual(mode.frame.midY, range.frame.midY, accuracy: 12,
                       "View, visibility, and date controls belong to the same toolbar row.")

        let title = app.staticTexts["home.shared.event.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        reveal(title, in: app)
        title.tap()
        let fullByIdentifier = element("sharing.event.visibility.full", in: app)
        let full = fullByIdentifier.waitForExistence(timeout: 2) ? fullByIdentifier : app.buttons["Full"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        full.tap()
        let save = app.buttons["sharing.event.save"]
        waitUntilEnabled(save)
        save.tap()
        waitUntilGone(save)
        waitForLabel("Fixture private planning", on: title)

        setSharedPrivacy("full", in: app)
        openViewMenu(in: app)
        let personal = element("home.mode.personal", in: app)
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        let personalPrivacy = app.buttons["home.personal.privacy"]
        XCTAssertTrue(personalPrivacy.waitForExistence(timeout: 5))
        personalPrivacy.tap()
        let partial = element("home.personal.privacy.partial", in: app)
        XCTAssertTrue(partial.waitForExistence(timeout: 5))
        XCTAssertTrue(partial.isSelected,
                      "Changing a shared calendar's default visibility must preserve personal visibility.")
        partial.tap()

        selectProfile("Work", in: app)
        setSharedPrivacy("opaque", in: app)
        waitForLabel("Fixture private planning", on: title)
        reveal(title, in: app)
        title.tap()
        let selectedFullByID = element("sharing.event.visibility.full", in: app)
        let selectedFull = selectedFullByID.waitForExistence(timeout: 2)
            ? selectedFullByID : app.buttons["Full"].firstMatch
        XCTAssertTrue(selectedFull.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedFull.isSelected, "An event override must outrank the new opaque calendar default.")
        let fullLocation = app.staticTexts["Fixture private room"].firstMatch
        XCTAssertTrue(fullLocation.waitForExistence(timeout: 5))
        XCTAssertEqual(fullLocation.label, "Fixture private room")
    }

    @MainActor
    func testDateToolbarPresetsAndCustomSaveOnlyToSharedProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-app.language.preference", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openViewMenu(in: app)
        let personal = element("home.mode.personal", in: app)
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        let personalRange = app.buttons["home.personal.range"]
        XCTAssertTrue(personalRange.waitForExistence(timeout: 5))
        personalRange.tap()
        let personalWeek = element("home.personal.range.last7Days", in: app)
        XCTAssertTrue(personalWeek.waitForExistence(timeout: 5))
        personalWeek.tap()

        selectProfile("Work", in: app)
        let sharedRange = app.buttons["home.shared.range"]
        XCTAssertTrue(sharedRange.waitForExistence(timeout: 5))
        waitUntilEnabled(sharedRange)
        sharedRange.tap()
        let threeDays = element("home.shared.range.last3Days", in: app)
        XCTAssertTrue(threeDays.waitForExistence(timeout: 5))
        threeDays.tap()
        openRange(in: app)
        let futureDays = app.textFields["sharing.range.futureDays"]
        let pastDays = app.textFields["sharing.range.pastDays"]
        XCTAssertTrue(futureDays.waitForExistence(timeout: 5))
        XCTAssertEqual(futureDays.value as? String, "2")
        XCTAssertEqual(pastDays.value as? String, "0")
        let cancelRange = app.buttons["sharing.range.cancel"]
        cancelRange.tap()
        waitUntilGone(cancelRange)

        waitUntilEnabled(sharedRange)
        sharedRange.tap()
        let custom = element("home.shared.range.custom", in: app)
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.tap()
        let apply = app.buttons["Apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        waitUntilEnabled(apply)
        apply.tap()
        waitUntilGone(apply)
        openRange(in: app)
        XCTAssertTrue(app.datePickers["sharing.range.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["sharing.range.end"].exists)
        XCTAssertFalse(futureDays.exists, "Applying the common custom date sheet must save a fixed shared range.")
        cancelRange.tap()
        waitUntilGone(cancelRange)

        openViewMenu(in: app)
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        XCTAssertTrue(personalRange.waitForExistence(timeout: 5))
        personalRange.tap()
        XCTAssertTrue(personalWeek.waitForExistence(timeout: 5))
        XCTAssertTrue(personalWeek.isSelected, "Shared presets and custom dates must preserve the personal one-week range.")
    }

    @MainActor
    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openSources(in app: XCUIApplication) {
        let settingsByID = app.buttons["home.settings"]
        let settings = settingsByID.exists ? settingsByID : app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let button = app.buttons["home.shared.sources"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        waitUntilEnabled(button)
        button.tap()
    }

    @MainActor
    private func saveSources(in app: XCUIApplication) {
        let save = app.buttons["sharing.sources.save"]
        waitUntilEnabled(save)
        save.tap()
        waitUntilGone(save)
        let doneByID = app.buttons["home.settings.done"]
        let done = doneByID.exists ? doneByID : app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        waitUntilGone(done)
    }

    @MainActor
    private func assertManagedSourcesAreAbsent(in app: XCUIApplication) {
        XCTAssertFalse(element("sharing.sources.source.fixture.target.work", in: app).exists)
        XCTAssertFalse(element("sharing.sources.source.fixture.target.family", in: app).exists)
    }

    @MainActor
    private func selectProfile(_ name: String, in app: XCUIApplication) {
        openViewMenu(in: app)
        let choice = element("home.shared.profile.\(name)", in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor
    private func openRange(in app: XCUIApplication) {
        let button = app.buttons["home.shared.range"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        waitUntilEnabled(button)
        button.tap()
        let edit = element("home.shared.range.edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
    }

    @MainActor
    private func openViewMenu(in app: XCUIApplication) {
        let menu = app.buttons["home.mode"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        waitUntilEnabled(menu)
        menu.tap()
    }

    @MainActor
    private func setSharedPrivacy(_ value: String, in app: XCUIApplication) {
        let menu = app.buttons["home.shared.privacy"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        waitUntilEnabled(menu)
        menu.tap()
        let choice = element("home.shared.privacy.\(value)", in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        // Native word selection avoids guessing where a trailing-aligned numeric caret landed.
        field.doubleTap()
        let selectAllMenuItem = app.menuItems["Select All"]
        if selectAllMenuItem.waitForExistence(timeout: 1) {
            selectAllMenuItem.tap()
        } else {
            let selectAllButton = app.buttons["Select All"]
            if selectAllButton.exists { selectAllButton.tap() }
        }
        field.typeText(text)
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 5), .completed,
                       "The numeric field must contain the replacement before saving.", file: file, line: line)
    }

    @MainActor
    private func waitForLabel(_ expected: String, on element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }
}
