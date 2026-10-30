import XCTest

final class YapperUITests: XCTestCase {
    @MainActor func testYapperCordManagerOpensInAnonymousSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--yapper-uitest-ephemeral-session", "-yapperCordEnabled", "YES"]
        app.launch()
        let webView = app.webViews.firstMatch
        let launcher = webView.buttons["Open Yapinplugger plugins"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 40))
        launcher.tap()
        let close = webView.buttons["Close plugin manager"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(close.frame.minY, 60, "The manager's close control must clear the status bar.")
        XCTAssertEqual(webView.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(webView.frame.height, app.frame.height, accuracy: 1)
        XCTAssertTrue(webView.staticTexts["CharacterCounter"].exists)
        XCTAssertFalse(app.otherElements["connectionError"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Yapinplugger plugin manager on iOS — anonymous session"
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

    @MainActor func testFullScreenViewportProtectsControlsAndFollowsTheme() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--yapper-uitest-ephemeral-session", "--yapper-uitest-edge-fixture", "-enhancedProfileLayoutEnabled", "NO", "-yapperCordEnabled", "NO"]
        app.launchEnvironment["YAPPER_EDGE_FIXTURE_HTML"] = Self.viewportFixture
        app.launch()
        let webView = app.webViews.firstMatch
        let top = webView.buttons["Top action"]
        let home = webView.buttons["Home"]
        XCTAssertTrue(top.waitForExistence(timeout: 15))
        let metrics = webView.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Viewport safe top ")).firstMatch
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let values = metrics.label.split(separator: " ")
        let safeTop = try XCTUnwrap(Double(values[3]))
        let safeBottom = try XCTUnwrap(Double(values[5]))
        XCTAssertGreaterThan(safeTop, 20, "System status area remains available.")
        XCTAssertGreaterThan(safeBottom, 0, "System home indicator remains available.")
        XCTAssertEqual(webView.frame.minX, 0, accuracy: 1)
        XCTAssertEqual(webView.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(webView.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(webView.frame.height, app.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(top.frame.minY, safeTop - 1)
        XCTAssertLessThanOrEqual(home.frame.maxY, app.frame.height - safeBottom + 1)
        XCTAssertTrue(top.isHittable)
        XCTAssertTrue(home.isHittable)
        var attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fullscreen red theme — anonymous viewport fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        webView.buttons["Change theme"].tap()
        XCTAssertTrue(webView.staticTexts["Theme changed to teal"].waitForExistence(timeout: 3))
        attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fullscreen dynamic teal theme — anonymous viewport fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(top.frame.minY, safeTop - 1)
        XCTAssertLessThanOrEqual(home.frame.maxY, app.frame.height - safeBottom + 1)
    }

    private static let viewportFixture = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root{--bg-main:#692736;color-scheme:dark}html,body{margin:0;background:var(--bg-main);font:16px -apple-system;color:white}
    .app{height:100dvh}.stage-row{height:100%;display:flex}.sidebar{padding:12px;flex:1}button{font:inherit;color:white;background:#ffffff22;border:1px solid #ffffff66;border-radius:12px;padding:12px 18px;min-height:44px}
    h1{font-size:24px;margin-top:44px}p{line-height:1.5}nav.nl-tabbar{position:fixed;left:0;right:0;bottom:0;height:56px;display:flex;align-items:center;justify-content:center;background:#ffffff11}#probe{position:absolute;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}
    </style></head><body><div class="app"><div class="stage-row"><main class="sidebar"><button>Top action</button><h1>Yapper viewport verification</h1><p>Anonymous layout fixture</p><p id="metrics" aria-live="polite">Preparing viewport</p><button onclick="document.documentElement.style.setProperty('--bg-main','#1b5261');document.getElementById('theme').textContent='Theme changed to teal'">Change theme</button><p id="theme">Red theme</p></main></div><nav class="nl-tabbar"><button>Home</button></nav></div><div id="probe"></div><script>
    function report(){let s=getComputedStyle(document.getElementById('probe'));document.getElementById('metrics').textContent='Viewport safe top '+parseFloat(s.paddingTop)+' bottom '+parseFloat(s.paddingBottom)}
    requestAnimationFrame(()=>requestAnimationFrame(report));window.addEventListener('resize',report);
    </script></body></html>
    """#
}
