import XCTest

final class NativeFlowTests: XCTestCase {
    @MainActor private func app(signedIn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if !signedIn { app.launchArguments.append("--native-ui-login-fixture") }
        return app
    }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testNativeLoginAndCenteredConversationList() throws {
        let app = app(signedIn: false)
        app.launch()
        let identifier = app.textFields["native.login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        let submit = app.buttons["native.login.submit"]
        XCTAssertFalse(submit.isEnabled)
        screenshot(app, "Native sign-in — no real account")
        identifier.tap()
        identifier.typeText("demo@example.invalid")
        let password = app.secureTextFields["native.login.password"]
        password.tap()
        password.typeText("fixture-password")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.fixture.notice").firstMatch.exists)
        XCTAssertEqual(account.frame.minX - app.frame.minX, app.frame.maxX - account.frame.maxX, accuracy: 1)
        XCTAssertLessThanOrEqual(account.frame.width, 380.5)
        XCTAssertGreaterThanOrEqual(account.frame.minX - app.frame.minX, 12)
        XCTAssertGreaterThanOrEqual(account.frame.height, 72)
        XCTAssertTrue(account.isHittable)
        XCTAssertTrue(app.buttons["native.settings"].isHittable)
        XCTAssertEqual(app.webViews.count, 0)
        screenshot(app, "Native conversation list — synthetic fixture")
    }

    @MainActor func testNativeMessagesSendAndDraftSurvivesNavigation() throws {
        let app = app()
        app.launch()
        let chat = app.buttons["native.conversation.fixture-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.staticTexts["Das läuft jetzt direkt in SwiftUI."].waitForExistence(timeout: 10))
        let composer = app.descendants(matching: .any).matching(identifier: "native.composer").firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertFalse(app.buttons["native.send"].isEnabled)
        composer.tap()
        composer.typeText("Native Testnachricht")
        app.buttons["native.send"].tap()
        XCTAssertTrue(app.staticTexts["Native Testnachricht"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["native.send"].isEnabled)
        screenshot(app, "Native messages and keyboard — synthetic fixture")
        composer.tap()
        composer.typeText("Lokaler Entwurf")
        app.navigationBars.buttons["Nachrichten"].tap()
        app.buttons["native.conversation.fixture-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Lokaler Entwurf")
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor func testNativeAccountSignOut() throws {
        let app = app()
        app.launch()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        let signOut = app.buttons["native.settings.signOut"]
        if !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Abmelden", "native.settings.signOut")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["native.login.identifier"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["native.account"].exists)
        XCTAssertEqual(app.webViews.count, 0)
    }
}
