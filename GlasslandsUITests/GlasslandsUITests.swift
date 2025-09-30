//
//  GlasslandsUITests.swift
//  GlasslandsUITests
//
//  Created by . . on 9/29/25.
//
// Simple launch + pause/resume smoke test to catch regressions/crashes in the 3D view.
//

import XCTest

final class GlasslandsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndPauseResume() throws {
        let app = XCUIApplication()
        app.launch()

        // Pause via HUD button, then resume
        let pauseButton = app.buttons["Pause"]
        if pauseButton.waitForExistence(timeout: 5) {
            pauseButton.tap()
            let resumeButton = app.buttons["Resume"]
            XCTAssertTrue(resumeButton.waitForExistence(timeout: 2))
            resumeButton.tap()
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
