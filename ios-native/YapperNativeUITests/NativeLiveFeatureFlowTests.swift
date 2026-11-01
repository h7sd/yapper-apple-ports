import XCTest

/// Explicit offline live-state fixtures; no account, server writes, microphone or camera use.
final class NativeLiveFeatureFlowTests: XCTestCase {
    private let serverID = "66666666-6666-4666-8666-666666666666"
    private let textID = "77777777-7777-4777-8777-777777777777"
    private let readOnlyID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let mentionID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1"

    @MainActor private func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "--native-ui-live-fixtures", "-native.fixtureColorTheme", "crimson", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-native.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["native.server.\(serverID)"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func dismissNotice(_ app: XCUIApplication) {
        let dismiss = app.buttons["native.mention.notice.dismiss"]
        if dismiss.exists { dismiss.tap() }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        XCTAssertEqual(app.webViews.count, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "0.2.4 " + name + " — anonymous fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testOnlineHomeServerUnreadAndActualVoiceRoster() throws {
        let app = app()
        dismissNotice(app)
        let server = app.buttons["native.server.\(serverID)"]
        XCTAssertTrue((server.value as? String ?? "").contains("13 ungelesene Nachrichten"))
        XCTAssertTrue((server.value as? String ?? "").contains("2 Erwähnungen"))
        capture(app, "Account tint and unread server badge")
        server.tap()
        let channel = app.buttons["native.server.channel.\(textID)"]
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        let nova = element(app, "native.server.voice.member.33333333-3333-4333-8333-333333333333")
        let milo = element(app, "native.server.voice.member.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(nova.waitForExistence(timeout: 5))
        XCTAssertTrue(milo.exists)
        XCTAssertTrue(nova.label.contains("Nova"))
        XCTAssertTrue(milo.label.contains("Mikrofon stumm"))
        capture(app, "Unread channels and voice participants")
        app.buttons["Servermenü"].tap()
        app.buttons["Mitglieder"].tap()
        XCTAssertTrue(element(app, "native.server.member.33333333-3333-4333-8333-333333333333").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "native.server.member.44444444-4444-4444-8444-444444444444").exists)
        capture(app, "Members with role colours")
    }

    @MainActor func testReadOnlyChannelBlocksComposerAndMentionsResolveInWritableChannel() throws {
        let app = app()
        dismissNotice(app)
        let server = app.buttons["native.server.\(serverID)"]
        server.tap()
        let readOnly = app.buttons["native.server.channel.\(readOnlyID)"]
        XCTAssertTrue(readOnly.waitForExistence(timeout: 5)); readOnly.tap()
        XCTAssertTrue(element(app, "native.composer.readOnly").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "native.composer").exists)
        XCTAssertFalse(app.buttons["native.send"].exists)
        capture(app, "Read-only announcement channel")
        let back = app.buttons["native.conversation.back"]
        if back.exists { back.tap() }
        let general = app.buttons["native.server.channel.\(textID)"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        let before = XCTAttachment(string: "General frame: \(general.frame)\n" + app.debugDescription)
        before.name = "Channel target before direct switch"; before.lifetime = .keepAlways; add(before)
        general.tap()
        if !element(app, "native.composer").waitForExistence(timeout: 5) {
            let after = XCTAttachment(string: app.debugDescription)
            after.name = "Channel target after direct switch"; after.lifetime = .keepAlways; add(after)
        }
        XCTAssertTrue(element(app, "native.composer").waitForExistence(timeout: 5))
        let mentionedText = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "@Yapper Demo")).firstMatch
        XCTAssertTrue(mentionedText.waitForExistence(timeout: 5))
        let text = mentionedText.value as? String ?? ""
        XCTAssertTrue(text.contains("@Moderation")); XCTAssertTrue(text.contains("#allgemein"))
        XCTAssertFalse(text.contains("<@"))
        capture(app, "Resolved user role and channel mentions")
    }

    @MainActor func testMentionNoticeOpensTheActualNativeMessage() throws {
        let app = app()
        let notice = app.buttons["native.mention.notice.open"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3)); notice.tap()
        XCTAssertTrue(element(app, "native.message.\(mentionID)").waitForExistence(timeout: 8))
        XCTAssertTrue(element(app, "native.composer").exists)
        capture(app, "Mention notice message destination")
    }

    @MainActor func testMentionInboxAndPeerOnlineHeader() throws {
        let app = app()
        dismissNotice(app)
        app.buttons["native.home.toolbar.inbox"].tap()
        let mention = app.buttons["native.inbox.mention.\(mentionID)"]
        XCTAssertTrue(mention.waitForExistence(timeout: 5))
        capture(app, "Mention inbox")
        app.buttons["Fertig"].firstMatch.tap()
        app.buttons["native.conversation.fixture-chat"].tap()
        let presence = element(app, "native.conversation.presence")
        XCTAssertTrue(presence.waitForExistence(timeout: 5)); XCTAssertEqual(presence.label, "Online")
        capture(app, "Online peer in native conversation")
    }
}
