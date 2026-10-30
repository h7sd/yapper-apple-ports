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
        let safeAreasReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "^Viewport safe top [1-9][0-9.]* bottom [1-9][0-9.]* .*"), object: metrics)
        XCTAssertEqual(XCTWaiter.wait(for: [safeAreasReady], timeout: 5), .completed, "Wait for WebKit's safe-area environment values to settle after viewport-fit changes.")
        let values = metrics.label.split(separator: " ")
        let safeTop = try XCTUnwrap(Double(values[3]))
        let safeBottom = try XCTUnwrap(Double(values[5]))
        let appTop = try XCTUnwrap(Double(values[7]))
        let appHeight = try XCTUnwrap(Double(values[9]))
        let viewportHeight = try XCTUnwrap(Double(values[11]))
        let navBottom = try XCTUnwrap(Double(values[13]))
        let navHeight = try XCTUnwrap(Double(values[15]))
        XCTAssertEqual(appTop, 0, accuracy: 1, "The themed app itself must start at the top edge, beyond the dark body canvas.")
        XCTAssertEqual(appHeight, viewportHeight, accuracy: 1)
        XCTAssertEqual(appHeight, app.frame.height, accuracy: 1)
        XCTAssertEqual(navBottom, viewportHeight, accuracy: 1, "The original navigation owns its safe-area padding and must reach the bottom edge.")
        XCTAssertEqual(navHeight, 56 + safeBottom, accuracy: 1)
        XCTAssertEqual(try metric("appPaddingTop", in: metrics.label), safeTop, accuracy: 1)
        XCTAssertEqual(try metric("railPaddingTop", in: metrics.label), 10, accuracy: 1)
        XCTAssertEqual(try metric("sidebarPaddingTop", in: metrics.label), 10, accuracy: 1)
        XCTAssertEqual(try metric("mainPaddingTop", in: metrics.label), 0, accuracy: 1)
        XCTAssertEqual(try metric("mainHeight", in: metrics.label), 48, accuracy: 1)
        XCTAssertLessThanOrEqual(top.frame.minY, safeTop + 12)
        XCTAssertLessThanOrEqual(webView.buttons["Rail action"].frame.minY, safeTop + 12)
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
        webView.buttons["Use new look"].tap()
        let newLookReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "mode new-look"), object: metrics)
        XCTAssertEqual(XCTWaiter.wait(for: [newLookReady], timeout: 5), .completed)
        XCTAssertEqual(try metric("appPaddingTop", in: metrics.label), safeTop, accuracy: 1)
        XCTAssertEqual(try metric("railPaddingTop", in: metrics.label), 8, accuracy: 1)
        XCTAssertEqual(try metric("sidebarPaddingTop", in: metrics.label), 0, accuracy: 1)
        XCTAssertEqual(try metric("mainPaddingTop", in: metrics.label), 4, accuracy: 1)
        XCTAssertEqual(try metric("mainHeight", in: metrics.label), 52, accuracy: 1)
        XCTAssertGreaterThanOrEqual(top.frame.minY, safeTop - 1)
        XCTAssertLessThanOrEqual(top.frame.minY, safeTop + 12)
        XCTAssertGreaterThanOrEqual(webView.buttons["Rail action"].frame.minY, safeTop - 1)
        XCTAssertLessThanOrEqual(webView.buttons["Rail action"].frame.minY, safeTop + 12)
        XCTAssertLessThanOrEqual(home.frame.maxY, app.frame.height - safeBottom + 1)
        attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fullscreen new-look — anonymous viewport fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func metric(_ name: String, in label: String) throws -> Double {
        let parts = label.split(separator: " ")
        let index = try XCTUnwrap(parts.firstIndex(of: Substring(name)))
        return try XCTUnwrap(Double(parts[index + 1]))
    }

    private static let viewportFixture = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>
    :root{--app-theme:#692736;color-scheme:dark}*{box-sizing:border-box}html,body{margin:0;background:#101114;font:16px -apple-system;color:white}
    .app{height:100dvh;display:flex;flex-direction:column;background:var(--app-theme)}.stage-row{flex:1;min-width:0;min-height:0;display:flex}.main{min-width:0;display:flex;flex-direction:column;flex:1}.sidebar-scroll{padding:12px}.rail{width:64px;flex-shrink:0;display:flex;flex-direction:column;align-items:center;padding-top:calc(10px + env(safe-area-inset-top))}.sidebar-head{height:52px;padding:0 12px 0 16px;padding-top:calc(10px + env(safe-area-inset-top))}.sidebar-probe{position:absolute;visibility:hidden}.main-head{display:flex;align-items:center;height:calc(48px + env(safe-area-inset-top));padding:env(safe-area-inset-top) 8px 0 6px;flex-shrink:0}
    html.new-look .app{padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom)}html.new-look .rail{padding:8px 0}html.new-look .sidebar-head{height:52px;padding:0 8px 0 16px}html.new-look .main-head{height:auto;min-height:52px;padding:4px}
    button{font:inherit;color:white;background:#ffffff22;border:1px solid #ffffff66;border-radius:12px;padding:10px;min-height:44px}h1{font-size:20px;margin-top:16px}p{line-height:1.4}#metrics{font-size:12px}nav.nl-tabbar{position:fixed;left:0;right:0;bottom:0;height:calc(56px + env(safe-area-inset-bottom));padding-bottom:env(safe-area-inset-bottom);display:flex;align-items:center;justify-content:center}#probe{position:absolute;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}
    </style></head><body><div class="app"><div class="stage-row"><aside class="rail"><button aria-label="Rail action">R</button></aside><main class="main"><header class="main-head"><button>Top action</button></header><div class="sidebar-scroll"><div class="sidebar-probe"><div class="sidebar-head">Header probe</div></div><h1>Yapper viewport verification</h1><p>Anonymous layout fixture</p><p id="metrics" aria-live="polite">Preparing viewport</p><button onclick="document.documentElement.style.setProperty('--app-theme','#1b5261');document.getElementById('theme').textContent='Theme changed to teal'">Change theme</button><p id="theme">Red theme</p><button onclick="document.documentElement.classList.add('new-look');requestAnimationFrame(report)">Use new look</button></div></main></div><nav class="nl-tabbar"><button>Home</button></nav></div><div id="probe"></div><script>
    function report(){let s=getComputedStyle(document.getElementById('probe')),a=document.querySelector('.app'),n=document.querySelector('nav').getBoundingClientRect(),m=document.querySelector('.main-head');document.getElementById('metrics').textContent='Viewport safe top '+parseFloat(s.paddingTop)+' bottom '+parseFloat(s.paddingBottom)+' appTop '+a.getBoundingClientRect().top+' appHeight '+a.getBoundingClientRect().height+' innerHeight '+innerHeight+' navBottom '+n.bottom+' navHeight '+n.height+' appPaddingTop '+parseFloat(getComputedStyle(a).paddingTop)+' railPaddingTop '+parseFloat(getComputedStyle(document.querySelector('.rail')).paddingTop)+' sidebarPaddingTop '+parseFloat(getComputedStyle(document.querySelector('.sidebar-head')).paddingTop)+' mainPaddingTop '+parseFloat(getComputedStyle(m).paddingTop)+' mainHeight '+m.getBoundingClientRect().height+' mode '+(document.documentElement.classList.contains('new-look')?'new-look':'base')}
    const observer=new ResizeObserver(report);for(const node of [document.getElementById('probe'),document.querySelector('nav'),document.querySelector('.main-head')])observer.observe(node,{box:'border-box'});requestAnimationFrame(()=>requestAnimationFrame(report));window.addEventListener('resize',report);window.visualViewport?.addEventListener('resize',report);
    </script></body></html>
    """#
}
