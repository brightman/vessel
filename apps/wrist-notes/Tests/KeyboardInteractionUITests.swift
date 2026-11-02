import XCTest

/// Runs against an already-installed WiseLife build, without changing records or model settings.
final class KeyboardInteractionUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "cloud.karama.wisenote")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["搜索记录"].waitForExistence(timeout: 20))
        if app.alerts.firstMatch.waitForExistence(timeout: 1), app.alerts.buttons["好"].exists { app.alerts.buttons["好"].tap() }
    }

    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, description, file: file, line: line)
    }

    func testSearchKeyboardHidesNavigationAndDismissesOutside() {
        app.buttons["搜索记录"].tap()
        let search = app.textFields["搜索想法、片段或关键词"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("keyboard draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        waitUntil("Bottom navigation must not sit above the search keyboard") { !self.app.buttons["一天"].exists }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Search keyboard"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.staticTexts["我的记录"].tap()
        waitUntil("Tapping outside the search field must dismiss the keyboard") { !self.app.keyboards.firstMatch.exists }
        XCTAssertTrue(app.buttons["一天"].exists)
        search.tap()
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Tapping the current input must keep editing")
        app.staticTexts["WiseLife"].tap()
        waitUntil("The page header also dismisses the keyboard") { !self.app.keyboards.firstMatch.exists }
        XCTAssertEqual(search.value as? String, "keyboard draft", "Dismissal must preserve the search text")
        search.tap()
        app.buttons["数据与设置"].tap()
        waitUntil("Navigation actions must dismiss without consuming the button action") { !self.app.keyboards.firstMatch.exists }
        XCTAssertTrue(app.staticTexts["设置"].exists)
        app.buttons["搜索记录"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search navigation must still autofocus")
    }

    func testAssistantUsesTheSameDismissalAndKeepsItsDraft() {
        app.buttons["AI"].tap()
        let field = app.textFields["daybook.assistant.question"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("assistant draft")
        waitUntil("AI keyboard hides bottom navigation") { !self.app.buttons["一天"].exists }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.staticTexts["WiseLife AI"].tap()
        waitUntil("Outside tap dismisses AI keyboard") { !self.app.keyboards.firstMatch.exists }
        XCTAssertTrue(app.buttons["一天"].exists)
        XCTAssertEqual(field.value as? String, "assistant draft")
        field.tap()
        app.buttons["搜索记录"].tap()
        XCTAssertTrue(app.textFields["搜索想法、片段或关键词"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Changing to search must retain the new field's focus")
        app.staticTexts["我的记录"].tap()
        waitUntil("Search focus can still dismiss after coming from AI") { !self.app.keyboards.firstMatch.exists }
        app.buttons["AI"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Returning to AI must not reopen the keyboard")
        XCTAssertEqual(field.value as? String, "assistant draft")
    }

    func testEditingSheetChangesFocusAndDismissesWithoutLosingText() {
        app.buttons["行动"].tap()
        app.buttons["新建行动"].tap()
        let title = app.textFields["行动内容"], notes = app.textFields["行动备注"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("keyboard draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        notes.tap(); notes.typeText("sheet notes")
        notes.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Switching or tapping a multiline input must keep editing")
        app.staticTexts["把重要的下一步放进你的行动里。"].tap()
        waitUntil("Outside tap must also work inside a presented sheet") { !self.app.keyboards.firstMatch.exists }
        XCTAssertEqual(title.value as? String, "keyboard draft")
        XCTAssertEqual(notes.value as? String, "sheet notes")
        notes.tap()
        app.buttons["关闭"].tap()
        waitUntil("Closing an editor must dismiss its keyboard") { !self.app.keyboards.firstMatch.exists }
        XCTAssertTrue(app.buttons["一天"].exists)
    }

    func testSettingsNumberPadDismissesOnOutsideTapAndScroll() {
        app.buttons["AI"].tap()
        app.buttons["daybook.assistant.models"].tap()
        let tokens = app.textFields["上下文窗口（tokens，可选）"]
        XCTAssertTrue(tokens.waitForExistence(timeout: 5))
        // No key or saved configuration is read or changed.
        tokens.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["AI 模型"].firstMatch.tap()
        waitUntil("A number pad must dismiss without a return key") { !self.app.keyboards.firstMatch.exists }
        tokens.tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.34))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.72)))
        waitUntil("Settings scrolling dismisses the keyboard interactively") { !self.app.keyboards.firstMatch.exists }
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["一天"].waitForExistence(timeout: 5))
    }
}
