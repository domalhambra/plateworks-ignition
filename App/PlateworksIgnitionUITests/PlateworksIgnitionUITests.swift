import XCTest

/// Black-box UI smoke tests: navigation, the wet-bulb sling readout, and the
/// Obs capture/log loop, driven through the accessibility identifiers set on the
/// controls.
///
/// ### Why these look different from typical XCUITest code
///
/// Two things had to change before this suite could pass anywhere. Both were
/// invisible until the app target got a CI job — until then nothing ever ran it.
///
/// 1. **Element type is not part of the contract.** The old assertions queried
///    `app.staticTexts["result-Unshaded"]`, but `ResultCard` applies
///    `.accessibilityElement(children: .ignore)`, which resolves to an *other*
///    element, not static text. The identifier is the stable contract; which
///    `XCUIElementType` SwiftUI maps a view onto is an implementation detail
///    that changes with OS releases. ``element(_:)`` matches on identifier
///    alone, so a future SwiftUI reshuffle can't rot the suite the same way.
///
/// 2. **State leaks between tests.** UI tests share one simulator container, and
///    this app persists nearly everything — the shift log, retained history,
///    site factors, weather inputs. `testWatchTabLogsAnObservation` logs an
///    observation, which is exactly the state that breaks the empty-state
///    assertion on the *next* run. Every launch here passes the reset flag so
///    the app persists into a throwaway defaults suite and each test starts from
///    first-launch defaults.
final class PlateworksIgnitionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launch with a clean persistent store.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Keep in sync with AppEnvironment.resetStateArgument.
        app.launchArguments += ["-uiTestingResetState"]
        app.launch()
        return app
    }

    func testLaunchShowsBothPigResults() {
        let app = launchApp()
        // The Ignition tab shows both shaded and unshaded results on launch.
        XCTAssertTrue(app.element("result-Unshaded").waitForExistence(timeout: 10),
                      "Unshaded PIG result card missing on launch")
        XCTAssertTrue(app.element("result-Shaded").exists,
                      "Shaded PIG result card missing on launch")
        XCTAssertTrue(app.element("calc-chain").exists,
                      "Calculation chain strip missing on launch")
    }

    /// The shell is two tabs. A third would mean a screen came back without its
    /// spec — most likely a re-split of the humidity calculation the weather
    /// group now owns (`docs/UX_TWO_TAB.md` §4).
    func testShellHasExactlyTwoTabs() {
        let app = launchApp()
        XCTAssertTrue(app.tabBars.buttons["Ignition"].waitForExistence(timeout: 10),
                      "Ignition tab missing")
        XCTAssertTrue(app.tabBars.buttons["Obs"].exists, "Obs tab missing")
        XCTAssertEqual(app.tabBars.buttons.count, 2,
                       "Expected exactly two tabs — Ignition and Obs")
    }

    func testDryBulbIsAdjustable() {
        let app = launchApp()
        let dryBulb = app.element("Dry bulb")
        XCTAssertTrue(dryBulb.waitForExistence(timeout: 10), "Dry bulb stepper missing")
        // Adjustable element: a swipe up should increment without crashing.
        dryBulb.swipeUp()
        XCTAssertTrue(app.element("result-Unshaded").exists,
                      "PIG result stopped rendering after adjusting dry bulb")
    }

    /// Wet-bulb mode is where the absorbed Humidity screen lives: the wet-bulb
    /// stepper and the Alaska threshold switch in the weather group, and dew
    /// point and wet-bulb depression down in Sling detail. Direct mode shows
    /// none of it, which is what keeps the everyday screen short.
    ///
    /// The derived RH is deliberately *not* asserted on: it has no in-page
    /// readout any more. It repeated the pinned summary bar, which carries the
    /// effective RH in both modes — so the assertion for it lives on
    /// ``testPinnedSummaryCarriesTheSlingRH`` instead, where the value actually
    /// shows.
    func testWetBulbSourceRevealsTheFullSlingReading() {
        let app = launchApp()
        // Direct mode (the launch default) carries none of the sling extras.
        XCTAssertFalse(app.element("alaska-toggle").exists,
                       "Alaska toggle showing in direct mode")
        XCTAssertFalse(app.element("Dew point").exists,
                       "Sling detail showing in direct mode")
        XCTAssertFalse(app.element("WB depression").exists,
                       "Sling detail showing in direct mode")

        let wetBulbSource = app.element("From wet bulb")
        XCTAssertTrue(wetBulbSource.waitForExistence(timeout: 10),
                      "Humidity source chip missing")
        wetBulbSource.tap()

        XCTAssertTrue(app.element("Wet bulb").waitForExistence(timeout: 10),
                      "Wet bulb stepper did not appear")
        XCTAssertTrue(app.element("Dew point").exists,
                      "Dew point missing — it moved here from the Humidity tab")
        XCTAssertTrue(app.element("WB depression").exists,
                      "Wet-bulb depression missing — it moved here from the Humidity tab")
        XCTAssertTrue(app.element("alaska-toggle").exists,
                      "Alaska thresholds toggle missing in wet-bulb mode")
        XCTAssertTrue(app.element("result-Unshaded").exists,
                      "PIG result stopped rendering in wet-bulb mode")
    }

    /// The sling RH has exactly one on-screen home now that the weather group's
    /// readout is gone: the pinned summary bar. If that ever stops reflecting the
    /// wet-bulb computation, the number disappears from the app entirely — the
    /// failure this test exists to catch.
    func testPinnedSummaryCarriesTheSlingRH() {
        let app = launchApp()
        let summary = app.element("pig-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Pinned summary bar missing")

        let directValue = summary.value as? String
        app.element("From wet bulb").tap()
        XCTAssertTrue(app.element("Wet bulb").waitForExistence(timeout: 10),
                      "Wet bulb stepper did not appear")

        // The bar is one accessibility element whose value spells out the whole
        // reading, humidity included; switching source recomputes the RH, so the
        // spoken value has to move with it.
        let slingValue = summary.value as? String
        XCTAssertNotNil(slingValue, "Pinned summary carries no spoken value")
        XCTAssertNotEqual(directValue, slingValue,
                          "Pinned summary did not follow the switch to wet-bulb RH")
        XCTAssertTrue(slingValue?.contains("humidity") == true,
                      "Pinned summary stopped reporting humidity")
    }

    /// The Ignition tab carries the same start bar as Obs, so the capture flow
    /// can be entered from either tab. Gated, the tap lands on the Obs record
    /// (where Confirm site is) without opening the form; confirmed, the same
    /// handoff opens the capture sheet directly.
    func testIgnitionTabStartsAnObservationAcrossTheTabHandoff() {
        let app = launchApp()

        let startBar = app.element("start-observation")
        XCTAssertTrue(startBar.waitForExistence(timeout: 10),
                      "Start bar missing from the Ignition tab")
        startBar.tap()
        XCTAssertTrue(app.element("watch-empty").waitForExistence(timeout: 10),
                      "Gated start did not land on the Obs record")
        XCTAssertFalse(app.element("capture-sheet").exists,
                       "Capture sheet opened past the site gate")

        app.element("confirm-site").tap()
        app.tabBars.buttons["Ignition"].tap()
        XCTAssertTrue(startBar.waitForExistence(timeout: 10),
                      "Start bar missing after returning to Ignition")
        startBar.tap()
        XCTAssertTrue(app.element("capture-sheet").waitForExistence(timeout: 10),
                      "Start from Ignition did not open the capture sheet")
    }

    /// The whole hourly loop: open the capture form, read the receipt, commit,
    /// read the script, land back on the record with the reading as the hero.
    func testWatchTabLogsAnObservationThroughTheCaptureSheet() {
        let app = launchApp()

        app.tabBars.buttons["Obs"].tap()
        // Fresh shift shows the empty state until the first log.
        XCTAssertTrue(app.element("watch-empty").waitForExistence(timeout: 10),
                      "Obs tab did not start from an empty shift")

        // The first log of a shift is gated on an explicit site review.
        app.element("confirm-site").tap()

        // Capture is a sheet now, opened from the bottom bar.
        app.element("open-capture").tap()
        XCTAssertTrue(app.element("capture-sheet").waitForExistence(timeout: 10),
                      "Capture sheet did not open")
        XCTAssertTrue(app.element("pending-pig").exists, "Pending PIG preview missing")
        XCTAssertTrue(app.element("obs-note").exists, "Obs note field missing")
        XCTAssertTrue(app.element("Dry bulb").exists, "Dry bulb stepper missing in the capture sheet")
        XCTAssertTrue(app.element("freeze-receipt").exists,
                      "Freeze receipt missing above the commit button")

        // Committing freezes the reading and presents the script to read out.
        app.element("log-observation").tap()
        XCTAssertTrue(app.element("broadcast-success").waitForExistence(timeout: 10),
                      "Post-log broadcast script did not appear")
        XCTAssertTrue(app.element("copy-broadcast-success").exists,
                      "Post-log script has no Copy action")

        // Done returns to the record, with the new reading as the hero.
        app.element("log-done").tap()
        XCTAssertTrue(app.element("result-Unshaded").waitForExistence(timeout: 10),
                      "Logged obs hero did not appear")
        XCTAssertTrue(app.element("result-Shaded").exists,
                      "Logged obs hero is missing the shaded result")
        XCTAssertTrue(app.element("radio-line").exists,
                      "Logged obs hero is missing the radio line")
        XCTAssertFalse(app.element("watch-empty").exists,
                       "Empty state still showing after logging an observation")
    }

    /// The record scroll carries no weather entry — that all moved into the
    /// sheet, which is what keeps the most repeated action off the bottom of a
    /// long page.
    func testObsScrollIsRecordOnlyUntilCaptureOpens() {
        let app = launchApp()

        app.tabBars.buttons["Obs"].tap()
        XCTAssertTrue(app.element("open-capture").waitForExistence(timeout: 10),
                      "Capture entry point missing from the Obs tab")
        XCTAssertFalse(app.element("obs-note").exists,
                       "Note field is on the record scroll — capture should be in the sheet")
        XCTAssertFalse(app.element("freeze-receipt").exists,
                       "Freeze receipt is on the record scroll — it belongs at the commit")
    }

    /// The site factors that every logged obs freezes are visible where the
    /// operator is asked to confirm the site — they used to be Ignition-only
    /// while the gate still said "review the site factors".
    func testSiteFactorsAreVisibleOnTheObsTab() {
        let app = launchApp()

        app.tabBars.buttons["Obs"].tap()
        // ChipPicker identifies each chip by its label, so assert on the chips
        // themselves — "Below"/"Level"/"Above" and "31%+" are unique to these rows.
        XCTAssertTrue(app.element("Level").waitForExistence(timeout: 10),
                      "Elevation-delta chips missing from Site & radio")
        XCTAssertTrue(app.element("Above").exists,
                      "Elevation-delta chips missing from Site & radio")
        XCTAssertTrue(app.element("31%+").exists, "Slope chips missing from Site & radio")
        XCTAssertTrue(app.element("0–30%").exists, "Slope chips missing from Site & radio")
    }

    /// The GPS autofill button is present, and the hand-typed position fields sit
    /// alongside it — the override path stays available whether or not a
    /// simulator can produce a fix.
    func testSiteGPSButtonAndManualPositionCoexist() {
        let app = launchApp()

        app.tabBars.buttons["Obs"].tap()
        XCTAssertTrue(app.element("use-gps").waitForExistence(timeout: 10),
                      "GPS autofill button missing")
        XCTAssertTrue(app.element("Site elevation").exists,
                      "Site elevation field missing — that is the manual override path")
        XCTAssertTrue(app.element("Latitude").exists, "Latitude field missing")
        XCTAssertTrue(app.element("Longitude").exists, "Longitude field missing")
    }
}

private extension XCUIApplication {
    /// The element carrying this accessibility identifier, whatever element type
    /// SwiftUI resolved the view to.
    ///
    /// Querying a specific type (`staticTexts[...]`, `otherElements[...]`) bakes
    /// a SwiftUI implementation detail into the test: a view with
    /// `.accessibilityElement(children: .ignore)` surfaces as `.other`, a plain
    /// `Text` as `.staticText`, and which is which shifts between OS versions.
    /// The identifier is the part the app actually promises.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
