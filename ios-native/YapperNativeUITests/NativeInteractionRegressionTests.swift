import XCTest

/// All actions use owned anonymous fixtures; this suite never sends to a real account.
final class NativeInteractionRegressionTests: XCTestCase {
    @MainActor private func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixtures", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-native.appearance", "dark"]
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func disappears(_ target: XCUIElement, timeout: TimeInterval = 5) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        XCTAssertEqual(app.webViews.count, 0)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name + " — anonymous fixture"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testSingleBackTapAtButtonEdgesPreservesDraftAndReturnsHome() throws {
        let app = app()
        let chat = app.buttons["native.conversation.fixture-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        let points = [CGVector(dx: 0.12, dy: 0.12), CGVector(dx: 0.88, dy: 0.88), CGVector(dx: 0.12, dy: 0.88)]
        for (index, point) in points.enumerated() {
            chat.tap()
            let composer = element(app, "native.composer")
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            if index == 0 { composer.typeText("Entwurf bleibt erhalten") }
            XCTAssertEqual(composer.value as? String, "Entwurf bleibt erhalten")
            let back = app.buttons["native.conversation.back"]
            let action = back.exists ? back : app.buttons["Home"].firstMatch
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.width, 44 - 0.001)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44 - 0.001)
            action.coordinate(withNormalizedOffset: point).tap()
            disappears(composer)
            XCTAssertTrue(chat.isHittable, "One tap must return to the home pane, even with the keyboard open.")
        }
        capture(app, "One-tap back and preserved draft")
    }

    @MainActor private func openGallery(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["native.composer.attach"].tap()
        let gallery = app.buttons["Foto oder Video auswählen"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.tap()
        let picker = element(app, "native.gallery.picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "The system photo/video picker must open, not the Files browser.")
        return picker
    }

    @MainActor private func cancelGallery(_ picker: XCUIElement) throws {
        // The picker can also show an onboarding card with its own Close button.
        // Cancel is the Photos navigation action, independent of the device language.
        let cancel = picker.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The native picker needs its real cancel action.")
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        disappears(picker)
    }

    @MainActor private func galleryPhoto(_ picker: XCUIElement) -> XCUIElement {
        // iOS26 Photos exposes grid assets as Images beneath its scroll view, rather
        // than UICollectionView cells. Scope to photo labels to exclude its header icon.
        picker.images.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Foto,", "Photo,")).firstMatch
    }

    @MainActor private func selectGalleryAsset(_ asset: XCUIElement) {
        // Photos' image proxy has a real visible frame but no XCTest activation hit
        // point on iOS26. Tap the center of that observed asset, as a person would.
        XCTAssertGreaterThan(asset.frame.width, 0)
        XCTAssertGreaterThan(asset.frame.height, 0)
        asset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor func testNativeGalleryCancelAndSelectedPhotoKeepDraftWithoutSending() throws {
        let app = app()
        let chat = app.buttons["native.conversation.fixture-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let composer = element(app, "native.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Galerie Entwurf")
        let picker = openGallery(app)
        capture(app, "Native Photos and videos picker")
        try cancelGallery(picker)
        XCTAssertEqual(composer.value as? String, "Galerie Entwurf")
        XCTAssertFalse(element(app, "native.composer.attachment").exists)

        let reopenedPicker = openGallery(app)
        let photo = galleryPhoto(reopenedPicker)
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "The owned test Simulator is seeded with a public Yapper image.")
        selectGalleryAsset(photo)
        let attachment = element(app, "native.composer.attachment")
        XCTAssertTrue(attachment.waitForExistence(timeout: 20))
        XCTAssertEqual(composer.value as? String, "Galerie Entwurf")
        XCTAssertTrue(app.buttons["native.send"].isEnabled)
        capture(app, "Selected gallery image ready to attach — no send")
        let selectedAttachment = attachment.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(selectedAttachment.isEmpty)
        try cancelGallery(openGallery(app))
        XCTAssertTrue(attachment.exists)
        XCTAssertEqual(attachment.staticTexts.allElementsBoundByIndex.map(\.label), selectedAttachment)
        XCTAssertEqual(composer.value as? String, "Galerie Entwurf")
        app.buttons["native.composer.attachment.remove"].tap()
        disappears(attachment)
        XCTAssertEqual(composer.value as? String, "Galerie Entwurf")
    }

    @MainActor func testNativeGallerySelectedVideoKeepsDraftWithoutSending() throws {
        let app = app()
        let chat = app.buttons["native.conversation.fixture-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let composer = element(app, "native.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Video Entwurf")
        let picker = openGallery(app)
        let video = picker.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Video,")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "The owned Simulator is seeded with the one-second synthetic gallery video.")
        selectGalleryAsset(video)
        let attachment = element(app, "native.composer.attachment")
        XCTAssertTrue(attachment.waitForExistence(timeout: 20))
        let labels = attachment.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.hasSuffix(".mp4") || $0.hasSuffix(".mov") })
        XCTAssertEqual(composer.value as? String, "Video Entwurf")
        XCTAssertTrue(app.buttons["native.send"].isEnabled)
        capture(app, "Selected gallery video ready to attach — no send")
        app.buttons["native.composer.attachment.remove"].tap()
        disappears(attachment)
        XCTAssertEqual(composer.value as? String, "Video Entwurf")
    }

    @MainActor func testOwnStatusPickerUpdatesBannerAndPreservesManualInvisible() throws {
        let app = app()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(account.label.contains("Online"))
        account.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Online")).firstMatch.tap()
        let invisible = app.buttons.matching(NSPredicate(format: "label == %@", "Unsichtbar")).firstMatch
        XCTAssertTrue(invisible.waitForExistence(timeout: 5))
        invisible.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Unsichtbar"), object: account)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        capture(app, "Own saved invisible status remains explicit")
    }
}
