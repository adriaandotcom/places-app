import XCTest

@MainActor final class PlacesUITests: XCTestCase {
    func testVisitNamingAndEvidenceAreImmediatelyAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-unnamed-stay", "--ui-saved-place"]
        app.launch()
        let stay = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch
        XCTAssertTrue(stay.waitForExistence(timeout: 10)); stay.tap()
        XCTAssertTrue(app.buttons["assign-place"].isHittable)
        XCTAssertTrue(app.staticTexts["visit-time-date"].exists)
        XCTAssertFalse(app.staticTexts["Why this appears here"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Last evidence:")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Mark as unknown"].exists)
        app.buttons["visit-evidence"].tap()
        XCTAssertTrue(app.staticTexts["Recorded observations"].waitForExistence(timeout: 5))
        let arrival = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Visit arrival")).firstMatch
        XCTAssertTrue(arrival.waitForExistence(timeout: 5)); arrival.tap()
        XCTAssertTrue(app.staticTexts["Location accuracy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "±10 m", "±10 m")).firstMatch.exists)
        let evidenceShot = XCTAttachment(screenshot: app.screenshot())
        evidenceShot.name = "Actual visit evidence"; evidenceShot.lifetime = .keepAlways; add(evidenceShot)
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["assign-place"].tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Unfinished draft")
        app.buttons["dismiss-keyboard"].tap()
        app.buttons["choose-saved-place"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertEqual(name.value as? String, "Unfinished draft")
        app.buttons["choose-saved-place"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Existing")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        let assigned = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Existing")).firstMatch
        XCTAssertTrue(assigned.waitForExistence(timeout: 5)); assigned.tap()
        XCTAssertTrue(app.staticTexts["Your correction"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["tab-places"].tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Fixture Existing").count, 1)
        XCTAssertFalse(app.staticTexts["Unfinished draft"].exists)
    }

    func testCompactVisitSuggestsVenueAboveConsentedMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-airport-stay"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        app.buttons["tab-map"].tap(); app.buttons["enable-apple-maps"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        app.buttons["tab-timeline"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch.tap()
        let name = app.buttons["assign-place"]
        let suggestion = app.buttons["visit-suggestion-b2ee52ea-3b09-439e-928b-bdbf168ded5e"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        XCTAssertTrue(name.isHittable)
        XCTAssertLessThan(app.staticTexts["visit-time-date"].frame.minY, name.frame.minY)
        XCTAssertLessThan(name.frame.minY, app.maps.firstMatch.frame.minY)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "visit-suggestion-")).count, 3)
        XCTAssertFalse(app.buttons["Mark as unknown"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Name and suggestions above map"; shot.lifetime = .keepAlways; add(shot)
        suggestion.tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Kos Airport “Ippokratis”")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.textFields["place-name"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["timeline-heading"].isHittable)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Kos Airport")).firstMatch.isHittable)
    }

    func testVisitNamingRemainsUsableAtAccessibilitySize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-unnamed-stay", "--ui-saved-place",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let stay = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch
        XCTAssertTrue(stay.waitForExistence(timeout: 10)); stay.tap()
        XCTAssertTrue(app.buttons["assign-place"].isHittable)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Visit detail at accessibility text size"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["assign-place"].tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        reveal(app.buttons["choose-saved-place"], in: app)
        XCTAssertTrue(app.buttons["choose-saved-place"].isHittable)
    }

    func testAirportSuggestionsAndSearchStayNearTheVisit() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-airport-stay"]
        app.launch()
        let stay = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch
        XCTAssertTrue(stay.waitForExistence(timeout: 10)); stay.tap()
        app.buttons["assign-place"].tap()
        let nearby = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nearby-catalog-"))
        XCTAssertTrue(nearby.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(nearby.firstMatch.label.contains("Kos Airport"))
        let suggestions = XCTAttachment(screenshot: app.screenshot())
        suggestions.name = "Main airport first in nearby suggestions"; suggestions.lifetime = .keepAlways; add(suggestions)
        app.buttons["find-catalog-place"].tap()
        let query = app.textFields["catalog-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("airport\n")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-result-"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(results.firstMatch.label.contains("Kos Airport"))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Schiphol")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Airport search scoped to 15 km"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["All regions"].tap()
        XCTAssertTrue(app.buttons["catalog-result-8499bdcc-37ee-4331-80be-57497c99e288"].waitForExistence(timeout: 5))
        app.buttons["Within 15 km"].tap()
        let airport = app.buttons["catalog-result-b2ee52ea-3b09-439e-928b-bdbf168ded5e"]
        XCTAssertTrue(airport.waitForExistence(timeout: 5)); airport.tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Kos Airport “Ippokratis”")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.textFields["place-name"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["timeline-heading"].isHittable)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Kos Airport")).firstMatch.isHittable)
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testOfflineCatalogSearchReviewSaveAndReuseWithoutMaps() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-unnamed-stay"]
        app.launch()
        let stay = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch
        XCTAssertTrue(stay.waitForExistence(timeout: 10)); stay.tap()
        app.buttons["assign-place"].tap()
        app.buttons["find-catalog-place"].tap()
        app.buttons["All regions"].tap()
        let query = app.textFields["catalog-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Rijksmuseum")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-result-"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
        let selectedID = results.firstMatch.identifier
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline Amsterdam results without Maps"; shot.lifetime = .keepAlways; add(shot)
        results.firstMatch.tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let chosen = name.value as! String
        XCTAssertTrue(chosen.contains("Rijksmuseum"))
        XCTAssertFalse(app.maps.firstMatch.exists)
        // Selecting is only a draft. Cancelling must leave the visit unnamed.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Somewhere new"].waitForExistence(timeout: 5))
        app.buttons["assign-place"].tap(); app.buttons["find-catalog-place"].tap()
        app.buttons["All regions"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Rijksmuseum")
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10)); results.firstMatch.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        let assigned = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", chosen)).firstMatch
        XCTAssertTrue(assigned.waitForExistence(timeout: 5)); assigned.tap()
        XCTAssertTrue(app.staticTexts["Your correction"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap(); app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
        app.buttons["find-catalog-place"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Rijksmuseum")
        XCTAssertTrue(app.buttons[selectedID].waitForExistence(timeout: 10)); app.buttons[selectedID].tap()
        XCTAssertTrue(app.buttons["Use saved place"].waitForExistence(timeout: 5)); app.buttons["Use saved place"].tap()
        XCTAssertTrue(app.buttons["add-place"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: chosen).count, 1)
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testOfflineCatalogKosWithoutPermissions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["skip-setup"].waitForExistence(timeout: 10)); app.buttons["skip-setup"].tap()
        app.buttons["tab-places"].tap(); app.buttons["add-place"].tap(); app.buttons["find-catalog-place"].tap()
        let query = app.textFields["catalog-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Hippocrates\n")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-result-"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline Kos results without permissions"; shot.lifetime = .keepAlways; add(shot)
        results.firstMatch.tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5)); app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["add-place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    func testDaySwipesMapPeriodsAndCityVisits() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        app.staticTexts["timeline-heading"].swipeRight()
        XCTAssertTrue(app.buttons["timeline-next-day"].isEnabled)
        app.buttons["timeline-next-day"].tap()
        XCTAssertFalse(app.buttons["timeline-next-day"].isEnabled)
        app.buttons["tab-map"].tap()
        app.buttons["enable-apple-maps"].tap()
        let picker = app.buttons["map-period-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.label.contains("Today"))
        XCTAssertTrue(picker.isHittable, picker.debugDescription)
        picker.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["map-previous-day"].tap()
        XCTAssertFalse(picker.label.contains("Today"))
        picker.swipeLeft()
        XCTAssertTrue(picker.label.contains("Today"))
        XCTAssertTrue(picker.isHittable, "After swipe: " + picker.debugDescription)
        picker.tap()
        XCTAssertTrue(app.buttons["Last 7 days"].waitForExistence(timeout: 5))
        app.buttons["Last 7 days"].tap()
        XCTAssertTrue(picker.label.contains("Last 7 days"))
        picker.tap()
        let city = app.buttons["suggested-period-Amsterdam"].firstMatch
        reveal(city, in: app); XCTAssertTrue(city.exists); city.tap()
        XCTAssertTrue(picker.label.contains("Amsterdam"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Map visit period with compact date navigation"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCityLookupNeedsSeparateOptInAndStopsWithMaps() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let lookup = app.buttons["City & country lookup"]
        reveal(lookup, in: app); lookup.tap()
        let toggle = app.switches["city-lookup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Enable city & country lookup"].waitForExistence(timeout: 5))
        app.buttons["Enable city & country lookup"].tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.navigationBars.buttons["BackButton"].tap()
        let maps = app.switches["maps-toggle"]
        reveal(maps, in: app); XCTAssertEqual(maps.value as? String, "1"); maps.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        reveal(lookup, in: app); lookup.tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testSelectiveSplitAndCancelPreserveCombinedStay() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-grouped-history"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        let visits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-stay-"))
        reveal(visits.firstMatch, in: app); visits.firstMatch.tap()
        app.buttons["edit-entry"].tap(); app.buttons["split-entries"].tap()
        XCTAssertTrue(app.buttons["select-all-originals"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirm-split-entries"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["3 entries combined"].exists)
        app.buttons["edit-entry"].tap(); app.buttons["split-entries"].tap()
        let originals = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "original-entry-"))
        XCTAssertTrue(originals.firstMatch.waitForExistence(timeout: 5))
        originals.firstMatch.tap()
        XCTAssertTrue(originals.firstMatch.isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Select original entries to separate"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["confirm-split-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 2)
    }

    func testLongHomeRecoveryShowsOneStayAndCanSplitAndMerge() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-wifi-recovery"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        let visits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-stay-"))
        let gaps = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-"))
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(gaps.count, 0)
        XCTAssertFalse(app.staticTexts["Between recorded locations"].exists)
        reveal(visits.firstMatch, in: app); visits.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["3 entries combined"].exists)
        app.buttons["edit-entry"].tap(); app.buttons["split-entries"].tap()
        XCTAssertTrue(app.buttons["select-all-originals"].waitForExistence(timeout: 5))
        app.buttons["select-all-originals"].tap(); app.buttons["confirm-split-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(gaps.count, 1)
        reveal(gaps.firstMatch, in: app); gaps.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["An unknown interval"].exists)
        XCTAssertFalse(app.staticTexts["Between recorded locations"].exists)
        app.buttons["edit-entry"].tap(); app.buttons["merge-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(gaps.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One Home stay across a Wi-Fi recovery gap"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

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
        app.buttons["edit-entry"].tap(); app.buttons["split-entries"].tap()
        XCTAssertTrue(app.buttons["select-all-originals"].waitForExistence(timeout: 5))
        app.buttons["select-all-originals"].tap(); app.buttons["confirm-split-entries"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(visits.count, 3)
        let corrected = visits.element(boundBy: 1)
        reveal(corrected, in: app); corrected.tap()
        XCTAssertTrue(app.staticTexts["Your correction"].exists)
        app.buttons["edit-entry"].tap(); app.buttons["merge-entries"].tap()
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
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
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
        // New nearby rows can push location controls out of the lazy form.
        // Scroll the form's outer margin without panning the map itself.
        func revealBelowMap(_ element: XCUIElement) {
            for _ in 0..<6 {
                if element.exists && element.isHittable { return }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.25)))
            }
        }
        let pinHint = app.staticTexts["Tap the map to move your pin"]
        revealBelowMap(pinHint)
        XCTAssertTrue(pinHint.exists)
        XCTAssertFalse(app.textFields["place-latitude"].exists)
        let radius = app.sliders["Recognition radius in metres"]
        revealBelowMap(radius)
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
        // The editable export name identifies the system picker regardless of its current folder.
        let filename = app.textFields.matching(NSPredicate(format: "value == %@", "Places-test-case")).firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 15))
        XCTAssertTrue(filename.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Test case file export"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTransportChoicesAndManualFerryCorrection() {
        let app = launch(fixture: true)
        let cycling = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Cycled")).firstMatch
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        reveal(cycling, in: app); cycling.tap()
        app.buttons["edit-entry"].tap()
        let menu = app.buttons["change-transport"]
        menu.tap()
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
            app.buttons["assign-place"].tap()
            if withSavedPlace {
                app.buttons["choose-saved-place"].tap()
                XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Existing")).firstMatch.waitForExistence(timeout: 5))
                app.navigationBars.buttons["BackButton"].tap()
            }
            let name = app.textFields["place-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
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
