# Final review 集中修复报告

## 状态与范围

已按 `final-fix-brief.md` 集中修复终审确认的三个问题：

1. `AppleRuleInterpreter` 保留组合条件。扩展名、显式文件/目录类型、引号名称关键词仍进入确定性条件；未被结构化字段表示的剩余条件进入 `semanticDescription`。nhentai 特例在原条件上追加 `nhentai-`，不再重建并覆盖条件。
2. 命名变换先切分条件与操作片段，再从操作片段读取删除/替换操作数。无法可靠排序的多操作请求返回空 operations 和明确警告。
3. `AppModel.saveNamingRuleDraft` 改为接收原始示例名称与预期名称，并用当前 draft 在保存入口重新调用 `NamingRuleExampleEvaluator`；调用方不再能传入已计算 evaluation。省略示例仍有效。

此外加入三条自然语言到 `NamingRuleEngine` 执行的端到端测试，分别覆盖组合语义+确定性条件、nhentai+文件类型约束、引号条件+替换操作。

## 严格 TDD：逐项 RED / GREEN

### 1. 组合语义与扩展名条件

测试：`combinedSemanticAndExtensionConditionArePreserved`

RED 命令：

```sh
swift test --disable-sandbox --filter combinedSemanticAndExtensionConditionArePreserved
```

实际 RED：

```text
Expectation failed: (draft.condition.semanticDescription → nil) == "同人志"
Test run with 1 test in 1 suite failed ... with 1 issue.
EXIT_CODE=1
```

最小实现：`namingCondition` 在提取扩展名/类型后，把剩余明确条件安全保存在 `semanticDescription`。

实际 GREEN：

```text
Test combinedSemanticAndExtensionConditionArePreserved() passed
Suite NamingOperationTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

### 2. nhentai 特例保留原始明确条件

测试：`nhentaiSpecialCaseAddsConstraintWithoutDiscardingExplicitConditions`

实际 RED：

```text
Expectation failed: (draft.condition.itemKinds → []) == [.file]
Expectation failed: (draft.condition.fileExtensions → []) == ["pdf"]
Expectation failed: (draft.condition.filenameKeywords → ["nhentai-"]) == ["月光", "nhentai-"]
Test run with 1 test in 1 suite failed ... with 3 issues.
EXIT_CODE=1
```

最小实现：先解析 `删除前缀` 前的条件，再向现有 `filenameKeywords` 插入 `nhentai-`；同时解析 `名称包含「…」` 等显式关键词。

实际 GREEN：

```text
Test nhentaiSpecialCaseAddsConstraintWithoutDiscardingExplicitConditions() passed
Suite NamingOperationTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

### 3. 条件引号不能污染替换操作数

测试：`replacementOperandsAreReadOnlyFromOperationFragment`

实际 RED：

```text
Expectation failed: (draft.condition.semanticDescription → "把「_」") == nil
Expectation failed: (draft.operations → [replaceLiteral(target: "draft", replacement: "-")])
  == [replaceLiteral(target: "_", replacement: "-")]
Test run with 1 test in 1 suite failed ... with 2 issues.
EXIT_CODE=1
```

最小实现：新增条件/操作分段，替换目标和替换值只从操作片段提取。

实际 GREEN：

```text
Test replacementOperandsAreReadOnlyFromOperationFragment() passed
Suite NamingOperationTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

GREEN 后清理了未使用的 `marker`，再次运行同一测试仍通过，编译不再报告该警告。

### 4. 多操作顺序安全

测试：`multipleTransformationsAreRejectedWhenOrderCannotBeParsedReliably`

实际 RED：

```text
Expectation failed: (draft.operations → [removeLiteralPrefix("draft_")]).isEmpty → false
Expectation failed: (draft.warnings → []).contains(... "多项" ... "顺序")
Test run with 1 test in 1 suite failed ... with 2 issues.
EXIT_CODE=1
```

最小实现：检测多个变换标记并返回不可执行草稿，警告为“检测到多项命名变换，无法可靠确定执行顺序，请拆分为多条规则”。

实际 GREEN：

```text
Test multipleTransformationsAreRejectedWhenOrderCannotBeParsedReliably() passed
Suite NamingOperationTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

### 5. 保存入口不可绕过示例验证

测试：`saveReevaluatesRawExampleAgainstCurrentDraft`

实际 RED：

```text
error: extra arguments at positions #2, #3 in call
note: 'saveNamingRuleDraft(_:exampleEvaluation:)' declared here
error: fatalError
EXIT_CODE=1
```

最小实现：将 API 改为 `exampleOriginalName` / `exampleExpectedName`，在保存方法内用当前 draft 重算；UI 只传 raw 输入。

实际 GREEN：

```text
Test saveReevaluatesRawExampleAgainstCurrentDraft() passed
Suite AppModelTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

测试使用 no-op 原名称 `report.pdf`，确认保存被当前 draft 的真实评估以“没有变化”阻止。已有 `omittedExampleDoesNotBlockValidOperations` 继续覆盖省略示例有效。

### 6. 模板命名分支同样保留组合条件

提交前自审发现模板分支存在同一根因，补测试：`templateNamingPreservesCombinedSemanticAndExtensionConditions`。

实际 RED：

```text
Expectation failed: (draft.condition.itemKinds → []) == [.file]
Expectation failed: (draft.condition.semanticDescription → nil) == "同人志"
Test run with 1 test in 1 suite failed ... with 2 issues.
EXIT_CODE=1
```

最小实现：模板分支复用 `namingCondition`，移除其重复且会丢语义的条件解析。

实际 GREEN：

```text
Test templateNamingPreservesCombinedSemanticAndExtensionConditions() passed
Suite FilenameTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

## 端到端覆盖

`NamingOperationTests` 新增并通过：

- `naturalLanguageCombinedSemanticAndDeterministicConditionsReachExecution`
- `naturalLanguageNhentaiRuleKeepsFileTypeConstraintDuringExecution`
- `naturalLanguageQuotedConditionAndReplacementReachExecution`

这三项均从 `AppleRuleInterpreter.interpretNaming` 生成 draft，再构造 `NamingRule`，最终通过真实 `NamingRuleEngine.proposals` 检查匹配过滤与改名结果。没有复制生产解析或执行逻辑。

## 最终验证结果

所有 SwiftPM 命令使用：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/codex-rule-enhancement-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-rule-enhancement-swiftpm-cache \
  swift test --disable-sandbox ...
```

聚焦测试：

```text
AppModelTests:         1/1 通过
RuleTests:            13/13 通过
NamingOperationTests: 25/25 通过
RuleCreationTests:     9/9 通过
FilenameTests:        28/28 通过
```

无过滤 `swift test --disable-sandbox` 完成构建并启动 14 个 suite 后，60 秒没有任何测试结束输出，复现已记录的并发 runner 挂起，随后有界终止。

改为对全部 14 个 suite 逐一执行 `--skip-build --filter <Suite>`：共 127 项，126 项通过，1 项失败。唯一失败：

```text
LearningTests.existingLibraryFilesRefreshWithoutDuplicatesAndEnrichDestination
LearningTests.swift:86:5
Expectation failed: enriched.first?.sampleContentTypes.contains("com.adobe.pdf") == true
```

该 PDF UTI 环境断言在此前 Task 2/3 报告中已稳定复现；本次未修改 Learning、UTI 或内容提取代码。

Release 应用构建：

```sh
./scripts/build-app.sh
```

沙箱内首次因 Xcode 无权写用户级 Swift/Clang cache 退出；按授权在沙箱外重跑，并在最终代码上再次增量运行，结果：

```text
** BUILD SUCCEEDED **
dist/AI File Organizer.app
```

`codesign --verify --deep --strict 'dist/AI File Organizer.app'`：退出码 0。

`git diff --check`：退出码 0，无空白错误。

## 修改文件

- `Package.swift`
- `Sources/AIFileOrganizerApp/AppModel.swift`
- `Sources/AIFileOrganizerApp/RulesView.swift`
- `Sources/AIFileOrganizerCore/AppleRuleInterpreter.swift`
- `Tests/AIFileOrganizerCoreTests/AppModelTests.swift`
- `Tests/AIFileOrganizerCoreTests/FilenameTests.swift`
- `Tests/AIFileOrganizerCoreTests/NamingOperationTests.swift`
- `.superpowers/sdd/rule-enhancement/final-fix-report.md`

## 自审

- 每项生产行为都有独立、先失败后通过的测试；失败原因分别对应缺失行为，不是测试拼写或环境错误。
- 条件解析先提取可表示字段，再把剩余非空文本放入语义条件，避免确定性字段存在时静默丢失条件。
- nhentai 特例只追加约束，保留显式文件/目录类型、扩展名、名称关键词和语义条件。
- 替换操作数只读取操作片段；多操作没有实现可靠有序解析，因此明确返回空 operations，而非执行部分请求。
- 保存入口完全移除 caller-provided evaluation 参数；即使 UI 的预览状态过期，保存时也会用当前 draft 与 raw 示例重算。
- 旧调用默认值仍支持省略示例；现有模板初始化、旧 JSON 解码和已有命名行为由聚焦/逐 suite 回归覆盖。
- 改动限定于解释器、保存接线、测试依赖与相关测试，没有修改 Learning 环境失败或其他相邻逻辑。

## 疑虑 / 已知边界

1. 无过滤 Swift Testing runner 在当前环境仍会并发挂起；逐 suite 已覆盖全部 127 项并给出唯一失败。
2. `LearningTests` 的 PDF UTI 断言仍受当前 macOS/SDK 环境影响，属于既有问题，本次未越界修复。
3. 自然语言解析仍只结构化已知扩展名、明确文件/目录词和带引号的名称包含条件；其他未表示条件会进入 `semanticDescription`，需要既有语义判断流程确认。

## Fix Round 2：nhentai 后置“同人志”语义门槛

### 问题与最小修复

复审发现 nhentai 特例只解析 `删除前缀` 之前的条件，却用整句 `contains("同人志")` 决定是否生成可执行 operation。因此“同人志”仅出现在操作/示例片段时，旧实现会生成可执行操作，但 `semanticDescription` 为 nil，规则可绕过语义判断直接执行。

修复限定在 nhentai 特例：整句通过“同人志”门槛后，若已解析语义不含“同人志”则追加；若没有已解析语义则设为 `同人志`。确定性的 item kind、扩展名和 filename keywords 保持不变。

### TDD：RED

新增测试：`nhentaiMeaningAfterOperationMarkerStillRequiresSemanticDecision`

命令：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/codex-rule-enhancement-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-rule-enhancement-swiftpm-cache \
  swift test --disable-sandbox \
  --filter nhentaiMeaningAfterOperationMarkerStillRequiresSemanticDecision
```

实际 RED：

```text
Expectation failed: (draft.condition.semanticDescription → nil) == "同人志"
Expectation failed: (proposal.disposition → .selectedByRule) == .blocked
Expectation failed: (proposal.reason → "匹配用户命名规则").contains("需要本地 AI 判断")
Test run with 1 test in 1 suite failed ... with 3 issues.
EXIT_CODE=1
```

失败直接证明旧草稿缺少语义条件，真实 `NamingRuleEngine` 在没有语义 evaluation 时仍选择执行规则。

### TDD：GREEN

同一命令在最小生产改动后：

```text
Test nhentaiMeaningAfterOperationMarkerStillRequiresSemanticDecision() passed
Suite NamingOperationTests passed
Test run with 1 test in 1 suite passed
EXIT_CODE=0
```

测试同时确认 PDF 与 `nhentai-` 确定性条件仍保留，并通过真实规则执行验证：未提供 semantic match 时 proposal 为 `.blocked`，原因包含“需要本地 AI 判断”。

### 最终验证

逐一运行全部 14 个 suite（`--skip-build --filter <Suite>`）：

```text
共 128 项：127 项通过，1 项失败
NamingOperationTests：26/26 通过
FilenameTests：28/28 通过
RuleCreationTests：9/9 通过
RuleTests：13/13 通过
AppModelTests：1/1 通过
```

唯一失败仍为既有环境断言：

```text
LearningTests.existingLibraryFilesRefreshWithoutDuplicatesAndEnrichDestination
Expectation failed: enriched.first?.sampleContentTypes.contains("com.adobe.pdf") == true
```

最终 Release 构建：

```text
./scripts/build-app.sh
** BUILD SUCCEEDED **
dist/AI File Organizer.app
```

`codesign --verify --deep --strict` 与 `git diff --check` 均以退出码 0 完成。

### Fix Round 2 修改文件与自审

- `Sources/AIFileOrganizerCore/AppleRuleInterpreter.swift`
- `Tests/AIFileOrganizerCoreTests/NamingOperationTests.swift`
- `.superpowers/sdd/rule-enhancement/final-fix-report.md`

自审：改动只补齐已被整句门槛要求的 `同人志` 语义，不改变 nhentai 数字前缀操作、确定性条件解析或非 nhentai 路径；已有语义约束不会被覆盖。疑虑仍只有既有 Swift Testing 并发挂起与 Learning PDF UTI 环境失败。
