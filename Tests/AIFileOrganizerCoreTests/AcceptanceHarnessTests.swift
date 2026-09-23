import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct AcceptanceHarnessTests {
  private static func sampleManifestURL() -> URL {
    // 测试从仓库根目录运行；兼容 SwiftPM 的多种工作目录。
    var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<4 {
      let url = candidate.appendingPathComponent("Evaluation/acceptance/manifest.json")
      if FileManager.default.fileExists(atPath: url.path) { return url }
      candidate.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: "Evaluation/acceptance/manifest.json")
  }

  @Test func shippedSampleManifestParsesAndValidates() throws {
    let data = try Data(contentsOf: Self.sampleManifestURL())
    let manifest = try JSONDecoder().decode(AcceptanceManifest.self, from: data)
    #expect(manifest.version == 1)
    #expect(manifest.validationIssues().isEmpty)
    #expect(manifest.cases.allSatisfy { $0.id.hasPrefix("sample-") })
    // 示例里必须同时演示两档 split 与两种 group，否则格式文档会漂移。
    #expect(Set(manifest.cases.map(\.split)) == [.dev, .holdout])
    #expect(Set(manifest.cases.map(\.group)) == [.definiteDoujin, .confusable])
  }

  @Test func manifestValidationRejectsDuplicateIDsAndMissingCategory() {
    let manifest = AcceptanceManifest(description: "校验用", cases: [
      AcceptanceCase(id: "a", name: "[社 (作者)] 标题", group: .definiteDoujin, split: .holdout),
      AcceptanceCase(id: "a", name: "report.pdf", group: .confusable, split: .holdout),
      AcceptanceCase(id: "b", name: "x.pdf", group: .confusable, split: .holdout,
        relativePath: "/absolute/path.pdf"),
    ])
    let issues = manifest.validationIssues()
    #expect(issues.contains { $0.contains("id 重复") })
    #expect(issues.contains { $0.contains("缺少 expectedCategory") })
    #expect(issues.contains { $0.contains("相对路径") })
  }

  private static func outcomes(
    split: AcceptanceCase.Split, group: AcceptanceCase.Group = .definiteDoujin,
    count: Int, correct: Int, ready: Int, misrouted: Int = 0
  ) -> [AcceptanceCaseResult] {
    (0..<count).map { index in
      AcceptanceCaseResult(
        caseID: "\(split.rawValue)-\(index)", group: group, split: split,
        expectedCategory: "bunga", topCandidateCategory: index < correct ? "bunga" : "PDF",
        isTopChoiceCorrect: index < correct,
        isBatchReady: index < ready, isMisroutedDefaultReady: index < misrouted,
        isCreatorCorrect: nil)
    }
  }

  @Test func sufficientAndAccurateHoldoutPassesEveryGate() {
    let results = Self.outcomes(split: .holdout, count: 30, correct: 30, ready: 25)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let report = AcceptanceEvaluator.report(results: results)
    #expect(report.gates.allSatisfy { $0.passed })
    #expect(report.passed)
    #expect(report.holdoutDoujin.topChoiceAccuracy == 1)
  }

  @Test func oneWrongDoujinFailsTheAccuracyGate() {
    // 30 项里错 2 项即 93.3%，低于 95%；29 项正确时也才 96.7%，只允许错 1 项。
    let results = Self.outcomes(split: .holdout, count: 30, correct: 28, ready: 25)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let report = AcceptanceEvaluator.report(results: results)
    #expect(!report.passed)
    #expect(report.gates.contains { $0.name.contains("首选分类正确率") && !$0.passed })
  }

  @Test func tooFewBatchReadyDoujinFailsThatGate() {
    let results = Self.outcomes(split: .holdout, count: 30, correct: 30, ready: 20)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let report = AcceptanceEvaluator.report(results: results)
    #expect(!report.passed)
    #expect(report.gates.contains { $0.name.contains("可批量接受") && !$0.passed })
  }

  @Test func anyMisroutedDefaultReadyCaseFails() {
    let results = Self.outcomes(split: .holdout, count: 30, correct: 30, ready: 25, misrouted: 1)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let report = AcceptanceEvaluator.report(results: results)
    #expect(!report.passed)
    #expect(report.gates.contains { $0.name.contains("不得错分") && !$0.passed })
  }

  /// 少量样本即使全对也不能通过：否则可以用 3 项样本“凑”出 100% 准确率。
  @Test func smallHoldoutCannotPassOnPerfectAccuracyAlone() {
    let results = Self.outcomes(split: .holdout, count: 3, correct: 3, ready: 3)
    let report = AcceptanceEvaluator.report(results: results)
    #expect(!report.passed)
    #expect(report.gates.contains { $0.name.contains("样本数") && !$0.passed })
    #expect(report.gates.contains { $0.name.contains("明确同人志") && !$0.passed })
  }

  /// dev 集只用于调参，不参与判定。
  @Test func devSplitNeverAffectsTheGates() {
    let holdout = Self.outcomes(split: .holdout, count: 30, correct: 30, ready: 25)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let withBadDev = holdout + Self.outcomes(split: .dev, count: 30, correct: 0, ready: 30,
      misrouted: 30)
    #expect(AcceptanceEvaluator.report(results: holdout).passed)
    #expect(AcceptanceEvaluator.report(results: withBadDev).passed)
    #expect(AcceptanceEvaluator.report(results: withBadDev).dev.topChoiceCorrect == 0)
  }

  @Test func reportRendersGateOutcomes() {
    let results = Self.outcomes(split: .holdout, count: 30, correct: 30, ready: 25)
      + Self.outcomes(split: .holdout, group: .confusable, count: 20, correct: 20, ready: 0)
    let text = AcceptanceEvaluator.render(
      AcceptanceEvaluator.report(results: results), mode: "无图像模型")
    #expect(text.contains("无图像模型"))
    #expect(text.contains("全部门槛通过"))
    #expect(text.contains("开发集"))
  }
}
