import XCTest

@MainActor final class PlacesUITests: XCTestCase {
    func testGapCanBePartiallyAssignedToSavedPlace() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-grouped-history"]
        app.launch()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.tap()
        app.buttons["assign-place"].tap()
        let arrival = app.datePickers["visit-arrival"]
        XCTAssertTrue(arrival.waitForExistence(timeout: 5))
        arrival.buttons.element(boundBy: 2).tap()
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "10")
        app.buttons["PopoverDismissRegion"].tap()
        app.datePickers["visit-departure"].buttons.element(boundBy: 2).tap()
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "20")
        app.buttons["PopoverDismissRegion"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Choose missing visit times"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["choose-saved-place"].tap()
        let home = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "saved-place-", "Home")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5)); home.tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 8))
        let gaps = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-"))
        XCTAssertTrue(gaps.firstMatch.label.contains("10 min"))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-stay-")).firstMatch.tap()
        app.buttons["edit-entry"].tap(); app.buttons["split-entries"].tap()
        // Same-place grouping retains the actual correction and the untouched gap.
        let originals = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "original-entry-"))
        XCTAssertTrue(originals.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(originals.element(boundBy: 0).label.contains("0:10 – 0:20"))
        XCTAssertTrue(originals.element(boundBy: 1).label.contains("0:20 – 0:30"))
        XCTAssertTrue(originals.element(boundBy: 1).label.contains("Unrecorded interval"))
    }

    func testExistingPlaceAppearanceSearchSelectionPersists() {
        let app = launch(fixture: true)
        app.buttons["tab-places"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Home")).firstMatch.tap()
        app.buttons["edit-place-details"].tap()
        reveal(app.buttons["choose-place-icon"], in: app); app.buttons["choose-place-icon"].tap()
        let search = app.textFields["place-icon-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Park")
        let park = app.buttons["icon-tree.fill"]
        XCTAssertTrue(park.waitForExistence(timeout: 5)); XCTAssertTrue(park.isHittable)
        // Tap the pictogram itself, not just the text or the accessibility activation point.
        park.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(park.isSelected)
        XCTAssertEqual(search.value as? String, "Park", "Selecting must not exit search and rebuild the unfiltered picker")
        XCTAssertTrue(app.buttons["save-place-appearance"].isHittable)
        let selected = XCTAttachment(screenshot: app.screenshot()); selected.name = "Park selected from icon search"; selected.lifetime = .keepAlways; add(selected)
        app.buttons["save-place-appearance"].tap()
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Park"))
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["edit-place-details"].waitForExistence(timeout: 8)); app.buttons["edit-place-details"].tap()
        XCTAssertTrue(app.buttons["choose-place-icon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Park"), "The appearance must survive saving and reopening an existing place")
        app.buttons["choose-place-icon"].tap()
        app.textFields["place-icon-search"].tap(); app.textFields["place-icon-search"].typeText("work")
        app.buttons["icon-briefcase.fill"].tap()
        app.navigationBars["Appearance"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["choose-place-icon"].label.contains("Park"), "Cancelling must retain the saved appearance")
    }

    func testPlaceMergeKeepsCurrentEditsAndSharedDetails() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["tab-map"].waitForExistence(timeout: 10))
        app.buttons["tab-map"].tap(); enableAppleMaps(in: app)
        app.buttons["tab-places"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Home")).firstMatch.tap()
        XCTAssertTrue(app.buttons["edit-place-details"].waitForExistence(timeout: 5))
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Shared place details with recognition area"; detail.lifetime = .keepAlways; add(detail)
        app.buttons["edit-place-details"].tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(" edited")
        app.buttons["dismiss-keyboard"].tap()
        reveal(app.buttons["choose-place-icon"], in: app); app.buttons["choose-place-icon"].tap()
        XCTAssertTrue(app.buttons["place-color-4"].waitForExistence(timeout: 5)); app.buttons["place-color-4"].tap()
        app.buttons["save-place-appearance"].tap()
        reveal(app.buttons["merge-place"], in: app); app.buttons["merge-place"].tap()
        XCTAssertTrue(app.buttons["merge-with-demo-cafe"].waitForExistence(timeout: 5)); app.buttons["merge-with-demo-cafe"].tap()
        XCTAssertTrue(app.buttons["confirm-place-merge"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirm-place-merge"].firstMatch.label.contains("Home edited"))
        let merge = XCTAttachment(screenshot: app.screenshot()); merge.name = "Merge keeps current edits"; merge.lifetime = .keepAlways; add(merge)
        app.buttons["confirm-place-merge"].firstMatch.tap()
        XCTAssertTrue(app.buttons["edit-place-details"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Home edited"].firstMatch.exists)
        app.buttons["tab-places"].tap()
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "A little coffee stop")).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Home edited")).firstMatch.exists)
    }

    func testCustomPlaceColorFavoritesCanBeReusedAndRemoved() {
        let app = launch(fixture: true)
        app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
        reveal(app.buttons["choose-place-icon"], in: app); app.buttons["choose-place-icon"].tap()
        XCTAssertTrue(app.colorWells["custom-place-color"].waitForExistence(timeout: 5))
        app.colorWells["custom-place-color"].coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Spectrum"].waitForExistence(timeout: 5)); app.buttons["Spectrum"].tap()
        let picker = XCTAttachment(screenshot: app.screenshot()); picker.name = "Native color spectrum"; picker.lifetime = .keepAlways; add(picker)
        app.buttons["Grid"].tap(); app.otherElements["white 100"].tap(); app.buttons["close"].tap()
        XCTAssertTrue(app.buttons["favorite-place-color"].isEnabled); app.buttons["favorite-place-color"].tap()
        app.buttons["save-place-appearance"].tap()
        app.buttons["choose-place-icon"].tap()
        app.scrollViews["place-color-swatches"].swipeLeft()
        let favorite = app.buttons["Favorite color FFFFFF"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5)); favorite.tap()
        let colors = XCTAttachment(screenshot: app.screenshot()); colors.name = "Reusable custom color favorite"; colors.lifetime = .keepAlways; add(colors)
        XCTAssertEqual(app.buttons["favorite-place-color"].label, "Remove favorite")
        app.buttons["favorite-place-color"].tap()
        XCTAssertTrue(favorite.waitForNonExistence(timeout: 5))
    }

    func testPastVisitsReviewCancellationAndConfirmedAdditionBeforeHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-past-visits"]
        app.launch()
        let addPast = app.buttons["add-past-visits"]
        XCTAssertTrue(addPast.waitForExistence(timeout: 10))
        let entry = XCTAttachment(screenshot: app.screenshot()); entry.name = "Add past visits before recorded history"; entry.lifetime = .keepAlways; add(entry)
        addPast.tap()
        XCTAssertTrue(app.datePickers["past-visit-departure"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Set departure"].exists)
        XCTAssertFalse(app.buttons["Use departure time"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(addPast.waitForExistence(timeout: 5))
        addPast.tap()
        XCTAssertTrue(app.datePickers["past-visit-departure"].waitForExistence(timeout: 5))
        let review = XCTAttachment(screenshot: app.screenshot()); review.name = "Editable arrival and departure"; review.lifetime = .keepAlways; add(review)
        app.buttons["confirm-past-visits"].tap()
        XCTAssertTrue(app.buttons["next-suggestion"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["suggestion-saved"].label, "Visits and memory added")
        let saved = XCTAttachment(screenshot: app.screenshot()); saved.name = "Add another suggestion after saving"; saved.lifetime = .keepAlways; add(saved)
        app.buttons["next-suggestion"].tap()
        XCTAssertTrue(app.buttons["confirm-past-visits"].waitForExistence(timeout: 5))
        app.buttons["confirm-past-visits"].tap()
        XCTAssertTrue(app.buttons["next-suggestion"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Garden"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Fixture Café"].exists)
        XCTAssertFalse(app.buttons["add-past-visits"].exists)
        let added = XCTAttachment(screenshot: app.screenshot()); added.name = "Both confirmed visits on timeline"; added.lifetime = .keepAlways; add(added)
        app.buttons["tab-places"].tap()
        app.staticTexts["Fixture Garden"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Photo 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["apple-memory-suggestions"].exists)
        app.buttons["tab-timeline"].tap()
        let suggestions = app.buttons["apple-memory-suggestions"]
        reveal(suggestions, in: app); suggestions.tap()
        XCTAssertTrue(app.staticTexts["Already added"].waitForExistence(timeout: 5))
    }

    func testTimelineOffersAppleSuggestionsAndPlaceDeletionKeepsMemories() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-past-visits"]
        app.launch()
        XCTAssertTrue(app.buttons["add-past-visits"].waitForExistence(timeout: 10))
        app.buttons["add-past-visits"].tap()
        XCTAssertTrue(app.buttons["confirm-past-visits"].waitForExistence(timeout: 5))
        app.buttons["confirm-past-visits"].tap()
        XCTAssertTrue(app.buttons["next-suggestion"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        let suggestions = app.buttons["apple-memory-suggestions"]
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5))
        app.buttons["tab-places"].tap()
        app.staticTexts["Fixture Garden"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Photo 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["apple-memory-suggestions"].exists)
        reveal(app.buttons["Edit place"], in: app); app.buttons["Edit place"].tap()
        let remove = app.buttons["delete-place"]
        reveal(remove, in: app); remove.tap()
        XCTAssertTrue(app.sheets.buttons["Delete place"].waitForExistence(timeout: 5))
        app.sheets.buttons["Delete place"].tap()
        XCTAssertTrue(app.staticTexts["Your places"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Fixture Garden"].exists)
        app.buttons["tab-timeline"].tap()
        let photo = app.buttons["Photo 1"]
        reveal(photo, in: app)
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        XCTAssertTrue(app.navigationBars["1 of 1"].waitForExistence(timeout: 5))
    }

    func testOnboardingReusesPastVisitsReviewWithoutSavingOnCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-skip"].waitForExistence(timeout: 10))
        for _ in 0..<5 { app.buttons["onboarding-skip"].tap() }
        let addPast = app.buttons["add-past-visits"]
        XCTAssertTrue(addPast.waitForExistence(timeout: 5))
        addPast.tap()
        XCTAssertTrue(app.buttons["confirm-past-visits"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(addPast.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture Garden"].exists)
    }

    func testMonthlyRewindReviewAndStory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-rewind"]
        app.launch()
        XCTAssertTrue(app.buttons["open-rewind"].waitForExistence(timeout: 10))
        app.buttons["open-rewind"].tap()
        XCTAssertTrue(app.buttons["rewind-review"].waitForExistence(timeout: 8))
        let intro = XCTAttachment(screenshot: app.screenshot()); intro.name = "Monthly rewind invitation"; intro.lifetime = .keepAlways; add(intro)
        app.buttons["rewind-review"].tap()
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review-entry-"))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 8))
        entries.firstMatch.tap()
        XCTAssertTrue(app.buttons["assign-place"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["show-rewind"].waitForExistence(timeout: 5))
        app.buttons["show-rewind"].tap()
        XCTAssertTrue(app.staticTexts["rewind-place-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["rewind-place-count"].label, "2")
        let card = XCTAttachment(screenshot: app.screenshot()); card.name = "Monthly rewind places card"; card.lifetime = .keepAlways; add(card)
        app.buttons["rewind-next"].tap()
        XCTAssertTrue(app.staticTexts["A familiar\nfavourite."].waitForExistence(timeout: 5))
        app.buttons["Previous"].tap()
        XCTAssertEqual(app.staticTexts["rewind-progress"].label, "1 of 6")
        for _ in 0..<5 { app.buttons["rewind-next"].tap() }
        XCTAssertTrue(app.staticTexts["The little\nthings stay."].waitForExistence(timeout: 5))
        let end = XCTAttachment(screenshot: app.screenshot()); end.name = "Monthly rewind memories card"; end.lifetime = .keepAlways; add(end)
        app.buttons["rewind-next"].tap()
        XCTAssertTrue(app.buttons["show-rewind"].waitForExistence(timeout: 5))
        app.buttons["rewind-month"].tap()
        app.buttons[Date().formatted(.dateTime.month(.wide).year())].tap()
        XCTAssertTrue(app.staticTexts["A fresh page"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["show-rewind"].exists)
    }

    func testRewindLargeTextKeepsControlsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-rewind", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["open-rewind"].waitForExistence(timeout: 10))
        app.buttons["open-rewind"].tap()
        let start = app.buttons["show-rewind"]
        reveal(start, in: app); start.tap()
        XCTAssertTrue(app.buttons["rewind-next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rewind-next"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Rewind with accessibility text"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["rewind-next"].tap()
        XCTAssertEqual(app.staticTexts["rewind-progress"].label, "2 of 6")
    }

    func testRewindRemindersDefaultOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let monthly = app.switches["monthly-rewind-reminder"]
        reveal(monthly, in: app)
        XCTAssertEqual(monthly.value as? String, "0")
        let weekly = app.switches["weekly-review-reminder"]
        reveal(weekly, in: app)
        XCTAssertEqual(weekly.value as? String, "0")
        weekly.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: weekly)], timeout: 5), .completed)
        weekly.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(weekly.value as? String, "0")
    }

    func testMainTabReturnsToPeopleAndDeletingPersonLeavesNoBlankPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["People"].tap()
        app.buttons["Alex"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit person"].waitForExistence(timeout: 5))
        app.buttons["tab-places"].tap()
        XCTAssertTrue(app.staticTexts["Your people"].waitForExistence(timeout: 5))
        app.buttons["Alex"].firstMatch.tap()
        app.buttons["Edit person"].tap()
        reveal(app.buttons["Delete person"], in: app); app.buttons["Delete person"].tap()
        app.sheets.buttons["Delete person"].tap()
        XCTAssertTrue(app.staticTexts["Your people"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Alex"].exists)
        XCTAssertTrue(app.buttons["add-person"].isHittable)
    }

    func testPhotoBrowserPagingZoomCaptionMapSharingAndReordering() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-photo-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons["trip-photo-trip"].tap()
        let first = app.buttons["Photo 1"]
        reveal(first, in: app); first.tap()
        XCTAssertTrue(app.navigationBars["1 of 9"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["photo-created-at"].exists)
        let zoom = app.scrollViews["zoomable-memory-photo"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5)); zoom.doubleTap()
        XCTAssertEqual(zoom.value as? String, "Zoomed")
        zoom.doubleTap()
        app.otherElements["memory-photo-pager"].swipeLeft()
        XCTAssertTrue(app.navigationBars["2 of 9"].waitForExistence(timeout: 5))
        app.otherElements["memory-photo-pager"].swipeLeft()
        XCTAssertTrue(app.navigationBars["3 of 9"].waitForExistence(timeout: 5))
        app.otherElements["memory-photo-pager"].swipeRight()
        XCTAssertTrue(app.navigationBars["2 of 9"].waitForExistence(timeout: 5))
        app.buttons["photo-caption"].tap()
        XCTAssertTrue(app.textFields["photo-caption-input"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Previous photo"].tap()
        XCTAssertTrue(app.navigationBars["1 of 9"].waitForExistence(timeout: 5))
        app.buttons["photo-caption"].tap()
        let caption = app.textFields["photo-caption-input"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5)); caption.tap(); caption.typeText("Morning by the water")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["photo-caption"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["photo-caption"].label, "Morning by the water")
        app.buttons["photo-location"].tap()
        XCTAssertTrue(app.buttons["choose-maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["apple-map"].exists)
        app.navigationBars["Photo location"].buttons["Done"].tap()
        app.buttons["export-memory-photo"].tap()
        app.buttons["Share photo"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
        app.navigationBars["1 of 9"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForNonExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Paged photo browser with caption and creation date"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
        let edit = app.buttons["Edit memory"].firstMatch
        reveal(edit, in: app); edit.tap()
        XCTAssertTrue(app.navigationBars["Memory"].waitForExistence(timeout: 5))
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "draft-photo-", "Photo 1")).firstMatch
        reveal(photo, in: app); photo.press(forDuration: 1)
        app.buttons["Reorder photos"].tap()
        XCTAssertTrue(app.navigationBars["Photo order"].waitForExistence(timeout: 5))
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder"))
        XCTAssertTrue(handles.element(boundBy: 1).exists)
        handles.element(boundBy: 0).press(forDuration: 0.5, thenDragTo: handles.element(boundBy: 1))
        let order = XCTAttachment(screenshot: app.screenshot()); order.name = "Native photo reorder handles"; order.lifetime = .keepAlways; add(order)
        app.buttons["Date order"].tap()
        app.navigationBars["Photo order"].buttons["Done"].tap()
        XCTAssertFalse(app.buttons["Remove photo"].exists)
        photo.press(forDuration: 1); app.buttons["Delete photo"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete photo"].waitForExistence(timeout: 5))
        // Compact native confirmations dismiss by tapping outside the popover.
        app.navigationBars["Memory"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete photo"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(photo.exists)
        app.buttons["save-memory"].tap()
        let lastPlace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seaside stay, View visits")).firstMatch
        reveal(lastPlace, in: app)
        XCTAssertTrue(lastPlace.isHittable)
        XCTAssertLessThan(lastPlace.frame.maxY, app.buttons["tab-places"].frame.minY)
        let bottom = XCTAttachment(screenshot: app.screenshot()); bottom.name = "Trip final place clear of floating navigation"; bottom.lifetime = .keepAlways; add(bottom)
    }

    func testAutomaticTripMemoryAndPeopleFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 10)); trip.tap()
        XCTAssertTrue(app.staticTexts["Breakfast by the sea"].waitForExistence(timeout: 5))
        app.buttons["edit-trip"].tap()
        app.buttons["trip-people"].tap()
        let alex = app.buttons["Alex"].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: 5)); alex.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["save-trip"].tap()
        app.buttons["add-memory"].tap()
        let note = app.textViews["memory-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("A lovely week together")
        app.buttons["memory-people"].tap()
        let name = app.textFields["new-person-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Sam")
        app.buttons["create-memory-person"].tap()
        XCTAssertTrue(app.buttons["Sam"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["save-memory"].tap()
        XCTAssertTrue(app.staticTexts["A lovely week together"].waitForExistence(timeout: 8))
        let tripShot = XCTAttachment(screenshot: app.screenshot()); tripShot.name = "Automatic trip and memories"; tripShot.lifetime = .keepAlways; add(tripShot)
        // A new trip memory inherits its companions.
        app.buttons["Alex"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Trips together"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Breakfast by the sea"].exists)
        XCTAssertTrue(app.staticTexts["A lovely week together"].exists)
        let personShot = XCTAttachment(screenshot: app.screenshot()); personShot.name = "Private person and shared trips"; personShot.lifetime = .keepAlways; add(personShot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["edit-trip"].tap()
        let title = app.textFields["trip-name"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.press(forDuration: 1)
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        else { title.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        title.typeText("Our island trip")
        app.buttons["save-trip"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Our island trip")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["add-trip"].tap()
        app.textFields["trip-name"].tap(); app.textFields["trip-name"].typeText("Weekend away")
        app.buttons["save-trip"].tap()
        let weekend = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "trip-", "Weekend away")).firstMatch
        XCTAssertTrue(weekend.waitForExistence(timeout: 5)); weekend.tap()
        XCTAssertTrue(app.staticTexts["A trip worth remembering"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["add-memory"].isHittable)
        let empty = XCTAttachment(screenshot: app.screenshot()); empty.name = "A first trip memory"; empty.lifetime = .keepAlways; add(empty)
    }

    func testSelectedPhotoSavesDisplaysAndDeletesLocally() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch.tap()
        app.buttons["add-memory"].tap()
        app.buttons["add-memory-photos"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addPhoto = app.navigationBars["Photos"].buttons["Done"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5)); addPhoto.tap()
        let save = app.buttons["save-memory"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        save.tap()
        let saved = app.buttons["Photo 1"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Locally saved photo"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
        app.buttons["Edit memory"].firstMatch.tap()
        let delete = app.buttons["Delete memory"]
        reveal(delete, in: app); delete.tap()
        app.sheets.buttons["Delete memory"].tap()
        XCTAssertTrue(app.buttons["add-memory"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Photo 1"].exists)
    }

    func testNativePhotoPickerCanBeCancelledWithoutSavingAMemory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch.tap()
        app.buttons["add-memory"].tap()
        app.buttons["add-memory-photos"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        let picker = XCTAttachment(screenshot: app.screenshot()); picker.name = "System selected photos picker"; picker.lifetime = .keepAlways; add(picker)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["save-memory"].exists)
        XCTAssertFalse(app.buttons["save-memory"].isEnabled)
    }

    func testPhotoSelectionSurvivesHistoryRefreshesAndReopening() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories", "--ui-memory-refresh"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch.tap()
        app.buttons["add-memory"].tap()
        let note = app.textViews["memory-note"]
        note.tap(); note.typeText("A photo selection to keep")
        app.buttons["add-memory-photos"].tap()
        let thumbnails = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(thumbnails.element(boundBy: 2).waitForExistence(timeout: 10))
        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "Picker before selection with active history updates"; opened.lifetime = .keepAlways; add(opened)
        for index in 0..<3 {
            thumbnails.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let until = Date().addingTimeInterval(3)
            let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= until }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 5), .completed)
            XCTAssertTrue(app.navigationBars["Photos"].exists)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Photo selection during history refreshes"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForNonExistence(timeout: 8))
        reveal(app.buttons["add-memory-photos"], in: app)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draft-photo-"))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in photos.count == 3 }, object: nil)], timeout: 20), .completed)
        XCTAssertEqual(note.value as? String, "A photo selection to keep")
        reveal(app.buttons["add-memory-photos"], in: app); app.buttons["add-memory-photos"].tap()
        let cancelPicker = app.navigationBars["Photos"].buttons["Cancel"]
        XCTAssertTrue(cancelPicker.waitForExistence(timeout: 10)); cancelPicker.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(photos.count, 3)
        app.buttons["save-memory"].tap()
        XCTAssertTrue(app.buttons["Photo 3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Photo 4"].exists)
        app.buttons["Edit memory"].firstMatch.tap()
        XCTAssertEqual(photos.count, 3)
        // Each grid action removes only its own photo, including inside a Form row.
        let removeSecond = photos.element(boundBy: 1)
        reveal(removeSecond, in: app); removeSecond.press(forDuration: 1)
        app.buttons["Delete photo"].tap()
        app.sheets.buttons["Delete photo"].tap()
        XCTAssertEqual(photos.count, 2)
        app.buttons["save-memory"].tap()
        XCTAssertTrue(app.buttons["Photo 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Photo 3"].exists)
    }

    func testCroppedPhotosForPlacesAndTrips() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-photo-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.buttons.containing(.staticText, identifier: "Seaside stay").firstMatch.tap()
        app.buttons["edit-place-details"].tap()
        reveal(app.buttons["choose-place-icon"], in: app); app.buttons["choose-place-icon"].tap()
        app.buttons["choose-place-photo"].tap()
        app.buttons["choose-crop-photo"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["use-photo-crop"].waitForExistence(timeout: 15))
        app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.2)
        app.buttons["use-photo-crop"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10))
        app.buttons["save-place-appearance"].tap()
        app.navigationBars["Edit place"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["edit-place-details"].waitForExistence(timeout: 10))
        let savedPlace = XCTAttachment(screenshot: app.screenshot()); savedPlace.name = "Place with cropped photo"; savedPlace.lifetime = .keepAlways; add(savedPlace)
        app.buttons["edit-place-details"].tap()
        reveal(app.buttons["choose-place-icon"], in: app); app.buttons["choose-place-icon"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 5))
        app.buttons["Remove photo"].tap()
        app.navigationBars["Appearance"].buttons["Cancel"].tap()
        app.buttons["choose-place-icon"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 5), "Cancel must keep the photo")
        app.buttons["Remove photo"].tap(); app.buttons["save-place-appearance"].tap()
        app.navigationBars["Edit place"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["edit-place-details"].waitForExistence(timeout: 10))
        app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons["trip-photo-trip"].tap(); app.buttons["edit-trip"].tap()
        app.buttons["choose-trip-photo"].tap()
        let suggested = app.buttons["Suggested photo 1"]
        XCTAssertTrue(suggested.waitForExistence(timeout: 10)); suggested.tap()
        XCTAssertTrue(app.buttons["use-photo-crop"].waitForExistence(timeout: 5))
        app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.1)
        app.buttons["use-photo-crop"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10)); app.buttons["save-trip"].tap()
        XCTAssertTrue(app.buttons["trip-photo"].waitForExistence(timeout: 10))
        let savedTrip = XCTAttachment(screenshot: app.screenshot()); savedTrip.name = "Trip with cropped photo"; savedTrip.lifetime = .keepAlways; add(savedTrip)
        app.buttons["edit-trip"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 5))
        app.buttons["Remove photo"].tap(); app.buttons["save-trip"].tap()
        XCTAssertTrue(app.buttons["edit-trip"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["trip-photo"].exists)
    }

    func testMentionsAvatarCropAndAddingMorePhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10)); app.buttons["tab-places"].tap()
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch.tap()
        app.buttons["add-memory"].tap()
        let note = app.textViews["memory-note"]
        note.tap(); note.typeText("An afternoon with @Al")
        let alexSuggestion = app.buttons["mention-memory-friend"]
        XCTAssertTrue(alexSuggestion.waitForExistence(timeout: 5)); alexSuggestion.tap()
        XCTAssertFalse(app.buttons["create-mentioned-person"].exists)
        note.typeText("and @Robin")
        let create = app.buttons["create-mentioned-person"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); reveal(create, in: app); create.tap()
        XCTAssertTrue(app.buttons["add-memory-photos"].waitForExistence(timeout: 5))
        reveal(app.buttons["add-memory-photos"], in: app); app.buttons["add-memory-photos"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Photo 1"].waitForExistence(timeout: 15))
        app.buttons["save-memory"].tap()
        XCTAssertTrue(app.staticTexts["An afternoon with @Alex and @Robin "].waitForExistence(timeout: 8))
        let more = app.buttons["add-photos-to-memory"].firstMatch
        reveal(more, in: app); more.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForNonExistence(timeout: 8))
        reveal(app.buttons["add-memory-photos"], in: app)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draft-photo-"))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in photos.count == 2 }, object: nil)], timeout: 15), .completed)
        app.buttons["save-memory"].tap()
        XCTAssertTrue(app.buttons["Photo 2"].waitForExistence(timeout: 8))
        let memories = XCTAttachment(screenshot: app.screenshot()); memories.name = "Compact avatars and memory photo shortcut"; memories.lifetime = .keepAlways; add(memories)
        let alex = app.buttons["Alex"].firstMatch
        reveal(alex, in: app); alex.tap()
        app.buttons["Edit person"].tap()
        let description = app.textViews["person-description"]
        description.tap(); description.typeText("Friend of @Rob")
        let robin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "mention-", "Robin")).firstMatch
        XCTAssertTrue(robin.waitForExistence(timeout: 5)); reveal(robin, in: app); robin.tap()
        let choose = app.buttons["choose-person-avatar"]
        reveal(choose, in: app); choose.tap()
        let suggested = app.buttons["Suggested photo 1"]
        XCTAssertTrue(suggested.waitForExistence(timeout: 15)); suggested.tap()
        XCTAssertTrue(app.buttons["use-photo-crop"].waitForExistence(timeout: 5))
        app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.15)
        let crop = XCTAttachment(screenshot: app.screenshot()); crop.name = "Private square avatar crop"; crop.lifetime = .keepAlways; add(crop)
        app.buttons["use-photo-crop"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10))
        app.navigationBars["Person"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Friend of @Robin "].waitForExistence(timeout: 8))
        app.buttons["Edit person"].tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["person-description"].value as? String, "Friend of @Robin ")
        app.navigationBars["Person"].buttons["Cancel"].tap()
        let saved = XCTAttachment(screenshot: app.screenshot()); saved.name = "Person avatar and linked description"; saved.lifetime = .keepAlways; add(saved)
        app.links["@Robin"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Robin"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls["places-collection"].buttons["People"].tap()
        let people = XCTAttachment(screenshot: app.screenshot()); people.name = "People with photos and colored initials"; people.lifetime = .keepAlways; add(people)
    }

    func testDayStripFollowsRepeatedSwipesBeyondItsVisibleDates() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-history-navigation"]
        app.launch()
        let days = app.scrollViews["timeline-days"]
        XCTAssertTrue(days.waitForExistence(timeout: 10))
        XCTAssertEqual(days.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(days.frame.maxX, app.frame.maxX, accuracy: 1)
        let left = app.buttons["timeline-day--6"]
        XCTAssertTrue(left.isHittable); left.tap()
        let pager = app.scrollViews["timeline-pager"]
        for offset in 7...10 {
            pager.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.4)).withOffset(CGVector(dx: 60, dy: 0))
                .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            let selected = app.buttons["timeline-day--\(offset)"]
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: selected)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertGreaterThanOrEqual(selected.frame.minX, days.frame.minX - 1)
            XCTAssertLessThanOrEqual(selected.frame.maxX, days.frame.maxX + 1)
            XCTAssertTrue(selected.isHittable)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Day strip follows history beyond viewport"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["timeline-day--5"].tap()
        for offset in stride(from: 4, through: 2, by: -1) {
            pager.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.4)).withOffset(CGVector(dx: -60, dy: 0))
                .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            let selected = app.buttons["timeline-day--\(offset)"]
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: selected)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertGreaterThanOrEqual(selected.frame.minX, days.frame.minX - 1)
            XCTAssertLessThanOrEqual(selected.frame.maxX, days.frame.maxX + 1)
        }
    }

    func testRegionAndAllHistorySelectionsFrameTheirPlacesOnBothMaps() {
        for offline in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-map-periods"] + (offline ? ["--ui-on-device-map"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["tab-map"].waitForExistence(timeout: 10)); app.buttons["tab-map"].tap()
            if !offline { enableAppleMaps(in: app) }
            let picker = app.buttons["map-period-picker"]
            let mapSurface = app.descendants(matching: .any).matching(identifier: offline ? "on-device-map" : "apple-map").firstMatch
            XCTAssertTrue(mapSurface.waitForExistence(timeout: 10))
            XCTAssertEqual(mapSurface.frame.minX, app.frame.minX, accuracy: 1)
            XCTAssertEqual(mapSurface.frame.maxX, app.frame.maxX, accuracy: 1)
            // MapKit reports its unobscured viewport to accessibility, not its
            // rendered bounds. Screenshots below verify its edge-to-edge drawing.
            if offline {
                XCTAssertEqual(mapSurface.frame.minY, app.frame.minY, accuracy: 1)
                XCTAssertEqual(mapSurface.frame.maxY, app.frame.maxY, accuracy: 1)
            }
            let names = ["Fixture Kos West", "Fixture Kos East"]
            func checkVisible(_ expected: [String]) {
                for name in expected {
                    let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
                    XCTAssertTrue(pin.waitForExistence(timeout: 10), name)
                    // Nearby pins overlap at a continent-wide scale; validate the
                    // frame here and exercise an unobstructed pin separately below.
                    XCTAssertGreaterThan(pin.frame.width, 0)
                    XCTAssertGreaterThan(pin.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(pin.frame.minX, app.frame.minX)
                    XCTAssertLessThanOrEqual(pin.frame.maxX, app.frame.maxX)
                    XCTAssertGreaterThan(pin.frame.minY, app.buttons["open-settings"].frame.maxY - 1)
                    XCTAssertLessThan(pin.frame.maxY, picker.frame.minY + 1)
                }
            }
            picker.tap()
            let kos = app.buttons["suggested-period-Kos"].firstMatch
            reveal(kos, in: app); kos.tap()
            checkVisible(names)
            let region = XCTAttachment(screenshot: app.screenshot()); region.name = "Kos fit \(offline ? "offline" : "Apple")"; region.lifetime = .keepAlways; add(region)
            // Re-selecting the very same period must restore its frame after a pan.
            let map = offline ? app.otherElements["on-device-map"] : app.maps.firstMatch
            map.swipeLeft(velocity: .fast)
            picker.tap(); reveal(kos, in: app); kos.tap()
            checkVisible(names)
            picker.tap(); reveal(app.buttons["all-history-period"], in: app); app.buttons["all-history-period"].tap()
            checkVisible(names + ["Fixture Amsterdam West", "Fixture Amsterdam East"])
            let all = XCTAttachment(screenshot: app.screenshot()); all.name = "Amsterdam and Kos with routes \(offline ? "offline" : "Apple")"; all.lifetime = .keepAlways; add(all)
            picker.tap()
            XCTAssertTrue(app.staticTexts["To"].exists)
            let show = app.buttons["show-history-period"]
            XCTAssertTrue(show.isHittable)
            let range = XCTAttachment(screenshot: app.screenshot()); range.name = "Separate period action"; range.lifetime = .keepAlways; add(range)
            show.tap()
            XCTAssertTrue(picker.label.contains("Selected period"))
            picker.tap(); reveal(kos, in: app); kos.tap()
            let regionalPin = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", names[0])).firstMatch
            XCTAssertTrue(regionalPin.isHittable)
            regionalPin.tap()
            XCTAssertTrue(app.buttons["Edit place"].waitForExistence(timeout: 5), "A visible regional pin opens its place")
            app.terminate()
        }
    }

    func testUnknownIntervalOffersSamePlaceFromBothSidesAndSavesCorrection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-gap-suggestions"]
        app.launch()
        let gap = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch
        XCTAssertTrue(gap.waitForExistence(timeout: 10)); gap.tap()
        let home = app.buttons["adjacent-place-gap-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.label.contains("Before and after"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Same place on both sides of an unknown interval"; shot.lifetime = .keepAlways; add(shot)
        home.tap()
        XCTAssertTrue(app.staticTexts["timeline-heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-gap-")).firstMatch.exists)
    }

    func testCompactTimelineScrollsHistoryAndShowsCalendarAndBatteryActivity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-history-navigation"]
        app.launch()
        let heading = app.staticTexts["timeline-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.label.contains("you were"))
        let days = app.scrollViews["timeline-days"]
        XCTAssertTrue(days.exists)
        let yesterday = app.buttons["timeline-day--1"]
        XCTAssertEqual(yesterday.value as? String, "No history")
        XCTAssertEqual(app.buttons["timeline-day-0"].value as? String, "1 place")
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Compact timeline and visit dots"; initial.lifetime = .keepAlways; add(initial)
        days.swipeRight(velocity: .fast)
        XCTAssertFalse(app.buttons["timeline-day-0"].isHittable)
        app.buttons["Choose date"].tap()
        XCTAssertTrue(app.otherElements["history-calendar"].waitForExistence(timeout: 5))
        let calendar = XCTAttachment(screenshot: app.screenshot()); calendar.name = "Calendar available history and visit dots"; calendar.lifetime = .keepAlways; add(calendar)
        app.buttons["Cancel"].tap()
        app.buttons["open-settings"].tap(); app.buttons["battery-activity"].tap()
        XCTAssertTrue(app.staticTexts["Wi-Fi checks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Location callbacks"].exists)
        let battery = XCTAttachment(screenshot: app.screenshot()); battery.name = "Local battery and recording diagnostics"; battery.lifetime = .keepAlways; add(battery)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testWiFiPickerOffersOnlyNearbyNamesAndPreservesThePlaceDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-nearby-wifi"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 10))
        app.buttons["tab-places"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Hotel")).firstMatch.tap()
        reveal(app.buttons["Edit place"], in: app); app.buttons["Edit place"].tap()
        reveal(app.buttons["choose-wifi-network"], in: app)
        XCTAssertTrue(app.textFields["wifi-name"].exists)
        let editorShot = XCTAttachment(screenshot: app.screenshot()); editorShot.name = "05 Saved place - inline Wi-Fi"; editorShot.lifetime = .keepAlways; add(editorShot)
        app.buttons["choose-wifi-network"].tap()
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
        app.buttons["Done"].tap()
        let name = app.textFields["wifi-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        reveal(name, in: app)
        name.tap(); name.typeText("Fixture Extra")
        app.buttons["add-wifi"].tap()
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        XCTAssertTrue(app.staticTexts["Fixture Guest"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Garden"].exists)
        XCTAssertFalse(app.buttons["choose-wifi-network"].exists)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["Edit place"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Fixture Extra"], in: app)
        XCTAssertTrue(app.staticTexts["Fixture Extra"].exists)
        app.buttons["place-edit-wifi"].tap()
        XCTAssertTrue(app.navigationBars["Wi-Fi networks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["wifi-name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Guest"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Garden"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Extra"].exists)
        name.tap(); name.typeText("Unsaved network")
        app.buttons["add-wifi"].tap()
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        app.buttons["Cancel"].tap()
        reveal(app.buttons["place-edit-wifi"], in: app)
        app.buttons["place-edit-wifi"].tap()
        XCTAssertTrue(app.navigationBars["Wi-Fi networks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["wifi-name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Unsaved network"].exists)
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
        XCTAssertFalse(app.buttons["offline-suggestions-info"].exists)
        XCTAssertLessThan(app.staticTexts["visit-time-date"].frame.minY, name.frame.minY)
        XCTAssertLessThan(name.frame.minY, app.maps.firstMatch.frame.minY)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "visit-suggestion-")).count, 3)
        XCTAssertFalse(app.buttons["Mark as unknown"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Name and suggestions above map"; shot.lifetime = .keepAlways; add(shot)
        suggestion.tap()
        XCTAssertTrue(app.textFields["place-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Kos Airport “Ippokratis”")
        XCTAssertFalse(app.buttons["offline-suggestions-info"].exists)
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
        // The zone is measured in points, not a percentage of a particular iPhone.
        // Start beyond the old 44pt zone and move past halfway without flick inertia.
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45)).withOffset(CGVector(dx: 60, dy: 0))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: yesterday)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertEqual(today.frame.minX, todayFrame.minX, accuracy: 0.5, "Dates stay in place while the highlight moves")
        XCTAssertEqual(today.frame.width, todayFrame.width, accuracy: 0.5)
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
        reveal(app.buttons["Last 7 days"], in: app)
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

    func testInstalledMapRowOpensDetailAndSwipeRevealsTrash() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-fixture", "--ui-map-details", "--ui-installed-map-details"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10)); app.buttons["open-settings"].tap()
        reveal(app.buttons["map-settings"], in: app); app.buttons["map-settings"].tap()
        let row = app.buttons["map-pack-netherlands"]
        reveal(row, in: app); XCTAssertTrue(row.exists)
        XCTAssertFalse(app.buttons["Change detail"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        let compact = XCTAttachment(screenshot: app.screenshot()); compact.name = "Compact downloaded map row"; compact.lifetime = .keepAlways; add(compact)
        row.tap()
        XCTAssertTrue(app.buttons["map-detail-normal"].waitForExistence(timeout: 5)); assertSelected(app.buttons["map-detail-normal"])
        app.buttons["Cancel"].tap()
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        let swipe = XCTAttachment(screenshot: app.screenshot()); swipe.name = "Swipe map row to reveal trash"; swipe.lifetime = .keepAlways; add(swipe)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete Netherlands"].waitForExistence(timeout: 5))
        app.sheets.buttons["Delete Netherlands"].tap()
        XCTAssertTrue(app.buttons["download-map-netherlands"].waitForExistence(timeout: 5))
    }

    func testCountryDetailPickerUsesLocalPreviewsAndRetainsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-fixture", "--ui-map-details", "--ui-metered-maps"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        reveal(app.buttons["map-settings"], in: app); app.buttons["map-settings"].tap()
        reveal(app.buttons["download-map-netherlands"], in: app); app.buttons["download-map-netherlands"].tap()
        let normal = app.buttons["map-detail-normal"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5)); assertSelected(normal)
        let tiny = app.buttons["map-detail-tiny"]
        tiny.tap(); assertSelected(tiny)
        let extensive = app.buttons["map-detail-extensive"]
        reveal(extensive, in: app); extensive.tap(); assertSelected(extensive)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Three local Amsterdam map previews"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["download-selected-map"].tap()
        let confirmation = app.alerts["Download Netherlands?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Low Data Mode")).firstMatch.exists)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["map-detail-extensive"].isSelected)
        app.buttons["Cancel"].tap()
        for _ in 0..<3 where !app.buttons["map-provider-off"].exists { app.swipeDown() }
        XCTAssertTrue(app.buttons["map-provider-off"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["map-provider-off"].isSelected)
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
        app.buttons["assign-place"].tap()
        XCTAssertTrue(app.datePickers["visit-arrival"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["visit-departure"].exists)
        XCTAssertFalse(app.staticTexts["Using this visit’s location"].exists, "A gap endpoint is not the missing stop's location")
        app.buttons["Cancel"].tap()
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

    func testCompanionsRequireSeparateOptIn() {
        let app = launch(fixture: true)
        app.buttons["open-settings"].tap()
        let companions = app.buttons["Mac & Apple Watch"]
        reveal(companions, in: app); companions.tap()
        let watch = app.switches["Receive Watch locations"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        XCTAssertEqual(watch.value as? String, "0")
        let mac = app.switches["Receive Mac locations through iCloud"]
        XCTAssertEqual(mac.value as? String, "0")
        XCTAssertFalse(app.buttons["Check for Mac observations"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Companions stay off until chosen"; shot.lifetime = .keepAlways; add(shot)
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
            // Lazy forms expose slivers under both bars as hittable. Keep the
            // whole target below the active navigation bar and above the footer.
            let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? app.frame.minY
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= top && frame.maxY < app.frame.maxY - 110 { return }
                if frame.minY < top {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
                    continue
                }
            }
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
        let search = app.textFields["place-icon-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let iconShot = XCTAttachment(screenshot: app.screenshot()); iconShot.name = "Native icon catalog"; iconShot.lifetime = .keepAlways; add(iconShot)
        search.tap(); search.typeText("work")
        XCTAssertTrue(app.buttons["icon-briefcase.fill"].waitForExistence(timeout: 5))
        app.buttons["icon-briefcase.fill"].tap()
        app.buttons["save-place-appearance"].tap()
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
        XCTAssertFalse(app.staticTexts["Choose this place’s location to see networks recorded nearby."].exists)
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

    func testPlaceAreaDrawingOnBothMapProviders() {
        for offline in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-fixture"] + (offline ? ["--ui-on-device-map"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["tab-places"].waitForExistence(timeout: 15))
            if !offline { app.buttons["tab-map"].tap(); enableAppleMaps(in: app) }
            app.buttons["tab-places"].tap(); app.buttons["add-place"].tap()
            let name = app.textFields["place-name"]
            name.tap(); name.typeText("Fixture area")
            app.buttons["dismiss-keyboard"].tap()
            let choose = app.buttons["choose-place-area"]
            // Scroll the form margin to avoid panning the map inside it.
            for _ in 0..<10 {
                if choose.exists && choose.isHittable { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25)))
            }
            XCTAssertTrue(choose.isHittable); choose.tap()
            XCTAssertTrue(app.buttons["draw-place-area"].waitForExistence(timeout: 5))
            app.buttons["draw-place-area"].tap()
            let maps = offline ? app.otherElements.matching(identifier: "place-pin-map") : app.maps
            XCTAssertTrue(maps.firstMatch.waitForExistence(timeout: 10))
            // The parent editor's map remains underneath this sheet.
            let map = maps.allElementsBoundByIndex.last!
            let save = app.buttons["use-place-area"]
            XCTAssertFalse(save.isEnabled)
            for point in [(0.3, 0.35), (0.7, 0.35), (0.7, 0.65), (0.3, 0.65)] {
                map.coordinate(withNormalizedOffset: CGVector(dx: point.0, dy: point.1)).tap()
            }
            XCTAssertTrue(save.isEnabled)
            // MapLibre draws updated vector sources on its next renderer frame.
            Thread.sleep(forTimeInterval: 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Polygon drawing \(offline ? "on-device" : "Apple")"; screenshot.lifetime = .keepAlways; add(screenshot)
            save.tap()
            XCTAssertTrue(app.buttons["use-place-radius"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.sliders["Recognition radius in metres"].exists)
            app.buttons["save-place"].tap()
            XCTAssertTrue(app.staticTexts["Fixture area"].waitForExistence(timeout: 5))
            app.terminate()
        }
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
                if element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 110 { return }
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

    func testRestartOnboardingPreservesMemoriesAndPausedRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-memories"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let recording = app.switches["tracking-toggle"]
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        if recording.value as? String == "1" {
            recording.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: recording)], timeout: 5), .completed)
        reveal(app.buttons["restart-onboarding"], in: app)
        app.buttons["restart-onboarding"].tap()
        XCTAssertTrue(app.staticTexts["Your location history, for you."].waitForExistence(timeout: 5))
        app.buttons["skip-setup"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5))
        app.buttons["open-settings"].tap()
        XCTAssertEqual(recording.value as? String, "0")
        reveal(app.buttons["restart-onboarding"], in: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Restart onboarding in Settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["restart-onboarding"].tap()
        XCTAssertTrue(app.buttons["onboarding-skip"].waitForExistence(timeout: 5))
        // Review every step without requesting new permissions or changing settings.
        for _ in 0..<9 {
            if !app.buttons["onboarding-skip"].exists { break }
            app.buttons["onboarding-skip"].tap()
        }
        XCTAssertEqual(app.buttons["onboarding-primary"].label, "Done")
        app.buttons["onboarding-primary"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5))
        app.buttons["open-settings"].tap()
        XCTAssertEqual(recording.value as? String, "0")
        app.buttons["Done"].tap()
        app.buttons["tab-places"].tap()
        XCTAssertTrue(app.staticTexts["Seaside stay"].exists)
        app.segmentedControls["places-collection"].buttons["Trips"].tap()
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 5)); trip.tap()
        XCTAssertTrue(app.staticTexts["Breakfast by the sea"].waitForExistence(timeout: 5))
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
        reveal(app.buttons["editor-enable-maps"], in: app)
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

    func testGPXExportOpensSystemFilePicker() {
        let app = launch(fixture: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        reveal(app.buttons["export-gpx"], in: app)
        app.buttons["export-gpx"].tap()
        XCTAssertTrue(app.buttons["Export GPX"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "saved place names")).firstMatch.exists)
        app.buttons["Export GPX"].tap()
        let filename = app.textFields.matching(NSPredicate(format: "value == %@", "Places-history")).firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 15))
        XCTAssertTrue(filename.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "GPX file export"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTransportChoicesAndManualFerryCorrection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-transport-choices"]
        app.launch()
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
        XCTAssertTrue(app.buttons["transport-scooter"].exists)
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
