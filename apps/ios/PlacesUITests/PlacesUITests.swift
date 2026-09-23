import XCTest

@MainActor final class PlacesUITests: XCTestCase {
    func testCombinedHomeCanSplitAndMergeWithoutLosingCorrections() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-grouped-history"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        let visits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-stay-"))
        XCTAssertEqual(visits.count, 1)
        reveal(visits.firstMatch, in: app); visits.firstMatch.tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["3 entries combined"].exists)
        reveal(app.buttons["split-entries"], in: app); app.buttons["split-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 3)
        let corrected = visits.element(boundBy: 1)
        reveal(corrected, in: app); corrected.tap()
        XCTAssertTrue(app.staticTexts["Your correction"].exists)
        reveal(app.buttons["merge-entries"], in: app); app.buttons["merge-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One combined Home visit"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testUnrecordedIntervalHasEndpointsAndConsentGatedMap() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-grouped-history"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Between recorded locations"].exists)
        XCTAssertTrue(app.staticTexts["Earlier location"].exists)
        XCTAssertTrue(app.staticTexts["Home"].exists)
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["Done"].tap()
        app.buttons["tab-map"].tap(); app.buttons["enable-apple-maps"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        app.buttons["tab-timeline"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Dashed lines link known endpoints; they aren’t a recorded route."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["endpoint-A"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["endpoint-B"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Known endpoints with an unrecorded path"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].tap()
        app.buttons["open-settings"].tap()
        reveal(app.switches["maps-toggle"], in: app)
        let mapsSwitch = app.switches["maps-toggle"]
        XCTAssertEqual(mapsSwitch.value as? String, "1")
        mapsSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(mapsSwitch.value as? String, "0")
        app.buttons["Done"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    private func launch(fixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (fixture ? ["--ui-fixture"] : [])
        app.launch()
        return app
    }

    func testSkipAllPermissionsAndMapConsent() {
        let app = launch()
        XCTAssertTrue(app.buttons["skip-setup"].waitForExistence(timeout: 10))
        app.buttons["skip-setup"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        app.buttons["tab-map"].tap()
        XCTAssertTrue(app.buttons["enable-apple-maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["tab-places"].tap()
        app.buttons["tab-map"].tap()
        XCTAssertTrue(app.buttons["enable-apple-maps"].exists)
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testNormalFirstLaunchOpensProtectedStorage() {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["skip-setup"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Unlock to open your history"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testManualPlaceAndLocalSearchWithoutLocationPermission() {
        let app = launch()
        XCTAssertTrue(app.buttons["skip-setup"].waitForExistence(timeout: 10))
        app.buttons["skip-setup"].tap(); app.buttons["tab-places"].tap()
        app.buttons["add-place"].tap()
        reveal(app.buttons["enter-coordinates"], in: app)
        app.buttons["enter-coordinates"].tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Fixture Garden")
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        reveal(app.textFields["place-latitude"], in: app)
        app.textFields["place-latitude"].tap(); app.textFields["place-latitude"].typeText("0")
        app.buttons["dismiss-keyboard"].tap()
        reveal(app.textFields["place-longitude"], in: app)
        app.textFields["place-longitude"].tap(); app.textFields["place-longitude"].typeText("0")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Garden"].waitForExistence(timeout: 5))
        app.buttons["tab-search"].tap()
        let search = app.textFields["local-search"]; search.tap(); search.typeText("Garden")
        XCTAssertTrue(app.staticTexts["Fixture Garden"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testDesignFixtureAndSettings() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Timeline with synthetic history"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.switches["maps-toggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["maps-toggle"].value as? String, "0")
    }

    func testEveryOnboardingPermissionCanBeSkipped() {
        let app = launch()
        XCTAssertTrue(app.buttons["onboarding-skip"].waitForExistence(timeout: 10))
        for _ in 0..<7 {
            if app.buttons["onboarding-skip"].exists { app.buttons["onboarding-skip"].tap() }
        }
        XCTAssertTrue(app.staticTexts["Not enabled"].exists)
        app.buttons["onboarding-primary"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
    }

    func testMapsAreRemovedWhenConsentIsRevoked() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["tab-map"].waitForExistence(timeout: 10))
        app.buttons["tab-map"].tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["enable-apple-maps"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["disable-apple-maps"].exists)
        app.buttons["open-settings"].tap()
        reveal(app.switches["maps-toggle"], in: app)
        let mapsSwitch = app.switches["maps-toggle"]
        XCTAssertEqual(mapsSwitch.value as? String, "1")
        mapsSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(mapsSwitch.value as? String, "0")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["enable-apple-maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["tab-timeline"].tap(); app.buttons["tab-map"].tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testAccessibilitySizeKeepsNavigationUsable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-timeline"].waitForExistence(timeout: 10))
        for tab in ["map", "places", "search", "timeline"] {
            XCTAssertTrue(app.buttons["tab-\(tab)"].isHittable)
            app.buttons["tab-\(tab)"].tap()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Timeline at largest accessibility text size"; screenshot.lifetime = .keepAlways; add(screenshot)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .trait])
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    func testLocationContinueRequiresAccessButNotNowSkips() {
        let app = launch()
        app.buttons["onboarding-primary"].tap()
        app.buttons["onboarding-primary"].tap()
        app.buttons["onboarding-primary"].tap()
        XCTAssertTrue(app.staticTexts["location-validation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.staticTexts["A little movement context"].exists)
        app.buttons["onboarding-skip"].tap()
        app.buttons["preset-home"].tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Home")
        app.buttons["Cancel"].tap()
        app.buttons["preset-work"].tap()
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Work")
    }

    func testEditorHidesCoordinatesUntilMapsAreDeclinedAndSearchesIconAliases() {
        let app = launch(fixture: true)
        app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
        XCTAssertFalse(app.textFields["place-latitude"].exists)
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["choose-place-icon"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("work")
        XCTAssertTrue(app.buttons["icon-briefcase.fill"].waitForExistence(timeout: 5))
        app.buttons["icon-briefcase.fill"].tap()
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 5))
        reveal(app.buttons["enter-coordinates"], in: app)
        app.buttons["enter-coordinates"].tap()
        XCTAssertTrue(app.textFields["place-latitude"].exists)
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testWiFiNamesHaveRowsAndConfirmedSwipeRemoval() {
        let app = launch(fixture: true)
        app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
        reveal(app.textFields["wifi-name"], in: app)
        app.textFields["wifi-name"].tap(); app.textFields["wifi-name"].typeText("Fixture Guest")
        app.buttons["add-wifi"].tap()
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        let row = app.staticTexts["Fixture Guest"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["Remove Wi-Fi name"].waitForExistence(timeout: 5))
        app.buttons["Remove Wi-Fi name"].tap()
        XCTAssertFalse(row.exists)
    }

    func testEditorCreatesMapOnlyAfterConsentAndSavesSelectedPin() {
        let app = launch(fixture: true)
        app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
        let name = app.textFields["place-name"]
        name.tap(); name.typeText("Fixture Pin")
        app.buttons["dismiss-keyboard"].tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
        reveal(app.buttons["editor-enable-maps"], in: app)
        app.buttons["editor-enable-maps"].tap()
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        reveal(map, in: app)
        map.tap()
        XCTAssertTrue(app.staticTexts["Tap the map to move your pin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["place-latitude"].exists)
        // Start outside the map so this scrolls the form instead of panning tiles.
        app.buttons["use-current-location"].swipeUp()
        let radius = app.sliders["Recognition radius in metres"]
        reveal(radius, in: app)
        radius.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertFalse(app.staticTexts["100 m"].exists)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Pin"].waitForExistence(timeout: 5))
    }

    func testResetRequiresConfirmationAndReturnsToEmptyOnboarding() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["tab-places"].tap()
        XCTAssertTrue(app.staticTexts["Home"].exists)
        app.buttons["tab-timeline"].tap()
        app.buttons["open-settings"].tap()
        reveal(app.buttons["reset-all-data"], in: app)
        app.buttons["reset-all-data"].tap()
        XCTAssertTrue(app.buttons["Delete all data and restart"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["reset-all-data"].exists)
        app.buttons["reset-all-data"].tap()
        app.buttons["Delete all data and restart"].tap()
        XCTAssertTrue(app.buttons["skip-setup"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["skip-setup"].tap()
        app.buttons["tab-places"].tap()
        XCTAssertFalse(app.staticTexts["Home"].exists)
        app.buttons["add-place"].tap()
        XCTAssertTrue(app.buttons["editor-enable-maps"].exists)
        XCTAssertFalse(app.textFields["place-latitude"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["tab-map"].tap()
        XCTAssertTrue(app.buttons["enable-apple-maps"].exists)
    }

    func testTestCaseExportExplainsExpectedResultsAndOpensFilePicker() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        reveal(app.buttons["export-test-case"], in: app)
        app.buttons["export-test-case"].tap()
        XCTAssertTrue(app.buttons["Export test case"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "expected result")).firstMatch.exists)
        app.buttons["Export test case"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Places-test-case")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Test case file export"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTransportChoicesAndManualFerryCorrection() {
        let app = launch(fixture: true)
        let cycling = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Cycled")).firstMatch
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        reveal(cycling, in: app); cycling.tap()
        let menu = app.buttons["change-transport"]
        reveal(menu, in: app); menu.tap()
        XCTAssertTrue(app.buttons["transport-ferry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Car"].exists)
        XCTAssertTrue(app.buttons["Public transport"].exists)
        XCTAssertTrue(app.buttons["Plane"].exists)
        XCTAssertFalse(app.buttons["Drove"].exists)
        XCTAssertFalse(app.buttons["Took the train"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Suggested")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Ranked transport choices"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["transport-ferry"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        let ferry = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Ferry")).firstMatch
        reveal(ferry, in: app); ferry.tap()
        XCTAssertTrue(app.staticTexts["Your correction"].waitForExistence(timeout: 5))
    }

    func testCreatePlaceFromVisitAssignsItThroughBothEntryPoints() {
        for withSavedPlace in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-unnamed-stay"] + (withSavedPlace ? ["--ui-saved-place"] : [])
            app.launch()
            let stay = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch
            XCTAssertTrue(stay.waitForExistence(timeout: 10)); stay.tap()
            XCTAssertEqual(app.buttons["assign-place"].label, "Name this place")
            if withSavedPlace {
                reveal(app.buttons["choose-saved-place"], in: app)
                app.buttons["choose-saved-place"].tap()
                XCTAssertTrue(app.buttons["Fixture Existing"].waitForExistence(timeout: 5))
                app.buttons["create-assigned-place"].tap()
            } else {
                app.buttons["assign-place"].tap()
                XCTAssertFalse(app.staticTexts["Choose a place"].exists)
            }
            let name = app.textFields["place-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Using this visit’s location"].exists)
            XCTAssertFalse(app.maps.firstMatch.exists)
            XCTAssertFalse(app.textFields["place-latitude"].exists)
            name.tap(); name.typeText("Fixture Corner")
            app.buttons["save-place"].tap()
            XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
            let assigned = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Corner")).firstMatch
            XCTAssertTrue(assigned.waitForExistence(timeout: 5)); assigned.tap()
            XCTAssertTrue(app.staticTexts["Your correction"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Name this place"].exists)
        }
    }

}
