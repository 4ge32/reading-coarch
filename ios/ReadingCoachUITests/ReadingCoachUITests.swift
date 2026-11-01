import XCTest

final class ReadingCoachUITests: XCTestCase {
    func testDemoReaderMarksWithoutOpeningTutor() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-memory"]
        app.launch()
        let sample = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Evidence and decisions")).firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let sentence = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sentence-")).firstMatch
        XCTAssertTrue(sentence.waitForExistence(timeout: 10))
        sentence.tap()
        XCTAssertEqual(sentence.value as? String, "マーク済み")
        XCTAssertFalse(app.textFields["今の解釈、質問、訂正した回答"].exists)
        sentence.tap()
        XCTAssertEqual(sentence.value as? String, "未マーク")
    }
}
