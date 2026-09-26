import XCTest

@MainActor final class PlacesUITests: XCTestCase {
    func testWiFiPickerOffersOnlyNearbyNamesAndPreservesThePlaceDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-nearby-wifi"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10))
        app.buttons["tab-places"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Hotel")).firstMatch.tap()
        reveal(app.buttons["Edit place"], in: app); app.buttons["Edit place"].tap()
        let choose = app.buttons["choose-wifi-network"]
        reveal(choose, in: app); choose.tap()
        XCTAssertTrue(app.buttons["Add Fixture Guest"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Add Fixture Guest").count, 1)
        XCTAssertTrue(app.buttons["Add Fixture Garden"].exists)
        XCTAssertFalse(app.buttons["Add Other city"].exists)
        XCTAssertFalse(app.buttons["Add Already added"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Networks observed around this place"; screenshot.lifetime = .keepAlways; add(screenshot)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        reveal(app.buttons["Add Fixture Guest"], in: app)
        app.buttons["Add Fixture Guest"].tap()
        XCTAssertTrue(app.buttons["Add Fixture Guest"].waitForNonExistence(timeout: 5))
        app.buttons["Add Fixture Garden"].tap()
        app.buttons["enter-wifi-manually"].tap()
        let name = app.textFields["wifi-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Fixture Extra")
        app.buttons["add-wifi"].tap()
        app.buttons["dismiss-keyboard"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Guest"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Garden"].exists)
        XCTAssertFalse(app.buttons["choose-wifi-network"].exists)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["Edit place"].waitForExistence(timeout: 5))
        app.buttons["Edit place"].tap()
        reveal(app.textFields["wifi-name"], in: app)
        XCTAssertTrue(app.staticTexts["Fixture Guest"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Garden"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Extra"].exists)
    }

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
        app.buttons["tab-map"].tap(); enableAppleMaps(in: app)
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        app.buttons["tab-timeline"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Somewhere new")).firstMatch.tap()
        let name = app.buttons["assign-place"]
        let suggestion = app.buttons["visit-suggestion-b2ee52ea-3b09-439e-928b-bdbf168ded5e"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        XCTAssertTrue(name.isHittable)
        let edit = app.buttons["edit-entry"]
        XCTAssertLessThan(edit.frame.maxX, app.buttons["Done"].frame.minX, "Edit and Done have separate targets")
        app.buttons["offline-suggestions-info"].tap()
        XCTAssertTrue(app.staticTexts["Suggestions stay on your iPhone"].waitForExistence(timeout: 5))
        app.buttons["close-suggestions-info"].tap()
        XCTAssertLessThan(app.staticTexts["visit-time-date"].frame.minY, name.frame.minY)
        XCTAssertLessThan(name.frame.minY, app.maps.firstMatch.frame.minY)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "visit-suggestion-")).count, 3)
        XCTAssertFalse(app.buttons["Mark as unknown"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Name and suggestions above map"; shot.lifetime = .keepAlways; add(shot)
        suggestion.tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Kos Airport “Ippokratis”")
        XCTAssertTrue(app.buttons["offline-suggestions-info"].exists)
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Airport"))
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
        let today = app.buttons["timeline-day-0"]
        let yesterday = app.buttons["timeline-day--1"]
        let todayFrame = today.frame
        let headingFrame = app.staticTexts["timeline-heading"].frame
        let pager = app.scrollViews["timeline-pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        XCTAssertTrue(today.isSelected)
        let pagerShot = XCTAttachment(screenshot: app.screenshot()); pagerShot.name = "Pager initial"; pagerShot.lifetime = .keepAlways; add(pagerShot)
        // A drag from the middle is ordinary browsing, not a day change.
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(today.isSelected)
        XCTAssertFalse(app.buttons["edit-entry"].exists, "A horizontal middle drag must not open an entry")
        // A short edge drag settles back to the same day.
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(today.isSelected)
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: yesterday)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertEqual(today.frame, todayFrame, "Dates stay in their positions while the active date moves")
        XCTAssertEqual(app.staticTexts["timeline-heading"].frame.origin, headingFrame.origin)
        XCTAssertFalse(app.buttons["timeline-next-day"].exists)
        today.tap()
        XCTAssertTrue(today.isSelected)
        app.buttons["tab-map"].tap()
        enableAppleMaps(in: app)
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

    func testCityLookupAndMapsHaveIndependentConsentAndKeepSavedNames() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let toggle = app.switches["city-lookup-toggle"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let consent = app.alerts["Find city & country with Apple?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.buttons["Not now"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        consent.buttons["Enable lookup"].tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["Your places"].exists)
        reveal(app.buttons["map-settings"], in: app); app.buttons["map-settings"].tap()
        XCTAssertTrue(app.buttons["map-provider-off"].isSelected, "Enrichment must not enable map requests")
        app.buttons["map-provider-apple"].tap()
        app.buttons["Enable Apple Maps"].tap()
        assertSelected(app.buttons["map-provider-apple"])
        app.buttons["map-provider-off"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "Changing maps must not revoke separate enrichment consent")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        app.buttons["tab-places"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Home")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Amsterdam, Netherlands"].waitForExistence(timeout: 5), "Saved names survive disabling enrichment")
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
        app.buttons["tab-map"].tap(); enableAppleMaps(in: app)
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
        reveal(app.buttons["map-settings"], in: app); app.buttons["map-settings"].tap()
        assertSelected(app.buttons["map-provider-apple"])
        app.buttons["map-provider-off"].tap()
        assertSelected(app.buttons["map-provider-off"])
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
    }

    private func assertSelected(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)], timeout: 5), .completed)
    }

    private func enableAppleMaps(in app: XCUIApplication) {
        app.buttons["choose-maps"].tap()
        app.buttons["map-provider-apple"].tap()
        app.buttons["Enable Apple Maps"].tap()
        app.buttons["Done"].tap()
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
        XCTAssertTrue(app.buttons["choose-maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.maps.firstMatch.exists)
        app.buttons["tab-places"].tap()
        app.buttons["tab-map"].tap()
        XCTAssertTrue(app.buttons["choose-maps"].exists)
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
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Fixture Garden")
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        reveal(app.buttons["enter-coordinates"], in: app)
        app.buttons["enter-coordinates"].tap()
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
        XCTAssertFalse(app.buttons["Retry storage"].exists)
        XCTAssertFalse(app.staticTexts["Optional Apple service"].exists)
        reveal(app.buttons["map-settings"], in: app)
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Separate map and Apple service settings"; settings.lifetime = .keepAlways; add(settings)
        let about = app.buttons["about-places"]
        reveal(about, in: app); about.tap()
        XCTAssertTrue(app.buttons["Third-party licenses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Offline place data"].exists)
    }

    func testEveryOnboardingPermissionCanBeSkipped() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-skip"].waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if app.buttons["onboarding-skip"].exists { app.buttons["onboarding-skip"].tap() }
        }
        reveal(app.staticTexts["Not enabled"], in: app)
        XCTAssertTrue(app.staticTexts["Not enabled"].exists)
        app.buttons["onboarding-primary"].tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
    }

    func testMapsAreRemovedWhenConsentIsRevoked() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["tab-map"].waitForExistence(timeout: 10))
        app.buttons["tab-map"].tap()
        XCTAssertFalse(app.maps.firstMatch.exists)
        enableAppleMaps(in: app)
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["disable-apple-maps"].exists)
        app.buttons["open-settings"].tap()
        reveal(app.buttons["map-settings"], in: app); app.buttons["map-settings"].tap()
        assertSelected(app.buttons["map-provider-apple"])
        app.buttons["map-provider-off"].tap()
        assertSelected(app.buttons["map-provider-off"])
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["choose-maps"].waitForExistence(timeout: 5))
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
        let name = app.textFields["place-name"]
        name.tap(); name.typeText("Koffie aan de kade")
        app.buttons["dismiss-keyboard"].tap()
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Café"))
        app.buttons["choose-place-icon"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let iconShot = XCTAttachment(screenshot: app.screenshot()); iconShot.name = "Native icon catalog"; iconShot.lifetime = .keepAlways; add(iconShot)
        search.tap(); search.typeText("work")
        XCTAssertTrue(app.buttons["icon-briefcase.fill"].waitForExistence(timeout: 5))
        app.buttons["icon-briefcase.fill"].tap()
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 5))
        name.tap(); name.typeText(" market")
        app.buttons["dismiss-keyboard"].tap()
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Work"), "Typing never replaces an explicitly selected icon")
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
        app.buttons["map-provider-apple"].tap()
        app.buttons["Enable Apple Maps"].tap()
        app.navigationBars.buttons["BackButton"].tap()
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
        XCTAssertNotEqual(app.staticTexts["recognition-radius-value"].label, "100 m")
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
        XCTAssertTrue(app.buttons["choose-maps"].exists)
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
