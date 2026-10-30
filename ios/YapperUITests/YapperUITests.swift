import XCTest

final class YapperUITests: XCTestCase {
    @MainActor func testYapperCordManagerOpensInAnonymousSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--yapper-uitest-ephemeral-session", "-yapperCordEnabled", "YES"]
        app.launch()
        let webView = app.webViews.firstMatch
        let launcher = webView.buttons["Open YapperCord plugins"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 40))
        launcher.tap()
        XCTAssertTrue(webView.buttons["Close plugin manager"].waitForExistence(timeout: 5))
        XCTAssertTrue(webView.staticTexts["CharacterCounter"].exists)
        XCTAssertFalse(app.otherElements["connectionError"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "YapperCord plugin manager on iOS — anonymous session"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testOriginalMobileLoginLoads() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--yapper-uitest-ephemeral-session"]
        app.launch()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        let welcome = webView.staticTexts["Welcome back"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 40), "The live Yapper login must load without a native error overlay.")
        XCTAssertTrue(webView.buttons["Log in"].exists)
        XCTAssertFalse(app.otherElements["connectionError"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Original Yapper login on iOS"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
