# Task 3 实现报告：规则创建韧性、操作编辑与示例预览

## 状态

- Task 3 已实现并完成聚焦测试、逐 suite 全量验证及原生 Release 应用构建。
- 提交信息：`feat: make rule creation resilient and previewable`。

## 实现内容

1. 新增 `RuleInterpretationEngine` 与 `NamingRuleInterpreting`：
   - 并行执行整理规则与命名规则解释；
   - 两路结果分别捕获错误，任一路产出草稿就返回可编辑结果；
   - 另一路为空或失败时返回可见 warning；
   - 只有两路都没有草稿时才抛出汇总错误。
2. `AppModel.interpretRule` 改用聚合引擎，并在新一轮解释前清理旧草稿、旧 warning 和旧错误，避免部分失败吞掉有效草稿或遗留过期状态。
3. 新增 `NamingRuleExampleEvaluator`：
   - 示例可完全省略；
   - 用户填写原名称后，直接复用 `NamingOperationEngine` 和 `FilenameValidator` 生成完整名称预览；
   - 保留生产路径的操作顺序、模板缺失字段、文件扩展名和名称合法性约束；
   - no-op、非法名称、缺失模板字段、预期名称不一致都会返回明确阻止原因；
   - 含语义条件时只标记“尚未验证”，不在规则编辑界面调用模型。
4. 命名规则草稿 UI 现在按编号展示有序操作，六类操作均可编辑参数、删除、上移和下移。示例区显示原名称、实际预览、可选预期名称、语义未验证提示及阻止原因。
5. 保存按钮由同一个 core 示例评估结果控制；`AppModel` 保存入口也拒绝带阻止原因的评估结果。保存始终以当前 `operations` 为权威，避免多操作编辑后落回旧模板值。
6. 通过 `xcodegen generate` 更新原生 Xcode 工程，纳入 Task 1/2/3 新增但原工程尚未引用的 core 与测试源文件，使原生 Release 构建覆盖完整语义与操作管线。

## TDD：RED

先只新增 `RuleCreationTests.swift`，随后运行：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/codex-rule-enhancement-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-rule-enhancement-swiftpm-cache \
  swift test --disable-sandbox --filter RuleCreationTests
```

退出码：`1`。关键输出符合缺功能预期：

```text
error: cannot find type 'NamingRuleInterpreting' in scope
error: cannot find 'RuleInterpretationEngine' in scope
error: cannot find 'NamingRuleExampleEvaluator' in scope
error: fatalError
```

失败来自待实现的两路解释聚合与示例评估 API，不是测试拼写或环境错误。

## TDD：GREEN 与验证

同一聚焦命令在最小 core 实现后通过：

```text
Suite RuleCreationTests passed
Test run with 9 tests in 1 suite passed
```

最终聚焦验证：

```sh
swift test --disable-sandbox --filter RuleCreationTests
swift test --disable-sandbox --filter NamingOperationTests
```

结果：`RuleCreationTests` 9/9、`NamingOperationTests` 18/18，共 27/27 通过；Debug app target 同时编译成功。

全套命令也实际启动：

```sh
swift test --disable-sandbox
```

它和 Task 2 记录一致，在完成构建后 60 秒没有测试输出，随后被有界终止。改为对全部 13 个 suite 逐一执行 `--skip-build --filter <Suite>`，共运行 118 项：117 项通过，1 项失败。唯一失败仍是未修改且已记录的环境相关断言：

```text
LearningTests.existingLibraryFilesRefreshWithoutDuplicatesAndEnrichDestination
Expectation failed: enriched.first?.sampleContentTypes.contains("com.adobe.pdf") == true
```

原生应用构建：

```sh
./scripts/build-app.sh
```

首次在沙箱内因 Xcode 无权访问用户级 SwiftPM 缓存而退出；按授权在沙箱外重跑及最终增量重跑均成功：

```text
** BUILD SUCCEEDED **
dist/AI File Organizer.app
```

`codesign --verify --deep --strict` 通过；`git diff --check` 通过。

## 测试覆盖

- 整理解释失败、整理解释为空时，命名草稿仍保留并携带 warning。
- 命名解释失败时，整理草稿仍保留并携带 warning。
- 两路均无草稿时才产生总错误。
- 用户原名称原样保留；`nhentai-651786 - 月光.pdf` 预览为 `月光.pdf`，并标注语义尚未验证。
- 示例预览与 `NamingRuleEngine` 实际规则执行及扩展名处理一致。
- no-op、非法输出、预期名称不一致阻止保存；示例省略时不阻止合法操作。

## 修改文件

- `AIFileOrganizer.xcodeproj/project.pbxproj`
- `Sources/AIFileOrganizerApp/AppModel.swift`
- `Sources/AIFileOrganizerApp/RulesView.swift`
- `Sources/AIFileOrganizerCore/AppleRuleInterpreter.swift`
- `Sources/AIFileOrganizerCore/NamingRuleExampleEvaluator.swift`
- `Sources/AIFileOrganizerCore/RuleInterpretationEngine.swift`
- `Tests/AIFileOrganizerCoreTests/RuleCreationTests.swift`
- `.superpowers/sdd/rule-enhancement/task-3-report.md`

## 自审

- 每条生产改动都对应 brief：解释隔离、部分 warning、总错误边界、操作编辑/排序、可选示例、生产引擎预览、语义未验证提示及阻止保存。
- 聚合器只把错误转换为文字，不改变解释器的草稿内容；两路任务都被等待，不会因先抛错而取消另一条有效结果。
- 示例评估没有复制操作变换逻辑，也没有调用 Foundation Models；文件与目录沿用生产的基础名和扩展名规则。
- UI 没有增加脆弱的源码文本断言，Debug/Release 两种编译路径都覆盖了它。
- 改动集中于规则创建与 Xcode 源文件清单，没有调整分类、执行、数据库或学习逻辑。

## 疑虑 / 已知边界

- 完整 `swift test` runner 在本机仍会无输出挂起；逐 suite 结果清楚定位到一个 Task 2 已记录的 PDF UTI 环境断言，Task 3 聚焦测试及其余 suite 均通过。
- 文本示例只有文件名证据，不提供 Spotlight 标题/作者/日期；用户若为需要这些字段的模板填写示例，会看到缺字段并被阻止保存。示例保持可省略。
