import XCTest

/// Captures the actual native source-shaped screens with explicitly anonymous Debug data.
final class NativeOriginalVisualTests: XCTestCase {
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func capture(_ app: XCUIApplication, _ label: String, appearance: String) {
        XCTAssertEqual(app.webViews.count, 0, "All product surfaces in this fixture run must be native.")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Original Yapper \(appearance) · \(label) · anonymous fixture"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func surfaces(appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-native.appearance", appearance]
        app.launch()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let rail = element(app, "native.original.rail")
        XCTAssertTrue(rail.exists)
        XCTAssertEqual(rail.frame.width, 72, accuracy: 1)
        XCTAssertTrue(element(app, "native.fixture.notice").exists)
        capture(app, "Home / server rail / direct messages", appearance: appearance)

        account.tap()
        let menu = element(app, "native.original.accountMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(menu.frame.width, 320.5)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX)
        capture(app, "Account popover", appearance: appearance)
        let profile = app.buttons["Mein Profil anzeigen"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        XCTAssertTrue(app.staticTexts["@yapper-demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["native.profile.edit"].exists)
        capture(app, "Own profile", appearance: appearance)
        app.buttons["native.profile.close"].firstMatch.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))

        let chat = app.buttons["native.conversation.fixture-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(element(app, "native.composer").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "native.conversation.header").exists)
        XCTAssertTrue(app.staticTexts["Das läuft jetzt direkt in SwiftUI."].waitForExistence(timeout: 5))
        capture(app, "Native chat and composer", appearance: appearance)
        let chatBack = app.buttons["native.conversation.back"]
        if chatBack.exists && chatBack.isHittable { chatBack.tap() }
        else { app.buttons["Home"].firstMatch.tap() }
        XCTAssertTrue(account.waitForExistence(timeout: 5))

        if !app.buttons["native.settings"].firstMatch.exists { account.tap() }
        let settings = app.buttons["native.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["native.settings.tab.account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["native.profile.edit"].waitForExistence(timeout: 5))
        capture(app, "Account settings", appearance: appearance)
    }

    @MainActor func testDarkOriginalSurfaces() throws { try surfaces(appearance: "dark") }
    @MainActor func testLightOriginalSurfaces() throws { try surfaces(appearance: "light") }
}
