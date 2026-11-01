import XCTest

/// Exercises only explicitly labelled Debug fixtures, never a user's account or service mutations.
final class NativeFeatureFlowTests: XCTestCase {
    private let friendID = "33333333-3333-4333-8333-333333333333"

    @MainActor private func app(language: String = "de", signedIn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US", "-native.appearance", "dark"]
        if !signedIn { app.launchArguments.append("--native-ui-login-fixture") }
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func tap(_ target: XCUIElement, in app: XCUIApplication, scroll: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if scroll {
            for _ in 0..<6 {
                if target.exists && target.isHittable { break }
                app.swipeUp()
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(target.isHittable, file: file, line: line)
        target.tap()
    }

    @MainActor private func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        if label == "Einstellungen" { return app.buttons["native.settings"] }
        let tab = app.tabBars.buttons[label].firstMatch
        return tab.exists ? tab : app.buttons[label].firstMatch
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let chatBack = app.buttons["native.conversation.back"]
        if chatBack.exists && chatBack.isHittable { chatBack.tap(); return }
        let customBack = app.buttons.matching(NSPredicate(format: "label == %@", "Zurück")).allElementsBoundByIndex.first(where: { $0.isHittable })
        if let customBack { customBack.tap(); return }
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists && button.isHittable { button.tap(); return }
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).allElementsBoundByIndex.first(where: { $0.isHittable })
        if let home { home.tap(); return }
        XCTFail("A real custom back, navigation back, or visible Home rail action is required.")
    }

    @MainActor private func settingsTab(_ app: XCUIApplication, _ id: String) {
        let strip = element(app, id: "native.settings.tabs")
        let target = app.buttons["native.settings.tab." + id]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        for attempt in 0...8 {
            let viewport = strip.frame.intersection(app.frame)
            let frame = target.frame
            // UIKit cannot calculate an activation point for an offscreen
            // horizontal-scroll child. Check geometry before querying it.
            if !viewport.isEmpty && !frame.isEmpty && viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                // Some SwiftUI clipped ScrollView children have no AX activation
                // point despite a visible center. Tap that measured screen point;
                // the destination's real controls are asserted by each flow.
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
                return
            }
            guard attempt < 8 else { break }
            let direction: CGFloat = frame.midX > viewport.midX ? -1 : 1
            let distance = min(abs(frame.midX - viewport.midX), viewport.width * 0.35)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - app.frame.minX, dy: viewport.midY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - app.frame.minX + direction * distance, dy: viewport.midY - app.frame.minY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)

        }
        XCTFail("The settings tab \(id) must have a visible activation center and be interactive within eight horizontal scrolls.")
    }

    @MainActor private func visibleButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    @MainActor private func nativeOnly(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.webViews.count, 0, "Every tested application surface must remain native.", file: file, line: line)
    }

    @MainActor private func waitForDismissal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "The presented navigation surface must finish dismissing.", file: file, line: line)
    }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name + " — anonymous Debug fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testHomeTabsPeopleSearchAndNativeProfileConversation() throws {
        let app = app()
        let friends = app.buttons["native.home.people"]
        XCTAssertTrue(friends.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(friends.frame.height, 44)
        if app.frame.width <= 760 {
            for label in ["Home", "Server", "Einstellungen"] {
                let item = tab(app, label)
                XCTAssertTrue(item.exists)
                XCTAssertTrue(item.isHittable)
            }
        } else {
            XCTAssertFalse(element(app, id: "native.app.tabs").exists, "The wide original layout uses its server rail and account actions.")
            XCTAssertTrue(element(app, id: "native.original.rail").exists)
            XCTAssertTrue(app.buttons["native.server.66666666-6666-4666-8666-666666666666"].isHittable)
            XCTAssertTrue(app.buttons["native.settings"].isHittable)
        }
        nativeOnly(app)
        tap(friends, in: app)
        XCTAssertTrue(element(app, id: "native.people.filter").waitForExistence(timeout: 10))
        let add = app.buttons["native.people.add"]
        XCTAssertTrue(add.exists)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        let search = app.textFields["Personen finden"]
        tap(search, in: app)
        search.typeText("Nova")
        let person = app.buttons["native.people." + friendID]
        tap(person, in: app)
        XCTAssertTrue(app.staticTexts["@nova"].waitForExistence(timeout: 10))
        let message = app.buttons["native.profile.message"]
        XCTAssertTrue(message.exists)
        nativeOnly(app)
        screenshot(app, "Native friend search and profile")
        tap(message, in: app, scroll: true)
        XCTAssertTrue(element(app, id: "native.composer").waitForExistence(timeout: 10))
        waitForDismissal(element(app, id: "native.people.filter"))
        nativeOnly(app)
        screenshot(app, "Profile opens native direct conversation")
    }

    @MainActor func testSettingsProfileEditorSecurityAndPluginControls() throws {
        let app = app(language: "en")
        XCTAssertTrue(app.buttons["native.home.people"].waitForExistence(timeout: 10))
        tap(tab(app, "Einstellungen"), in: app)
        XCTAssertTrue(app.staticTexts["@yapper-demo"].waitForExistence(timeout: 10))
        let edit = visibleButton(app, "native.profile.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(edit.frame.height, 44)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        tap(edit, in: app)
        XCTAssertTrue(app.textFields["Anzeigename"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["Anzeigename"].exists)
        XCTAssertTrue(app.buttons["native.profile.save"].exists)
        nativeOnly(app)
        screenshot(app, "Native profile editor")
        tap(visibleButton(app, "Abbrechen"), in: app)
        waitForDismissal(app.buttons["native.profile.save"])
        XCTAssertTrue(app.buttons["native.profile.edit"].waitForExistence(timeout: 5))
        settingsTab(app, "security")
        let password = app.buttons["native.security.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(password.frame.height, 44)
        nativeOnly(app)
        screenshot(app, "Native security settings without account changes")
        tap(password, in: app)
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.secureTextFields.count, 3)
        XCTAssertFalse(app.buttons["Passwort speichern"].isEnabled)
        nativeOnly(app)
        tap(visibleButton(app, "Abbrechen"), in: app)
        waitForDismissal(app.secureTextFields.firstMatch)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        settingsTab(app, "plugins")
        let counter = app.switches["Zeichenzähler"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let original = counter.value as? String
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original ?? "1"), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", original ?? "1"), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed, "Restore the owned test app's original preference.")
        XCTAssertTrue(app.switches["Bild-Zoom"].exists)
        XCTAssertTrue(app.switches["Bild-in-Bild für Videos"].exists)
        nativeOnly(app)
        screenshot(app, "Native Yapinplugger plugin controls")
    }

    @MainActor func testCommunityNavigationAndNativeBalances() throws {
        let app = app()
        XCTAssertTrue(app.buttons["native.home.people"].waitForExistence(timeout: 10))
        tap(tab(app, "Einstellungen"), in: app)
        settingsTab(app, "community")
        XCTAssertTrue(app.buttons["Shards & Quests"].waitForExistence(timeout: 5))
        nativeOnly(app)
        tap(app.buttons["Shards & Quests"], in: app)
        XCTAssertTrue(app.staticTexts["Guthaben"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Noch keine Einträge."].exists)
        nativeOnly(app)
        screenshot(app, "Native synthetic Shards balance")
        back(app)
        tap(app.buttons["Ranglisten"], in: app)
        XCTAssertTrue(app.switches["Mich aus Ranglisten ausblenden"].waitForExistence(timeout: 5))
        nativeOnly(app)
        back(app)
        tap(app.buttons["Dekorationen"], in: app)
        XCTAssertTrue(app.staticTexts["Zurzeit keine Dekorationen verfügbar."].waitForExistence(timeout: 5))
        nativeOnly(app)
        back(app)
        tap(app.buttons["Hilfe & Kontostatus"], in: app)
        XCTAssertTrue(app.buttons["Kontostatus & Widerspruch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fehlerberichte"].exists)
        XCTAssertTrue(app.buttons["Verifizierung beantragen"].exists)
        nativeOnly(app)
        screenshot(app, "Native support and community menus")
    }

    @MainActor func testServerChannelsMembersAndNativeConversation() throws {
        let app = app()
        XCTAssertTrue(app.buttons["native.home.people"].waitForExistence(timeout: 10))
        if app.frame.width <= 760 { tap(tab(app, "Server"), in: app) }
        let server = app.buttons["native.server.66666666-6666-4666-8666-666666666666"]
        tap(server, in: app)
        XCTAssertTrue(app.buttons["Servermenü"].waitForExistence(timeout: 5))
        let channel = app.buttons["native.server.channel.77777777-7777-4777-8777-777777777777"]
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(channel.frame.height, 44)
        nativeOnly(app)
        screenshot(app, "Native synthetic server and channel list")
        tap(channel, in: app)
        XCTAssertTrue(element(app, id: "native.conversation.header").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["#allgemein"].exists)
        XCTAssertTrue(element(app, id: "native.composer").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Das läuft jetzt direkt in SwiftUI."].waitForExistence(timeout: 5))
        nativeOnly(app)
        screenshot(app, "Native server text channel")
        back(app)
        if !app.buttons["Servermenü"].exists { tap(server, in: app) }
        tap(app.buttons["Servermenü"], in: app)
        tap(app.buttons["Mitglieder"], in: app)
        XCTAssertTrue(app.navigationBars["Mitglieder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nova"].waitForExistence(timeout: 5))
        nativeOnly(app)
        screenshot(app, "Native synthetic server members")
        tap(app.navigationBars["Mitglieder"].buttons["Fertig"], in: app)
        waitForDismissal(app.navigationBars["Mitglieder"])
        XCTAssertTrue(channel.isHittable, "The channel list must be interactive after the members sheet closes.")
        nativeOnly(app)
    }

    @MainActor func testGermanWelcomeKeepsBothLegalLinksVisibleWithNativeTouchTargets() throws {
        let app = app(signedIn: false)
        let welcome = app.staticTexts["native.welcome.title"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        XCTAssertEqual(welcome.label, "Willkommen bei Yapper")
        XCTAssertEqual(app.buttons["native.login.web"].label, "Anmelden")
        for id in ["native.terms", "native.privacy"] {
            let link = element(app, id: id)
            XCTAssertTrue(link.exists)
            XCTAssertTrue(link.isHittable)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
            XCTAssertGreaterThanOrEqual(link.frame.minY, app.frame.midY)
            XCTAssertLessThanOrEqual(link.frame.maxY, app.frame.maxY)
        }
        nativeOnly(app)
        screenshot(app, "German native welcome with visible legal footer")
    }
}
