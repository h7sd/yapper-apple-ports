import XCTest

final class YapperUITests: XCTestCase {
    @MainActor func testOriginalMobileLoginLoads() throws {
        let app = XCUIApplication()
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
