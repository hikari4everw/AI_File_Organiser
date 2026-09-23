import Foundation

// MARK: - 验收集清单

/// 一个留出验收样本。真实样本由用户提供，不参与学习与调参。
public struct AcceptanceCase: Codable, Hashable, Sendable {
  public enum Group: String, Codable, Hashable, Sendable {
    /// 类别明确的同人志，用于准确率与批量接受率。
    case definiteDoujin = "definite-doujin"
    /// 易混淆或其他类型项目，用于错分检查。
    case confusable
  }

  public enum Split: String, Codable, Hashable, Sendable {
    /// 允许用于校准排序与门槛。
    case dev
    /// 独立验收集：不得参与调参，只用于最终判定。
    case holdout
  }

  public var id: String
  /// 送进分类器的项目名称（作品目录名或文件名，不含扩展名以外的改动）。
  public var name: String
  public var group: Group
  public var split: Split
  /// 期望的首选分类目录相对路径。易混淆项目可以留空。
  public var expectedCategory: String?
  /// 期望的作者归档目录相对路径，用于另行审核作者路由，不参与分类准确率门槛。
  public var expectedCreator: String?
  /// 可选：资料库内的真实相对路径，用于提供正文/OCR/画面证据。留空则只测名称与结构。
  public var relativePath: String?

  public init(
    id: String, name: String, group: Group, split: Split,
    expectedCategory: String? = nil, expectedCreator: String? = nil,
    relativePath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.split = split
    self.expectedCategory = expectedCategory
    self.expectedCreator = expectedCreator
    self.relativePath = relativePath
  }
}

public struct AcceptanceManifest: Codable, Hashable, Sendable {
  public var version: Int
  public var description: String
  public var cases: [AcceptanceCase]

  public init(version: Int = 1, description: String, cases: [AcceptanceCase]) {
    self.version = version
    self.description = description
    self.cases = cases
  }

  /// 清单自身的问题。空数组表示可用于评测。
  public func validationIssues() -> [String] {
    var issues: [String] = []
    if version != 1 { issues.append("不支持的清单版本：\(version)") }
    if cases.isEmpty { issues.append("清单没有任何样本") }
    var seen = Set<String>()
    for item in cases {
      if item.id.isEmpty { issues.append("存在没有 id 的样本") }
      if !seen.insert(item.id).inserted { issues.append("样本 id 重复：\(item.id)") }
      if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("样本 \(item.id) 没有名称")
      }
      if item.group == .definiteDoujin,
        (item.expectedCategory ?? "").isEmpty
      {
        issues.append("明确同人志样本 \(item.id) 缺少 expectedCategory")
      }
      if item.relativePath?.hasPrefix("/") == true {
        issues.append("样本 \(item.id) 的 relativePath 必须是资料库内的相对路径")
      }
    }
    return issues
  }
}

// MARK: - 单个样本的分类结果

public struct AcceptanceCaseResult: Codable, Hashable, Sendable {
  public var caseID: String
  public var group: AcceptanceCase.Group
  public var split: AcceptanceCase.Split
  public var expectedCategory: String?
  public var topCandidateCategory: String?
  /// 首选候选是否等于期望分类。易混淆样本没有期望分类时为 nil。
  public var isTopChoiceCorrect: Bool?
  /// 是否进入“可批量接受”建议组。
  public var isBatchReady: Bool
  /// 是否属于“默认纳入方案却分错”的情况。验收要求恒为 0。
  public var isMisroutedDefaultReady: Bool
  /// 作者路由结果：true 正确、false 错误、nil 表示本次无法判定（另行审核）。
  public var isCreatorCorrect: Bool?
  public var note: String

  public init(
    caseID: String, group: AcceptanceCase.Group, split: AcceptanceCase.Split,
    expectedCategory: String?, topCandidateCategory: String?, isTopChoiceCorrect: Bool?,
    isBatchReady: Bool, isMisroutedDefaultReady: Bool, isCreatorCorrect: Bool?,
    note: String = ""
  ) {
    self.caseID = caseID
    self.group = group
    self.split = split
    self.expectedCategory = expectedCategory
    self.topCandidateCategory = topCandidateCategory
    self.isTopChoiceCorrect = isTopChoiceCorrect
    self.isBatchReady = isBatchReady
    self.isMisroutedDefaultReady = isMisroutedDefaultReady
    self.isCreatorCorrect = isCreatorCorrect
    self.note = note
  }
}

// MARK: - 汇总与门槛

public struct AcceptanceMetrics: Codable, Hashable, Sendable {
  public var caseCount: Int
  public var topChoiceEvaluated: Int
  public var topChoiceCorrect: Int
  public var batchReady: Int
  public var misroutedDefaultReady: Int
  public var creatorEvaluated: Int
  public var creatorCorrect: Int

  public var topChoiceAccuracy: Double? {
    topChoiceEvaluated == 0 ? nil : Double(topChoiceCorrect) / Double(topChoiceEvaluated)
  }

  public var batchReadyRate: Double? {
    topChoiceEvaluated == 0 ? nil : Double(batchReady) / Double(topChoiceEvaluated)
  }

  public static func summarize(_ results: [AcceptanceCaseResult]) -> AcceptanceMetrics {
    let evaluable = results.filter { $0.isTopChoiceCorrect != nil }
    return AcceptanceMetrics(
      caseCount: results.count,
      topChoiceEvaluated: evaluable.count,
      topChoiceCorrect: evaluable.filter { $0.isTopChoiceCorrect == true }.count,
      batchReady: evaluable.filter(\.isBatchReady).count,
      misroutedDefaultReady: results.filter(\.isMisroutedDefaultReady).count,
      creatorEvaluated: results.filter { $0.isCreatorCorrect != nil }.count,
      creatorCorrect: results.filter { $0.isCreatorCorrect == true }.count)
  }
}

public struct AcceptanceGate: Codable, Hashable, Sendable {
  public var name: String
  public var passed: Bool
  public var detail: String

  public init(name: String, passed: Bool, detail: String) {
    self.name = name
    self.passed = passed
    self.detail = detail
  }
}

public struct AcceptanceReport: Codable, Hashable, Sendable {
  public var holdout: AcceptanceMetrics
  public var dev: AcceptanceMetrics
  public var holdoutDoujin: AcceptanceMetrics
  public var gates: [AcceptanceGate]

  public var passed: Bool { gates.allSatisfy(\.passed) }
}

/// 验收门槛。参数与计划一致，判定只使用留出集。
public enum AcceptanceEvaluator {
  public static let minimumHoldoutCases = 50
  public static let minimumHoldoutDoujin = 30
  public static let minimumTopChoiceAccuracy = 0.95
  public static let minimumBatchReadyRate = 0.80

  public static func report(results: [AcceptanceCaseResult]) -> AcceptanceReport {
    let holdout = results.filter { $0.split == .holdout }
    let dev = results.filter { $0.split == .dev }
    let holdoutDoujin = holdout.filter { $0.group == .definiteDoujin }
    let holdoutMetrics = AcceptanceMetrics.summarize(holdout)
    let doujinMetrics = AcceptanceMetrics.summarize(holdoutDoujin)

    var gates: [AcceptanceGate] = []
    gates.append(
      AcceptanceGate(
        name: "留出集样本数 ≥ \(minimumHoldoutCases)",
        passed: holdout.count >= minimumHoldoutCases,
        detail: "当前 \(holdout.count) 项"))
    gates.append(
      AcceptanceGate(
        name: "留出集明确同人志 ≥ \(minimumHoldoutDoujin)",
        passed: holdoutDoujin.count >= minimumHoldoutDoujin,
        detail: "当前 \(holdoutDoujin.count) 项"))
    if let accuracy = doujinMetrics.topChoiceAccuracy {
      gates.append(
        AcceptanceGate(
          name: "明确同人志首选分类正确率 ≥ \(Int(minimumTopChoiceAccuracy * 100))%",
          passed: accuracy >= minimumTopChoiceAccuracy,
          detail: String(
            format: "%.1f%%（%d/%d）", accuracy * 100,
            doujinMetrics.topChoiceCorrect, doujinMetrics.topChoiceEvaluated)))
    } else {
      gates.append(
        AcceptanceGate(
          name: "明确同人志首选分类正确率 ≥ \(Int(minimumTopChoiceAccuracy * 100))%",
          passed: false, detail: "留出集没有可评分的明确同人志样本"))
    }
    if let rate = doujinMetrics.batchReadyRate {
      gates.append(
        AcceptanceGate(
          name: "明确同人志进入可批量接受建议组 ≥ \(Int(minimumBatchReadyRate * 100))%",
          passed: rate >= minimumBatchReadyRate,
          detail: String(
            format: "%.1f%%（%d/%d）", rate * 100,
            doujinMetrics.batchReady, doujinMetrics.topChoiceEvaluated)))
    } else {
      gates.append(
        AcceptanceGate(
          name: "明确同人志进入可批量接受建议组 ≥ \(Int(minimumBatchReadyRate * 100))%",
          passed: false, detail: "留出集没有可评分的明确同人志样本"))
    }
    gates.append(
      AcceptanceGate(
        name: "默认纳入方案的明确建议不得错分",
        passed: holdoutMetrics.misroutedDefaultReady == 0,
        detail: "错分 \(holdoutMetrics.misroutedDefaultReady) 项"))

    return AcceptanceReport(
      holdout: holdoutMetrics, dev: AcceptanceMetrics.summarize(dev),
      holdoutDoujin: doujinMetrics, gates: gates)
  }

  /// 人类可读报告。`mode` 用于区分有/无图像模型两档。
  public static func render(_ report: AcceptanceReport, mode: String) -> String {
    var lines: [String] = []
    lines.append("=== 验收结果（\(mode)）===")
    lines.append(
      "留出集：\(report.holdout.caseCount) 项，"
        + "首选分类正确率 \(Self.percent(report.holdout.topChoiceAccuracy))，"
        + "可批量接受 \(Self.percent(report.holdout.batchReadyRate))，"
        + "默认错分 \(report.holdout.misroutedDefaultReady) 项")
    lines.append(
      "留出集明确同人志：\(report.holdoutDoujin.caseCount) 项，"
        + "首选分类正确率 \(Self.percent(report.holdoutDoujin.topChoiceAccuracy))，"
        + "可批量接受 \(Self.percent(report.holdoutDoujin.batchReadyRate))")
    lines.append(
      "开发集（仅供调参，不参与判定）：\(report.dev.caseCount) 项，"
        + "首选分类正确率 \(Self.percent(report.dev.topChoiceAccuracy))")
    let creator = report.holdout.creatorEvaluated == 0
      ? "作者路由未判定（另行审核）"
      : "作者路由 \(report.holdout.creatorCorrect)/\(report.holdout.creatorEvaluated) 正确（另行审核，不计入门槛）"
    lines.append(creator)
    lines.append("")
    lines.append("门槛：")
    for gate in report.gates {
      lines.append("  [\(gate.passed ? "通过" : "未通过")] \(gate.name) — \(gate.detail)")
    }
    lines.append("")
    lines.append(report.passed ? "结论：全部门槛通过" : "结论：存在未通过的门槛")
    return lines.joined(separator: "\n")
  }

  private static func percent(_ value: Double?) -> String {
    guard let value else { return "不可评分" }
    return String(format: "%.1f%%", value * 100)
  }
}
