import UIKit
import XCTest

/// Taps through the iOS app like a person does, on the offline fixture account: no Proton account, no network.
/// The app runs in English so the tests can find controls by their visible names.
final class MobileLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testLibraryShowsThePhotosOfTheAccount() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "the library grid shows no photo")
        XCTAssertTrue(app.buttons["Select"].exists)
    }

    func testAPhotoOpensInTheViewerAndClosesAgain() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        close.tap()

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")
    }

    /// Swiping down closes the viewer for a video too, also while its stream cannot play.
    func testSwipingDownOnAVideoClosesTheViewer() {
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 60), "the library grid shows no video")
        firstVideo.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))

        XCTAssertTrue(
            wait(for: app.buttons["Close"], "exists == false", timeout: 20), "swiping down did not close the viewer")
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 10), "the library did not return")
    }

    /// The viewer asks again silently after a rate limit and shows no message for it. A failure that a new attempt can
    /// change offers Try again, and one that no attempt changes offers none. The scenario argument makes the fixture
    /// rate-limit the first preparation, fail the second in a changeable way and every later one for good.
    func testTheFailedVideoOffersTryAgainOnlyWhenAnotherAttemptCanChangeIt() {
        app.terminate()
        app.launchArguments += ["-EncryptedMemoriesVideoFailureScenario"]
        app.launch()
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 60), "the library grid shows no video")
        firstVideo.tap()

        let tryAgain = app.buttons["Try again"]
        XCTAssertTrue(
            tryAgain.waitForExistence(timeout: 30), "a failure that a new attempt can change offers no Try again")
        XCTAssertTrue(app.staticTexts["The video couldn’t be played."].exists, "the silent retry did not run")
        XCTAssertFalse(app.staticTexts["Proton is busy right now."].exists, "the rate limit showed a message")

        tryAgain.tap()
        XCTAssertTrue(
            app.staticTexts["The video couldn’t be decrypted."].waitForExistence(timeout: 20),
            "Try again did not prepare the video again")
        XCTAssertFalse(app.buttons["Try again"].exists, "a failure that no new attempt changes still offers Try again")
    }

    func testTheAlbumButtonOfTheViewerAddsTheOpenPhotoToAnAlbum() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()

        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), "the viewer shows no album button")
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10), "the album list did not open")
        XCTAssertTrue(album.isEnabled, "the photo is in the album before it was added")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20), "adding the photo did not close the album list")

        // The album list opens again and marks the album that already holds the photo.
        addToAlbum.tap()
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: album, "isEnabled == false"), "the album does not hold the photo")
    }

    func testTheGridContextMenuOpensAndCancelsTheAlbumPicker() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).press(forDuration: 1.2)
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), "the context menu has no album action")
        addToAlbum.tap()
        let cancel = app.barButton(titled: "Cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the album picker did not open")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Grid context menu album picker hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(cancel.isHittable)
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the context menu list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        cancel.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "Cancel did not return to the library")
    }

    func testAlbumPickerShowsItsFirstAlbumWithoutScrolling() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the visible list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20))
    }

    func testAlbumPickerShowsItsEmptyStateWithoutScrolling() throws {
        app.terminate()
        app.launchArguments += ["-EncryptedMemoriesEmptyAlbumFixture"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let empty = app.staticTexts["No albums yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(.staticText, identifier: "No albums yet").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(empty.frame), "The empty state must fit inside the visible list")
        XCTAssertTrue(empty.isHittable, "The empty state must be visible without scrolling")
    }

    func testSelectionToolbarShowsTheFirstAlbumWithoutScrolling() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let column = try app.verticalTabColumn()
        app.barButton(titled: "Select").tap()
        try app.visiblePhoto(beside: column).tap()
        let addToAlbum = app.barButton(titled: "Add to Album")
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the visible selection list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20))
    }

    /// Every fixture photo is an edit with an original. The More menu shows the original, marks it with a badge, and
    /// returns to the edited version.
    func testTheViewerShowsTheOriginalOfAnEditedPhotoAndTheEditAgain() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let more = app.buttons.matching(NSPredicate(format: "label == 'More actions' OR label == 'More'")).firstMatch
        let showOriginal = app.buttons["Show Original"]
        // The viewer asks for the original once the photo stayed on screen and the app admits the ask, so the item
        // appears after a wait of unknown length, also while the library still loads on a slow runner.
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the viewer shows no More menu")
        more.tap()
        XCTAssertTrue(showOriginal.waitForExistence(timeout: 30), "the More menu offers no Show Original")
        showOriginal.tap()

        let badge = app.descendants(matching: .any)["Showing the original"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the original carries no badge")

        more.tap()
        let showEdited = app.buttons["Show Edited"]
        XCTAssertTrue(showEdited.waitForExistence(timeout: 10), "the More menu offers no Show Edited")
        showEdited.tap()
        XCTAssertTrue(wait(for: badge, "exists == false", timeout: 10), "the edited version still carries the badge")
    }

    func testSelectingPhotosShowsTheirActionsAndDoneEndsTheSelection() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let column = try app.verticalTabColumn()
        app.buttons["Select"].tap()
        let selectedPhoto = try app.visiblePhoto(beside: column)
        selectedPhoto.tap()

        XCTAssertTrue(wait(for: selectedPhoto, "isSelected == true"), "the tapped photo is not selected")
        XCTAssertTrue(app.buttons["Share selected items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move selected items to Trash"].isEnabled)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: selectedPhoto, "isSelected == false"), "Done must clear the selection")
    }

    func testTabsSwitchToCollectionsBackToTheLibraryAndToSearch() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))

        app.tab(titled: "Collections").tap()
        XCTAssertTrue(
            wait(for: firstPhoto, "exists == false", timeout: 20), "the library grid stays visible under Collections")

        app.tab(titled: "Library").tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")

        // The search tab turns the tab bar into a search field, so it comes last.
        app.tab(titled: "Search").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search shows no search field")
    }

    func testSearchTabActivatesAndReturnsToLibrary() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.tab(titled: "Search").tap()
        let field = app.searchFields.firstMatch
        let fieldExists = field.waitForExistence(timeout: 10)
        XCTAssertTrue(fieldExists, "Search tab must show a search field")
        guard fieldExists else { return }
        let keyboard = app.keyboards.firstMatch
        let keyboardExists = keyboard.waitForExistence(timeout: 10)
        XCTAssertTrue(keyboardExists, "Search tab must focus the keyboard")
        guard keyboardExists else { return }
        if UIDevice.current.userInterfaceIdiom == .phone {
            field.typeText("Spring")
        }
        let library = app.tab(titled: "Library")
        if UIDevice.current.userInterfaceIdiom == .pad {
            let openScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            openScreenshot.name = "Search open with keyboard"
            openScreenshot.lifetime = .keepAlways
            add(openScreenshot)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()
            XCTAssertTrue(wait(for: keyboard, "exists == false", timeout: 10), "Outside tap must hide keyboard")
            XCTAssertTrue(field.exists, "Search field must remain after the outside tap")
            let search = app.tab(titled: "Search")
            XCTAssertTrue(search.exists && search.isSelected, "Search tab must remain selected after outside tap")
            let outsideScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            outsideScreenshot.name = "Search after outside tap"
            outsideScreenshot.lifetime = .keepAlways
            add(outsideScreenshot)
            let ax = XCTAttachment(string: app.debugDescription)
            ax.name = "Search dismissal hierarchy"
            ax.lifetime = .keepAlways
            add(ax)
            let library = app.tab(titled: "Library")
            XCTAssertTrue(library.exists, "Library tab must exist to end search")
            guard library.exists else { return }
            let frame = library.frame
            let window = app.windows.firstMatch.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let safePoint = !frame.isEmpty && window.contains(point)
            XCTAssertTrue(safePoint, "Library tap point must be inside the window")
            guard safePoint else { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: point.x - window.minX, dy: point.y - window.minY)).tap()
            XCTAssertTrue(wait(for: library, "isSelected == true", timeout: 10), "Library must be selected")
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            let submit = keyboard.buttons.matching(
                NSPredicate(format: "label ==[c] 'Search' OR label ==[c] 'Return'")
            ).firstMatch
            let submitReady = submit.waitForExistence(timeout: 10) && submit.isHittable
            if !submitReady {
                let ax = XCTAttachment(string: app.debugDescription)
                ax.name = "Search submit hierarchy"
                ax.lifetime = .keepAlways
                add(ax)
            }
            XCTAssertTrue(submitReady, "Search or Return key must be reachable")
            guard submitReady else { return }
            submit.tap()
            if library.isHittable {
                library.tap()
            } else {
                let ax = XCTAttachment(string: app.debugDescription)
                ax.name = "Search dismissal hierarchy"
                ax.lifetime = .keepAlways
                add(ax)
                XCTAssertTrue(library.exists, "Library tab must exist to end search")
                guard library.exists else { return }
                let frame = library.frame
                let window = app.windows.firstMatch.frame
                let point = CGPoint(x: frame.midX, y: frame.midY)
                let keyboardVisible = keyboard.exists
                let keyboardFrame = keyboardVisible ? keyboard.frame : .zero
                // The iPhone probe measured a 6 pt gap below the keyboard at this midpoint.
                let distance = max(
                    keyboardFrame.minX - point.x, point.x - keyboardFrame.maxX,
                    keyboardFrame.minY - point.y, point.y - keyboardFrame.maxY)
                let safePoint =
                    !frame.isEmpty && window.contains(point)
                    && (!keyboardVisible || (!keyboardFrame.contains(point) && distance >= 4))
                XCTAssertTrue(safePoint, "Library tap point must be inside the window and clear of the keyboard")
                guard safePoint else { return }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: point.x - window.minX, dy: point.y - window.minY)).tap()
            }
        } else {
            XCTFail("Unsupported device idiom for search dismissal")
            return
        }
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "Library did not return")
        XCTAssertTrue(wait(for: app.searchFields.firstMatch, "exists == false", timeout: 10), "Search field remains")
        app.tab(titled: "Search").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search must reactivate")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Search must refocus the keyboard")
    }

    /// The end of the search suggestions scrolls clear of the bottom search field, so the Smart Search hint can be read
    /// with the keyboard up and with the keyboard down.
    func testTheSmartSearchHintScrollsAboveTheSearchField() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.tab(titled: "Search").tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search shows no search field")
        // The fixture account has Smart Search off, so the hint ends the suggestions.
        let hint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Turn on Smart Search'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 30), "the suggestions show no Smart Search hint")

        // Recent searches make the suggestions longer than the space above the keyboard.
        for query in ["Spring", "Winter", "Summer"] {
            searchField.tap()
            searchField.typeText(query + "\n")
            let clear = searchField.buttons.firstMatch
            if clear.waitForExistence(timeout: 5) { clear.tap() }
        }
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "the suggestions did not return after the searches")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is not up")

        scrollSuggestionsToTheEnd()
        XCTAssertLessThanOrEqual(
            hint.frame.maxY, searchField.frame.minY, "the search field above the keyboard covers the end of the list")

        // Dragging the list down dismisses the keyboard; the field returns to the tab bar.
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 550)))
        XCTAssertTrue(wait(for: app.keyboards.firstMatch, "exists == false", timeout: 20), "the keyboard did not close")
        scrollSuggestionsToTheEnd()
        XCTAssertLessThanOrEqual(
            hint.frame.maxY, searchField.frame.minY, "the search field in the tab bar covers the end of the list")
    }

    private func scrollSuggestionsToTheEnd() {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        }
        // The list bounces back to its end before the frames are compared.
        sleep(1)
    }

    func testReturningFromBackgroundRestoresTheViewerWithPreviewProtection() throws {
        app.terminate()
        app.launchArguments += ["-EncryptedMemories.blurAppPreview", "YES"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
    }

    func testPrivacyPreviewSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let previewSwitch = app.switches["Blur App Preview"]
        XCTAssertTrue(previewSwitch.waitForExistence(timeout: 5))
        let initialValue = try XCTUnwrap(previewSwitch.value as? String)
        XCTAssertEqual(initialValue, "1", "Blur App Preview defaults on")
        let changedValue = initialValue == "0" ? "1" : "0"
        previewSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: previewSwitch, "value == '\(changedValue)'"))

        app.backButton(to: "Settings").tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Blur App Preview"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(initialValue)'"))
    }

    func testPrivacySwitchHidesTheMapTab() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let geometry = XCTAttachment(string: app.debugDescription)
        geometry.name = "Map tab role and bar geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let mapTab = try app.verifiedTab(titled: "Map")
        let libraryTab = try app.verifiedTab(titled: "Library")
        XCTAssertTrue(mapTab.exists)

        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let mapSwitch = app.switches["Map and Places"]
        XCTAssertTrue(mapSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(mapSwitch.value as? String, "1")
        mapSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: mapSwitch, "value == '0'"))
        app.backButton(to: "Settings").tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(wait(for: mapTab, "exists == false", timeout: 20))
        XCTAssertTrue(libraryTab.exists)
    }

    func testRemoveLocationSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let removeLocationSwitch = app.switches["Remove location when sharing"]
        XCTAssertTrue(removeLocationSwitch.waitForExistence(timeout: 5))
        let originalValue = try XCTUnwrap(removeLocationSwitch.value as? String)
        XCTAssertEqual(originalValue, "1", "Remove location when sharing defaults on")
        removeLocationSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changedValue = originalValue == "0" ? "1" : "0"
        XCTAssertTrue(wait(for: removeLocationSwitch, "value == '\(changedValue)'"))

        app.backButton(to: "Settings").tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Remove location when sharing"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(originalValue)'"))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }

    /// Grid videos are named "Video, <date>".
    private var firstVideo: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video, '")).firstMatch
    }
}
