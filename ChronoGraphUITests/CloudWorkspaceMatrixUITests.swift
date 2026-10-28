import XCTest
import UIKit

/// Focused presentation journeys; functional state-machine coverage stays in the portrait suite.
/// The runner can override CHRONOGRAPH_MATRIX_LANGUAGE, CHRONOGRAPH_MATRIX_LOCALE,
/// CHRONOGRAPH_MATRIX_ORIENTATION (portrait/landscapeLeft/landscapeRight),
/// CHRONOGRAPH_MATRIX_STYLE (Light/Dark), and CHRONOGRAPH_MATRIX_TEXT_SIZE.
/// Run the first journey on the smallest supported Simulator destination.
final class CloudWorkspaceMatrixUITests: XCTestCase {
    private let me = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let hostMeeting = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let guestMeeting = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            screenshot("Cloud matrix failure — " + name, XCUIApplication())
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testCompactLargeTextSourceConsentAndAccountDeletionStayReachable() {
        let app = launch(largeText: true)
        tap("cloud.source.add", in: app)
        tap("cloud.upload.calendar.cloud.fixture.work", in: app)
        let privacy = element("cloud.upload.independentRules", in: app)
        reveal(privacy, in: app)
        XCTAssertTrue(privacy.isHittable)
        screenshot("Cloud compact AX XXXL — upload scope explanation", app)
        let consent = app.switches["cloud.upload.consent"]
        reveal(consent, in: app)
        XCTAssertEqual(consent.value as? String, "0")
        setOn(consent, in: app)
        let confirm = element("cloud.upload.confirm", in: app)
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(confirm.isHittable)
        screenshot("Cloud compact AX XXXL — explicit consent and upload reachable", app)
        app.navigationBars.buttons["取消"].firstMatch.tap()
        tap("cloud.account.delete", in: app)
        let deletion = element("cloud.account.delete.confirm", in: app)
        if !app.navigationBars["删除云端账号？"].waitForExistence(timeout: 2) {
            XCTAssertTrue(deletion.waitForExistence(timeout: 5))
            XCTAssertTrue(deletion.isHittable)
        }
        screenshot("Cloud compact AX XXXL — full account deletion disclosure", app)
        verifyDeletionDisclosureTail(above: deletion, in: app)
        dismissDialog(cancel: "cloud.account.delete.cancel", confirming: "cloud.account.delete.confirm", in: app)
        let accountControl = element("cloud.account.delete", in: app)
        XCTAssertTrue(accountControl.exists && accountControl.isHittable)
        XCTAssertFalse(app.textFields["cloud.server"].exists)
    }

    @MainActor func testDarkGuestResponseAndStatusRemainReadable() {
        let app = launch("guest-proposal", style: "Dark")
        tap("cloud.meeting.open." + guestMeeting, in: app)
        tap("cloud.meeting.accept", in: app)
        waitLabel("已同意", id: "cloud.meeting.response." + me, in: app)
        XCTAssertFalse(app.buttons["cloud.meeting.confirm"].exists)
        screenshot("Cloud dark — accepted guest response and version", app)
        tap("cloud.meeting.decline", in: app)
        waitLabel("不方便", id: "cloud.meeting.response." + me, in: app)
        screenshot("Cloud dark — declined guest response", app)
    }

    @MainActor func testLandscapeFindCandidateAndFinalizeMeetingStayReachable() {
        let app = launch("host-proposal", orientation: .landscapeLeft)
        tap("cloud.find.open", in: app)
        XCTAssertTrue(app.navigationBars["找时间"].waitForExistence(timeout: 5))
        let participant = app.switches["cloud.find.person." + peer]
        reveal(participant, in: app)
        setOn(participant, in: app)
        tap("cloud.find.search", in: app)
        let candidate = element("cloud.find.candidate", in: app)
        _ = candidate.waitForExistence(timeout: 1)
        reveal(candidate, in: app)
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        screenshot("Cloud landscape — common candidate and timezone", app)
        candidate.tap()
        XCTAssertTrue(element("cloud.find.propose", in: app).waitForExistence(timeout: 5))
        screenshot("Cloud landscape — proposal confirmation", app)
        dismissDialog(cancel: "cloud.find.propose.cancel", confirming: "cloud.find.propose", in: app)
        app.navigationBars.buttons["完成"].firstMatch.tap()
        tap("cloud.meeting.open." + hostMeeting, in: app)
        let start = element("cloud.meeting.start", in: app)
        reveal(start, in: app)
        XCTAssertFalse(start.label.isEmpty)
        tap("cloud.meeting.confirm", in: app)
        let calendar = element("cloud.meeting.calendar", in: app)
        reveal(calendar, in: app)
        XCTAssertTrue(calendar.isHittable)
        screenshot("Cloud landscape — finalized meeting with explicit calendar action", app)
    }

    @MainActor private func launch(_ scenario: String = "standard", orientation: UIDeviceOrientation = .portrait, style: String = "Light", largeText: Bool = false) -> XCUIApplication {
        let options = ProcessInfo.processInfo.environment
        let language = options["CHRONOGRAPH_MATRIX_LANGUAGE"] ?? "zh-Hans"
        let locale = options["CHRONOGRAPH_MATRIX_LOCALE"] ?? (language.hasPrefix("zh") ? "zh_CN" : "en_US")
        let requestedOrientation: UIDeviceOrientation
        switch options["CHRONOGRAPH_MATRIX_ORIENTATION"] {
        case "portrait": requestedOrientation = .portrait
        case "landscapeLeft": requestedOrientation = .landscapeLeft
        case "landscapeRight": requestedOrientation = .landscapeRight
        default: requestedOrientation = orientation
        }
        XCUIDevice.shared.orientation = requestedOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-signed-in-fixtures", "-cloud-fixture-scenario", scenario,
            "-app.language.preference", language, "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            "-AppleInterfaceStyle", options["CHRONOGRAPH_MATRIX_STYLE"] ?? style]
        if let category = options["CHRONOGRAPH_MATRIX_TEXT_SIZE"] ?? (largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : nil) {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launch()
        tap("home.settings", in: app)
        tap("home.cloudWorkspace", in: app)
        let nickname = app.textFields["cloud.nickname"]
        _ = nickname.waitForExistence(timeout: 1)
        reveal(nickname, in: app)
        XCTAssertTrue(nickname.waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "identifier ==[c] %@", id)).firstMatch }
    @MainActor private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        _ = target.waitForExistence(timeout: 1)
        reveal(target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing control: \(id)")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: target)
        waitForExpectations(timeout: 5)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 20) {
        func viewport() -> CGRect {
            let navigation = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable })?.frame ?? app.frame
            let containers = app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            // The active Form can be a centered iPad sheet. Full-window bounds include
            // dismissible space outside it, and underlying full-screen scroll views.
            return containers.last(where: { container in
                let frame = container.frame
                return frame.width > 100 && frame.height > 100 && frame.intersects(app.frame)
                    && frame.width <= navigation.width + 4
                    && abs(frame.midX - navigation.midX) < navigation.width * 0.25
            })?.frame ?? app.frame
        }
        func band() -> (CGFloat, CGFloat) {
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable })?.frame.maxY ?? (app.frame.minY + 64)
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 40
            let visible = viewport()
            let top = max(navigationBottom + 12, visible.minY + 12)
            let bottom = min(keyboardTop, visible.maxY - 16)
            return (top, max(top + 60, bottom))
        }
        func ready() -> Bool {
            guard target.exists && target.isHittable else { return false }
            let id = target.identifier
            let overlayActions = ["cloud.account.delete.confirm", "cloud.source.delete.confirm", "cloud.find.propose"]
            let scrollableDeletion = id == "cloud.account.delete.confirm" && app.navigationBars["删除云端账号？"].exists
            if id == "home.settings" || (overlayActions.contains(id) && !scrollableDeletion) { return true }
            if !id.isEmpty && app.navigationBars.descendants(matching: .any).matching(identifier: id).firstMatch.exists { return true }
            let (top, bottom) = band()
            if scrollableDeletion {
                // Check actual clipping bounds. The generic gesture band reserves
                // extra padding that the SE's bottommost row cannot scroll past.
                let clipBottom = min(viewport().maxY, app.frame.maxY,
                                     app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY)
                return target.frame.minY >= top - 1 && target.frame.maxY <= clipBottom + 1
            }
            return target.frame.midY >= top && target.frame.midY <= bottom
        }
        func drag(_ delta: CGFloat) {
            let (top, bottom) = band()
            let height = bottom - top
            let bounded = max(-height * 0.45, min(height * 0.45, delta))
            let startY = top + height * (bounded > 0 ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let dragX = viewport().midX - app.frame.minX
            let start = origin.withOffset(CGVector(dx: dragX, dy: startY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: dragX, dy: startY + bounded - app.frame.minY))
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
    @MainActor private func waitLabel(_ text: String, id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        _ = target.waitForExistence(timeout: 2)
        reveal(target, in: app)
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: target)
        waitForExpectations(timeout: 8)
    }
    @MainActor private func setOn(_ control: XCUIElement, in app: XCUIApplication) {
        reveal(control, in: app)
        if control.value as? String != "1" {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            if control.value as? String != "1" {
                expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: control)
                waitForExpectations(timeout: 5)
            }
        }
        XCTAssertEqual(control.value as? String, "1")
    }
    @MainActor private func dismissDialog(cancel: String, confirming: String, in app: XCUIApplication) {
        let destructiveControl = element(confirming, in: app)
        XCTAssertTrue(destructiveControl.exists, "Only dismiss a confirmed, currently presented dialog")
        let cancelControl = element(cancel, in: app)
        if cancelControl.exists && cancelControl.isHittable { cancelControl.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: destructiveControl)
        waitForExpectations(timeout: 8)
    }
    @MainActor private func verifyDeletionDisclosureTail(above destructiveControl: XCUIElement, in app: XCUIApplication) {
        let reviewNavigation = app.navigationBars["删除云端账号？"]
        if reviewNavigation.exists {
            reveal(destructiveControl, in: app)
            XCTAssertTrue(destructiveControl.exists && destructiveControl.isHittable)
            let message = element("cloud.account.delete.disclosure", in: app)
            XCTAssertTrue(message.exists && message.isHittable)
            XCTAssertTrue(message.label.contains("Apple 登录授权请单独管理"))
            let navigation = reviewNavigation.frame
            let form = app.collectionViews.allElementsBoundByIndex.last(where: {
                abs($0.frame.midX - navigation.midX) < 4 && $0.frame.width <= navigation.width + 4
            })?.frame ?? app.frame
            let visibleTop = max(navigation.maxY + 12, form.minY + 12)
            let visibleBottom = min(destructiveControl.frame.minY, form.maxY - 16)
            let footerBottom = min(form.maxY, app.frame.maxY)
            let geometry = XCTAttachment(string: "Accessible review message: \(message.frame); footer: \(destructiveControl.frame); Form: \(form); visible tail band: \(visibleTop)...\(visibleBottom)")
            geometry.name = "Cloud accessible deletion review geometry"; geometry.lifetime = .keepAlways; add(geometry)
            XCTAssertGreaterThanOrEqual(destructiveControl.frame.minY, visibleTop - 1)
            XCTAssertLessThanOrEqual(destructiveControl.frame.maxY, footerBottom + 1, "The entire deletion button must fit in the unobscured review viewport")
            XCTAssertGreaterThan(message.frame.maxY, visibleTop)
            XCTAssertLessThanOrEqual(message.frame.maxY, visibleBottom)
            screenshot("Cloud compact AX XXXL — deletion review final lines and action visible", app)
            return
        }
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Apple 登录授权请单独管理")).firstMatch
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", "删除云端账号？")).firstMatch
        XCTAssertTrue(message.exists && title.exists && destructiveControl.exists)
        let footer = destructiveControl.frame
        let bodyTop = max(app.frame.minY + 40, title.frame.maxY + 12)
        let bodyBottom = footer.minY - 16
        let visibleBottom = footer.minY
        let geometry = XCTAttachment(string: "Disclosure title frame: \(title.frame); message initial frame: \(message.frame); gesture body: \(bodyTop)...\(bodyBottom); destructive footer: \(footer)")
        geometry.name = "Cloud accessibility disclosure geometry"; geometry.lifetime = .keepAlways; add(geometry)
        XCTAssertGreaterThan(bodyBottom - bodyTop, 60, "The native disclosure needs a touchable body above its destructive footer")
        let startY = bodyBottom - 12
        let endY = bodyTop + 12
        let distance = startY - endY
        var previousBottom = message.frame.maxY
        let maximumDrags = min(24, max(1, Int((max(0, previousBottom - bodyBottom) / distance).rounded(.up)) + 3))
        for _ in 0..<maximumDrags {
            if message.frame.maxY <= visibleBottom { break }
            XCTAssertTrue(message.isHittable, "The native disclosure body must remain touchable while scrolling")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: footer.midX - app.frame.minX, dy: startY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: footer.midX - app.frame.minX, dy: endY - app.frame.minY))
            // Both points are in the message body, strictly above the destructive button.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            let nextBottom = message.frame.maxY
            XCTAssertLessThan(nextBottom, previousBottom - 1, "The clipped disclosure did not scroll toward its final line")
            previousBottom = nextBottom
        }
        XCTAssertLessThanOrEqual(message.frame.maxY, visibleBottom, "The complete deletion disclosure must be reachable above the fixed destructive footer")
        screenshot("Cloud compact AX XXXL — deletion disclosure final lines visible", app)
    }
    @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
