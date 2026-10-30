import XCTest

/// Taps through the browser like a person would and keeps screenshots of every step.
final class NovaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNewTabButtons() {
        let app = XCUIApplication()
        app.launchEnvironment = ["NOVA_SCENARIO": "page", "NOVA_URL": "https://de.wikipedia.org", "NOVA_BAR": "top"]
        app.launch()
        sleep(9)
        shot(app, "01-page")

        // 1. Tab overview → "+"
        let tabs = app.buttons["Tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Tabs-Knopf fehlt")
        tabs.tap()
        sleep(2)
        shot(app, "02-overview")
        let plus = app.buttons["Neuer Tab"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "Plus-Knopf fehlt")
        plus.tap()
        sleep(3)
        shot(app, "03-after-plus")
        app.typeText("apple.com\n")
        sleep(6)
        shot(app, "04-typed-address")

        // 2. Menu → "Neuer Tab"
        app.buttons["Mehr"].firstMatch.tap()
        sleep(2)
        shot(app, "05-menu")
        app.buttons["Neuer Tab"].firstMatch.tap()
        sleep(3)
        shot(app, "06-menu-new-tab")

        // 3. Long press on the tabs button → "Neuer Tab"
        app.buttons["Abbrechen"].firstMatch.tap()
        sleep(1)
        app.buttons["Tabs"].press(forDuration: 1.2)
        sleep(1)
        shot(app, "07-tabs-long-press")
        app.buttons["Neuer Tab"].firstMatch.tap()
        sleep(3)
        shot(app, "08-long-press-new-tab")

        // 4. Count in the overview
        app.buttons["Abbrechen"].firstMatch.tap()
        sleep(1)
        app.buttons["Tabs"].tap()
        sleep(2)
        shot(app, "09-overview-count")
    }
}
