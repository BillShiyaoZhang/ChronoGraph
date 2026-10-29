import XCTest
import UIKit

#if DEBUG
/// Synthetic HTTPS transport and memory Keychain, compiled only into a Debug fixture run.
/// CHRONOGRAPH_AUTH_TEXT_SIZE and CHRONOGRAPH_AUTH_STYLE exercise this same journey on iPad/large text.
final class CloudPasswordAuthenticationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { screenshot("Password authentication failure", XCUIApplication()) }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testInviteRegistrationCanRetryAndDoesNotEnableCalendarUpload() {
        let app = launch()
        tap("cloud.auth.showRegister", in: app)
        fill("cloud.auth.username", "New.Friend", in: app)
        fill("cloud.auth.password", "RegistrationPass123!", secure: true, in: app)
        fill("cloud.auth.confirmation", "RegistrationPass123!", secure: true, in: app)
        fill("cloud.auth.invite", String(repeating: "I", count: 20), in: app)
        fill("cloud.auth.displayName", "新朋友", in: app)
        tap("cloud.password.register", in: app)
        waitLabel("邀请码无效", id: "cloud.error", in: app)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        fill("cloud.auth.invite", "fixture-invite-valid-code-2026", in: app)
        screenshot("Password registration — invitation required", app)
        tap("cloud.password.register", in: app)
        openAccount(in: app)
        let nickname = app.textFields["cloud.nickname"]
        reveal(nickname, in: app)
        XCTAssertTrue(nickname.waitForExistence(timeout: 8))
        XCTAssertEqual(nickname.value as? String, "新朋友")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cloud.source.name.55555555-5555-4555-8555-555555555555").firstMatch.exists)
        let accountNavigation = app.navigationBars["账号与服务器"]
        let back = accountNavigation.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: accountNavigation)
        waitForExpectations(timeout: 5)
        tap("cloud.uploads.open", in: app)
        tap("cloud.source.add", in: app)
        tap("cloud.sharing.sources", in: app)
        tap("cloud.upload.calendar.cloud.fixture.work", in: app)
        tap("cloud.sharing.sources.done", in: app)
        XCTAssertFalse(element("cloud.upload.consent", in: app).exists, "Selecting sources does not authorize their upload")
        XCTAssertFalse(element("cloud.upload.confirm", in: app).exists)
        tap("cloud.sharing.review", in: app)
        let consent = app.switches["cloud.upload.consent"]
        reveal(consent, in: app)
        XCTAssertEqual(consent.value as? String, "0")
        let confirm = element("cloud.upload.confirm", in: app)
        reveal(confirm, in: app)
        XCTAssertFalse(confirm.isEnabled)
        screenshot("Password account — calendar upload still needs explicit consent", app)
        tap("cloud.sharing.review.back", in: app)
        tap("cloud.upload.cancel", in: app)
    }

    @MainActor func testWrongPasswordCanRetryThenLogoutAndLoginAgain() {
        let app = launch()
        fill("cloud.auth.username", "Fixture.User", in: app)
        fill("cloud.auth.password", "WrongPassword123!", secure: true, in: app)
        tap("cloud.password.login", in: app)
        waitLabel("用户名或密码不正确", id: "cloud.error", in: app)
        fill("cloud.auth.password", "FixturePass123!", secure: true, in: app)
        tap("cloud.password.login", in: app)
        openAccount(in: app)
        reveal(app.textFields["cloud.nickname"], in: app)
        XCTAssertTrue(app.textFields["cloud.nickname"].waitForExistence(timeout: 8))
        screenshot("Password login — account active with Apple disabled", app)
        tap("cloud.logout", in: app)
        reveal(app.textFields["cloud.auth.username"], in: app)
        XCTAssertTrue(app.textFields["cloud.auth.username"].waitForExistence(timeout: 8))
        let password = app.secureTextFields["cloud.auth.password"]
        reveal(password, in: app)
        XCTAssertTrue(password.exists)
        XCTAssertEqual(password.value as? String, password.placeholderValue)
        XCTAssertFalse(app.textFields["cloud.nickname"].exists)
        fill("cloud.auth.password", "FixturePass123!", secure: true, in: app)
        tap("cloud.password.login", in: app)
        openAccount(in: app)
        reveal(app.textFields["cloud.nickname"], in: app)
        XCTAssertTrue(app.textFields["cloud.nickname"].waitForExistence(timeout: 8))
    }

    @MainActor func testRestoredPasswordSessionCanChangePasswordAndRejectWrongCurrentPassword() {
        let app = launch("password-restored")
        XCTAssertTrue(app.textFields["cloud.nickname"].waitForExistence(timeout: 8))
        tap("cloud.password.change.open", in: app)
        fill("cloud.password.current", "WrongPassword123!", secure: true, in: app)
        fill("cloud.password.new", "ReplacementPass456!", secure: true, in: app)
        fill("cloud.password.newConfirmation", "ReplacementPass456!", secure: true, in: app)
        tap("cloud.password.change.save", in: app)
        waitLabel("当前密码不正确", id: "cloud.password.change.error", in: app)
        XCTAssertTrue(app.navigationBars["修改密码"].exists)
        fill("cloud.password.current", "FixturePass123!", secure: true, in: app)
        fill("cloud.password.new", "ReplacementPass456!", secure: true, in: app)
        fill("cloud.password.newConfirmation", "ReplacementPass456!", secure: true, in: app)
        screenshot("Password change — wrong current password retains valid session", app)
        tap("cloud.password.change.save", in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["修改密码"])
        waitForExpectations(timeout: 8)
        waitLabel("密码已更新", id: "cloud.notice", in: app)
        tap("cloud.logout", in: app)
        fill("cloud.auth.username", "fixture.user", in: app)
        fill("cloud.auth.password", "ReplacementPass456!", secure: true, in: app)
        tap("cloud.password.login", in: app)
        openAccount(in: app)
        XCTAssertTrue(app.textFields["cloud.nickname"].waitForExistence(timeout: 8))
    }

    @MainActor private func launch(_ scenario: String = "password-fresh") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        configureDedicatedSimulatorIfRequested()
        let app = XCUIApplication()
        app.launchArguments = ["-sharing-home-fixtures", "-cloud-ui-testing", "-cloud-password-fixtures", "-cloud-fixture-scenario", scenario,
            "-app.language.preference", "zh-Hans", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if let size = ProcessInfo.processInfo.environment["CHRONOGRAPH_AUTH_TEXT_SIZE"] { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        if let style = ProcessInfo.processInfo.environment["CHRONOGRAPH_AUTH_STYLE"] { app.launchArguments += ["-AppleInterfaceStyle", style] }
        app.launch()
        tap("home.settings", in: app)
        tap("home.cloudWorkspace", in: app)
        if scenario == "password-restored" { openAccount(in: app) }
        let target = scenario == "password-restored" ? app.textFields["cloud.nickname"] : app.textFields["cloud.auth.username"]
        _ = target.waitForExistence(timeout: 1)
        reveal(target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        return app
    }

    @MainActor private func openAccount(in app: XCUIApplication) {
        let account = element("cloud.account.open", in: app)
        // The session changes the workspace's identity. Wait for the old login
        // form to leave before walking the new page's accessibility containers.
        let login = app.textFields["cloud.auth.username"]
        if login.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: login)
            waitForExpectations(timeout: 8)
        }
        // The hub can grow when a status notice appears. Its account link may
        // not enter the lazy Form's AX tree until it is scrolled into view.
        reveal(account, in: app)
        XCTAssertTrue(account.waitForExistence(timeout: 8))
        tap("cloud.account.open", in: app)
        XCTAssertTrue(app.textFields["cloud.nickname"].waitForExistence(timeout: 8))
    }
    @MainActor private func configureDedicatedSimulatorIfRequested() {
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_MANUAL_PASSWORD_SIMULATOR"] == "1" else { return }
        #if targetEnvironment(simulator)
        // Explicitly opted-in disposable device only. Preserve production AutoFill
        // metadata; the iOS 26.1 Simulator's fake strong-password cover blocks typing.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        let general = settings.staticTexts["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 8))
        general.tap()
        let autofill = settings.staticTexts["AutoFill & Passwords"].firstMatch
        for _ in 0..<5 where !autofill.isHittable { settings.swipeUp() }
        XCTAssertTrue(autofill.waitForExistence(timeout: 5))
        autofill.tap()
        let toggle = settings.switches.matching(NSPredicate(format: "label CONTAINS[c] %@", "AutoFill Passwords")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        settings.terminate()
        #endif
    }
    @MainActor private func fill(_ id: String, _ value: String, secure: Bool = false, in app: XCUIApplication) {
        let field = secure ? app.secureTextFields[id] : app.textFields[id]
        _ = field.waitForExistence(timeout: 2)
        reveal(field, in: app, searchEarlier: id.hasPrefix("cloud.auth.") && element("cloud.error", in: app).exists)
        let old = field.value as? String ?? ""
        let count = old == field.placeholderValue ? 0 : old.count
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        if count > 0 {
            // Opening the keyboard can move a populated Form field. Reveal its
            // current position before placing the caret for replacement.
            reveal(field, in: app)
            XCTAssertTrue(field.isHittable)
            if !secure { field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
            if !app.keyboards.firstMatch.exists { field.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
        if secure {
            // New-password autofill can coalesce a bulk XCTest key-input event.
            // Individual keys exercise normal typing without changing app behavior.
            for character in value { field.typeText(String(character)) }
        } else { field.typeText(value) }
        if !secure { XCTAssertEqual(field.value as? String, value) }
        // Do not press Return: secure fields use it to submit the form.
        let done = app.buttons["cloud.auth.keyboard.done"]
        if done.exists { done.tap() }
        else { app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.tap() }
        if app.keyboards.firstMatch.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            waitForExpectations(timeout: 3)
        }
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
    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 20, searchEarlier: Bool = false) {
        func viewport() -> CGRect {
            let navigation = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.frame ?? app.frame
            let containers = app.collectionViews.allElementsBoundByAccessibilityElement + app.scrollViews.allElementsBoundByAccessibilityElement
            // Login and pushed-page transitions can remove a container between
            // enumeration and use. Snapshot each surviving AX-bound element once,
            // rather than re-resolving a changing ordinal index for its frame.
            let frames = containers.compactMap { container -> CGRect? in
                guard container.exists else { return nil }
                return try? container.snapshot().frame
            }
            // An iPad sheet can be centered inside a larger application window.
            return frames.last(where: { frame in
                frame.width > 100 && frame.height > 100 && frame.intersects(app.frame)
                    && frame.width <= navigation.width + 4
                    && abs(frame.midX - navigation.midX) < navigation.width * 0.25
            }) ?? app.frame
        }
        func band() -> (CGFloat, CGFloat) {
            let navigationBottom = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })?.frame.maxY ?? (app.frame.minY + 64)
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
        let searchDirections: [CGFloat] = searchEarlier ? [1, -1] : [-1, 1]
        for searchDirection in searchDirections {
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
    @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif
