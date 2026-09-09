#if canImport(XCTest)
  import XCTest

  final class AIFileOrganizerUITests: XCTestCase {
    @MainActor
    func testFirstLaunchShowsWorkspaceSetup() {
      let app = XCUIApplication()
      app.launchArguments = ["-ui-testing-reset", "-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      XCTAssertTrue(app.staticTexts["整理收件箱，不打乱你的生活"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons["完成设置"].exists)
    }
  }
#endif
