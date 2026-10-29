import XCTest

/// Synthetic requests validate the actual snapshot, including recurring exceptions
/// and identifiers reused by different calendars. No deployed service is accessed.
final class MultiSourceSharingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
            attachment.name = "Multiple calendar sharing — " + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testMultipleCalendarsAndOccurrenceRulesPublishOnlyTheReviewedFields() {
        let app = launch("sharing-multi-rules")
        openNewSharing(in: app)
        replaceName("Combined availability", in: app)
        chooseSources(["cloud.fixture.work", "cloud.fixture.personal"], in: app)
        tap("cloud.upload.level", in: app)
        tap("cloud.upload.level.partial", in: app)
        screenshot("Multiple calendar configuration", in: app)
        tap("cloud.sharing.preview", in: app)
        XCTAssertTrue(element("cloud.sharing.events.list", in: app).waitForExistence(timeout: 8))

        openEvent("Work recurring one", in: app)
        tap("cloud.sharing.event.rule.scope", in: app)
        tap("cloud.sharing.event.rule.scope.series", in: app)
        tap("cloud.sharing.event.rule.visibility.opaque", in: app)
        tap("cloud.sharing.event.apply", in: app)

        openEvent("Work recurring one", in: app)
        tap("cloud.sharing.event.rule.visibility.full", in: app)
        screenshot("Occurrence override with inherited series rule", in: app)
        tap("cloud.sharing.event.apply", in: app)
        openEvent("Work excluded appointment", in: app)
        tap("cloud.sharing.event.rule.visibility.excluded", in: app)
        tap("cloud.sharing.event.apply", in: app)

        // Returning to the form still has not created or uploaded a source.
        tap("cloud.sharing.events.done", in: app)
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        tap("cloud.sharing.review", in: app)
        let consent = app.switches["cloud.upload.consent"]
        reveal(consent, in: app)
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(element("cloud.upload.confirm", in: app).isEnabled)
        setConsent(consent, in: app)
        screenshot("Reviewed combined server sharing", in: app)
        tap("cloud.upload.confirm", in: app)

        let share = element("cloud.source.share", in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 12), "The synthetic server rejects any snapshot other than the exact reviewed mixed rules")
        XCTAssertTrue(app.navigationBars["Combined availability"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("cloud.error", in: app).exists)
        tap("cloud.source.level.edit", in: app)
        XCTAssertEqual(app.textFields["cloud.sharing.name"].value as? String, "Combined availability")
        tap("cloud.sharing.preview", in: app)
        openEvent("Work recurring one", in: app)
        XCTAssertTrue(element("cloud.sharing.event.rule.visibility.full", in: app).isSelected)
        tap("cloud.sharing.event.cancel", in: app)
        openEvent("Personal recurring one", in: app)
        XCTAssertTrue(element("cloud.sharing.event.rule.visibility.inherit", in: app).isSelected,
                      "A matching provider item identifier in another calendar must not inherit the Work rule")
        tap("cloud.sharing.event.cancel", in: app)
        tap("cloud.sharing.events.done", in: app)
        tap("cloud.source.level.cancel", in: app)
        tap("cloud.source.share", in: app)
        tap("cloud.link.create", in: app)
        XCTAssertTrue(element("cloud.link.share", in: app).waitForExistence(timeout: 8),
                      "This fixture also refuses a link if cancelling the editor caused a second upload")
    }

    @MainActor func testCancellingMultipleSourceDraftDoesNotCreateOrPublishIt() {
        let app = launch("standard")
        openNewSharing(in: app)
        replaceName("Cancelled combined calendar", in: app)
        chooseSources(["cloud.fixture.work", "cloud.fixture.personal"], in: app)
        tap("cloud.sharing.preview", in: app)
        let appointment = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cloud.sharing.event.")).firstMatch
        reveal(appointment, in: app)
        XCTAssertTrue(appointment.exists)
        appointment.tap()
        tap("cloud.sharing.event.rule.visibility.excluded", in: app)
        tap("cloud.sharing.event.apply", in: app)
        tap("cloud.sharing.events.done", in: app)
        tap("cloud.sharing.review", in: app)
        let consent = app.switches["cloud.upload.consent"]
        reveal(consent, in: app)
        setConsent(consent, in: app)
        reveal(element("cloud.upload.confirm", in: app), in: app)
        XCTAssertTrue(element("cloud.upload.confirm", in: app).isEnabled)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.cancel", in: app)
        tap("cloud.sharing.close", in: app)
        XCTAssertTrue(element("share.calendar.hub.close", in: app).waitForExistence(timeout: 5))
        let published = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "share.calendar.cloud.profile.", "Cancelled combined calendar")).firstMatch
        XCTAssertFalse(published.exists)
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-signed-in-fixtures",
            "-cloud-fixture-scenario", scenario, "-app.language.preference", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element("home.share", in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func openNewSharing(in app: XCUIApplication) {
        tap("home.personal.range", in: app)
        tap("home.personal.range.last3Days", in: app)
        tap("home.share", in: app)
        tap("home.share.calendar", in: app)
        tap("share.calendar.cloud.open", in: app)
        XCTAssertTrue(element("cloud.upload.cancel", in: app).waitForExistence(timeout: 5))
    }

    @MainActor private func replaceName(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["cloud.sharing.name"]
        reveal(field, in: app)
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
        if element("cloud.sharing.keyboard.done", in: app).exists { tap("cloud.sharing.keyboard.done", in: app) }
        else if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        else { field.swipeDown() }
    }

    @MainActor private func chooseSources(_ values: [String], in app: XCUIApplication) {
        tap("cloud.sharing.sources", in: app)
        for id in values { tap("cloud.upload.calendar." + id, in: app) }
        tap("cloud.sharing.sources.done", in: app)
    }

    @MainActor private func openEvent(_ title: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "cloud.sharing.event.", title)).firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.exists && row.isHittable, "Missing local preview: " + title)
        row.tap()
        XCTAssertTrue(element("cloud.sharing.event.apply", in: app).waitForExistence(timeout: 5))
    }

    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier ==[c] %@", id)).firstMatch
    }

    @MainActor private func screenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func setConsent(_ consent: XCUIElement, in app: XCUIApplication) {
        reveal(consent, in: app)
        if consent.value as? String != "1" {
            consent.switches.firstMatch.exists ? consent.switches.firstMatch.tap() : consent.tap()
        }
        XCTAssertEqual(consent.value as? String, "1")
    }

    @MainActor private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        if !target.exists { _ = target.waitForExistence(timeout: 5) }
        reveal(target, in: app)
        XCTAssertTrue(target.exists && target.isHittable, "Missing visible control: " + id)
        XCTAssertTrue(target.isEnabled, "Disabled control: " + id)
        target.tap()
    }

    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        func ready() -> Bool {
            guard target.exists && target.isHittable else { return false }
            if target.identifier.hasSuffix(".done") || target.identifier.hasSuffix(".cancel") || target.identifier.hasSuffix(".back") { return true }
            let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            if app.navigationBars.allElementsBoundByAccessibilityElement.contains(where: { $0.isHittable && $0.frame.contains(center) }) { return true }
            let top = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.frame.maxY ?? app.frame.minY + 64
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 10 : app.frame.maxY - 40
            return target.frame.midY >= top + 5 && target.frame.midY <= bottom
        }
        if ready() { return }
        for direction: CGFloat in [-1, 1] {
            for _ in 0..<5 {
                if ready() { return }
                let top = app.frame.minY + app.frame.height * 0.25
                let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 20 : app.frame.minY + app.frame.height * 0.8
                let height = max(80, bottom - top)
                let delta = target.exists && target.frame.height > 0
                    ? max(-height * 0.5, min(height * 0.5, (top + bottom) / 2 - target.frame.midY)) : direction * height * 0.5
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.6, dy: delta < 0 ? bottom : top))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
            }
        }
    }
}
