# 验收状态记录

本文件记录当前实际验证到的状态，与计划 `Docs/superpowers/plans/2026-09-23-directory-author-classification.md`
的验收条款逐条对应。**未验证的项目明确写为未验证**，不用合成样本或少量样本充数。

## 一、自动化验证（已复现）

| 项目 | 结果 | 说明 |
|---|---|---|
| 单元测试 | 262 项 / 31 套件通过 | `swift test` |
| 核心安全检查 | 11 / 11 通过 | `swift run AIFileOrganizerChecks` |
| Release 构建 | 成功 | `swift build -c release --product AIFileOrganizer` |
| Xcode UI 测试 | **无法运行** | 见下方环境问题 |

### 环境问题（非代码缺陷）

本机 Xcode 27.0 与系统 CoreSimulator 版本不匹配，`xcodebuild` 无法加载设备支持：

```
CoreSimulator is out of date. Current version (1051.55.0) is older than build version (1171.7.0).
iOSSimulator: Simulator device support disabled.
DVTPlugInLoading: Failed to load code for plug-in com.apple.dt.DVTCoreDeviceCore
```

因此 `xcodebuild ... test`（含 `UITests/AIFileOrganizerUITests.swift`）在本机无法启动。
UI 测试用例已随代码更新，但**尚未在本机执行过**。

## 二、分类准确率（未验证）

计划要求：固定至少 50 项独立标注样本（30 项类别明确同人志 + 20 项易混淆/其他），
样本不参与学习和调参；明确同人志首选分类正确率 ≥95%、进入可批量接受建议组 ≥80%、
默认纳入方案的明确建议不得错分。

**当前状态：真实标注样本尚未提供，三条门槛均未验证。**

- 评测工具与清单格式已就位：`Evaluation/acceptance/`。
- 仓库内清单只有 `sample-` 前缀的示例条目；工具遇到示例清单以退出码 3 结束，不会报告通过。
- 工具已用 50 项临时样本做过端到端冒烟：能正确输出各档指标与逐条门槛判定（见下）。

### 参数标定状态

排序与门槛参数**尚未在新的证据尺度上重新标定**。已知事实：

- `RankedCandidate.score` 是累加的证据总分，没有上限（多种证据叠加时实测可达 2.3）。
- 界面展示改用 `normalizedScore = min(max(score, 0), 1)`，不会再出现超过 100 分。
- 决策门槛 `0.70/0.20`（确定性提案）与 `0.65/0.15`（模型提案）仍作用于原始分。
- 两种做法不能兼得：若在核心内截断分数，"通用文件类型证据"（恰好 1.0）会与
  "强正文证据"（1.2）变得不可区分，首选目录会排错。因此截断只放在展示层。

待真实样本到位后，应使用 `split: "dev"` 的子集校准排序与门槛并固化，再用
`split: "holdout"` 判定；届时把标定结果补记到本节。

## 三、实际模型状态

| 项目 | 状态 |
|---|---|
| 本地图像模型（MobileCLIP-BLT） | **未安装**（`~/Library/Application Support/AI File Organizer/Concept Models` 不存在） |
| 无图像模型档 | 已验证：名称、结构、PDF/图片文本与 OCR 均可工作 |
| 有图像模型档 | **未验证**：本机没有模型，且验收清单也没有真实样本 |

有模型档的验收报告可用同一命令追加：设置 `AI_FILE_ORGANIZER_TEST_MODEL` 指向本地
MobileCLIP 包即可，工具会输出第二份报告。

## 四、冒烟运行记录

用 50 项临时构造样本（30 项同人志 + 20 项易混淆）与一个最小测试资料库运行
`AIFileOrganizerAcceptance`，用于确认工具本身正确：

```
=== 验收结果（无图像模型）===
留出集：50 项，首选分类正确率 40.0%，可批量接受 0.0%，默认错分 0 项
留出集明确同人志：30 项，首选分类正确率 0.0%，可批量接受 0.0%
门槛：
  [通过] 留出集样本数 ≥ 50 — 当前 50 项
  [通过] 留出集明确同人志 ≥ 30 — 当前 30 项
  [未通过] 明确同人志首选分类正确率 ≥ 95% — 0.0%（0/30）
  [未通过] 明确同人志进入可批量接受建议组 ≥ 80% — 0.0%（0/30）
  [通过] 默认纳入方案的明确建议不得错分 — 错分 0 项
```

该资料库只有 1 部作品、没有同人志式命名样本，因此同人志正确率为 0 是预期结果；
此记录只证明门槛判定与报告输出可用，**不作为准确率结论**。
