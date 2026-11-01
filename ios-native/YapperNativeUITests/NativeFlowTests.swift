import XCTest

final class NativeFlowTests: XCTestCase {
    @MainActor private func app(signedIn: Bool = true, language: String = "de") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        if !signedIn { app.launchArguments.append("--native-ui-login-fixture") }
        return app
    }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func leaveConversation(_ app: XCUIApplication) {
        let back = app.buttons["native.conversation.back"]
        if back.exists && back.isHittable { back.tap() }
        else { app.buttons["Home"].firstMatch.tap() }
    }

    @MainActor func testNativeLoginAndCenteredConversationList() throws {
        let app = app(signedIn: false)
        app.launch()
        let welcome = app.staticTexts["native.welcome.title"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        XCTAssertEqual(welcome.label, "Willkommen bei Yapper")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.terms").firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.privacy").firstMatch.isHittable)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertFalse(app.staticTexts["Deine Gespräche. Jetzt nativ auf dem iPhone."].exists)
        XCTAssertEqual(app.webViews.count, 0)
        screenshot(app, "German welcome with legal footer — no real account")
        app.buttons["native.login.web"].tap()
        let finish = app.buttons["native.webLogin.fixture.complete"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.fixture.notice").firstMatch.exists)
        let bar = app.descendants(matching: .any).matching(identifier: "native.original.accountBar").firstMatch
        let sidebar = app.descendants(matching: .any).matching(identifier: "native.original.sidebar").firstMatch
        let rail = app.descendants(matching: .any).matching(identifier: "native.original.rail").firstMatch
        XCTAssertTrue(bar.exists && sidebar.exists && rail.exists)
        if app.frame.width <= 760 {
            XCTAssertEqual(rail.frame.width, 64, accuracy: 1)
            XCTAssertEqual(bar.frame.minX - sidebar.frame.minX, sidebar.frame.maxX - bar.frame.maxX, accuracy: 1)
            XCTAssertEqual(bar.frame.height, 64, accuracy: 1)
        } else {
            XCTAssertEqual(rail.frame.width, 72, accuracy: 1)
            XCTAssertEqual(bar.frame.width, 316, accuracy: 1)
            XCTAssertEqual(bar.frame.minX - rail.frame.minX, sidebar.frame.maxX - bar.frame.maxX, accuracy: 1)
            XCTAssertEqual(bar.frame.height, 66, accuracy: 1)
        }
        XCTAssertGreaterThanOrEqual(account.frame.height, 44)
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
        if app.frame.width <= 760 { XCTAssertFalse(app.buttons["native.send"].exists) } else { XCTAssertFalse(app.buttons["native.send"].isEnabled) }
        composer.tap()
        composer.typeText("Native Testnachricht")
        app.buttons["native.send"].tap()
        XCTAssertTrue(app.staticTexts["Native Testnachricht"].waitForExistence(timeout: 5))
        if app.frame.width <= 760 { XCTAssertFalse(app.buttons["native.send"].exists) } else { XCTAssertFalse(app.buttons["native.send"].isEnabled) }
        screenshot(app, "Native messages and keyboard — synthetic fixture")
        composer.tap()
        composer.typeText("Lokaler Entwurf")
        leaveConversation(app)
        app.buttons["native.conversation.fixture-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Lokaler Entwurf")
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor func testNativeAccountSignOut() throws {
        let app = app()
        app.launch()
        let signOut = app.buttons["native.account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        XCTAssertTrue(signOut.isHittable)
        signOut.tap()
        let confirm = app.buttons.matching(identifier: "native.settings.signOut.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["native.welcome.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["native.account"].exists)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor func testEnglishWelcomeAndLegalFooter() throws {
        let app = app(signedIn: false, language: "en")
        app.launch()
        let welcome = app.staticTexts["native.welcome.title"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        XCTAssertEqual(welcome.label, "Welcome to Yapper")
        XCTAssertEqual(app.buttons["native.login.web"].label, "Sign in")
        for id in ["native.terms", "native.privacy"] {
            let link = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(link.exists)
            XCTAssertTrue(link.isHittable)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        }
        XCTAssertEqual(app.webViews.count, 0)
        screenshot(app, "English welcome with legal footer — no real account")
    }

    @MainActor func testOfficialWebLoginLoadsAndCancelsWithoutAccount() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let signIn = app.buttons["native.login.web"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        XCTAssertTrue(web.secureTextFields.firstMatch.waitForExistence(timeout: 30), "The real official login must load its password form; no credentials or CAPTCHA are submitted.")
        screenshot(app, "Official web sign-in only — no account or CAPTCHA submission")
        app.buttons["native.webLogin.cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertEqual(app.webViews.count, 0)
    }
}
