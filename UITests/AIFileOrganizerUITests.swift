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

    @MainActor
    func testProgressPanelShowsStageCountsAndStopAction() {
      let app = XCUIApplication()
      app.launchArguments = [
        "-ui-testing-reset", "-ui-testing-progress-demo", "-ApplePersistenceIgnoreState", "YES",
      ]
      app.launch()

      XCTAssertTrue(app.groups["organization-progress-panel"].waitForExistence(timeout: 5))
      XCTAssertEqual(
        app.staticTexts["organization-progress-title"].value as? String,
        "正在分析内容"
      )
      XCTAssertEqual(
        app.staticTexts["organization-progress-value"].value as? String,
        "37 / 120"
      )
      XCTAssertTrue(app.buttons["organization-progress-stop"].exists)
    }
  }
#endif
