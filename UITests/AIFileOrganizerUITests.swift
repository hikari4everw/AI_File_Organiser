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

    @MainActor
    func testDestinationBoardRulesAndHistoryNavigation() {
      let app = XCUIApplication()
      app.launchArguments = [
        "-ui-testing-reset", "-ui-testing-workspace-demo", "-ApplePersistenceIgnoreState", "YES",
      ]
      app.launch()

      XCTAssertTrue(app.buttons["整理计划"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["创作/音乐/乐谱"].exists)
      XCTAssertTrue(app.staticTexts["Moonlight Score.pdf"].exists)
      XCTAssertTrue(app.staticTexts["Moonlight Sonata.pdf"].exists)
      XCTAssertTrue(app.buttons["采用建议"].exists)
      app.buttons["我的规则"].click()
      XCTAssertTrue(app.staticTexts["用一句话描述你的整理习惯"].exists)
      XCTAssertTrue(app.staticTexts["命名规则"].exists)
      app.buttons["历史与撤销"].click()
      XCTAssertTrue(app.staticTexts["历史与撤销"].exists)
    }
  }
#endif
