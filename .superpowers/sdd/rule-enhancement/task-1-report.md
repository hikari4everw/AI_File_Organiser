# Task 1 实现报告

## 实现内容

- 新增 `NamingOperation`：支持按顺序渲染模板、删除字面前缀/后缀、删除受约束的数字前缀/后缀，以及字面替换；类型符合 `Codable`、`Hashable`、`Sendable`。
- 新增 `NamingOperationEngine`：从基础名称开始依序执行操作；模板操作使用当时的名称作为 `{原标题}`，并合并缺失字段到现有 `TemplateRenderResult`。
- 为 `NamingRule` 和 `NamingRuleDraft` 增加有序 `operations`，保留原有接收 `template` 的初始化器。旧 JSON 没有 `operations` 时自动转换为单个模板操作，无需数据库迁移。
- 扩展 `AppleRuleInterpreter.interpretNaming`：
  - 保留现有“命名为/重命名为/rename as”模板解析。
  - 精确解析同人志 nhentai 示例为 `同人志` 语义条件、`nhentai-` 粗粒度文件名条件及 `nhentai-<ASCII 数字> - ` 首部删除操作。
  - 支持带明确字面量的中文删除前缀/后缀，以及“替换为/替换成”表达。
  - 对含糊删除表达返回无可执行操作的草稿，并附清晰警告。
- `NamingRuleEngine` 改用有序操作引擎；保持原有冲突、缺失字段、名称校验、文件扩展名和 application bundle 行为。结构化变换未在首尾命中时不产生同名改名建议。
- 保存命名草稿时保留结构化操作；旧单模板草稿仍使用编辑后的模板内容。

## TDD：RED / GREEN 证据

### RED 1：缺少结构化 API

命令：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/ai-file-organizer-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ai-file-organizer-swiftpm-cache swift test --filter NamingOperationTests
```

结果：退出码 1。编译器按预期报告 `cannot find 'NamingOperationEngine' in scope`、`NamingRule`/`NamingRuleDraft` 没有 `operations`、新初始化器不存在。失败来自待实现功能。

说明：更早一次运行先被 SwiftPM 内部 `sandbox-exec` 和用户缓存权限阻止，未进入测试编译，不计为有效 RED；随后将缓存放入 `/tmp` 并获准在外层沙箱外运行，得到上述有效 RED。

### GREEN 1：结构化模型、执行、解析和兼容解码

同一聚焦命令结果：退出码 0，`NamingOperationTests` 13 个测试通过。

### RED 2：中部 nhentai 文本不得产生同名建议

命令：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/ai-file-organizer-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ai-file-organizer-swiftpm-cache swift test --filter NamingOperationTests.namingRuleEngineDoesNotProposeWhenNumericPrefixOccursInMiddle
```

结果：退出码 1，断言按预期失败；引擎返回了 `selectedByRule` 的同名建议。

### GREEN 2：非命中的结构化变换被过滤

聚焦命令结果：退出码 0，`NamingOperationTests` 14 个测试通过。

## 最终测试

- 聚焦：`swift test --filter NamingOperationTests`（带上述 `/tmp` 缓存环境变量）——退出码 0，14/14 通过。
- 全套：`swift test`（带上述 `/tmp` 缓存环境变量）——退出码 0，99/99 通过，共 12 个测试套件。
- 静态 diff：`git diff --check`——退出码 0，无空白错误。

## 修改文件

- `Sources/AIFileOrganizerCore/FilenameModels.swift`
- `Sources/AIFileOrganizerCore/NamingOperationEngine.swift`
- `Sources/AIFileOrganizerCore/NamingRuleEngine.swift`
- `Sources/AIFileOrganizerCore/AppleRuleInterpreter.swift`
- `Sources/AIFileOrganizerApp/AppModel.swift`
- `Tests/AIFileOrganizerCoreTests/NamingOperationTests.swift`
- `.superpowers/sdd/rule-enhancement/task-1-report.md`

## 自审结果

- 逐条对照 brief：六类操作能力、顺序执行、缺失字段兼容、旧初始化器、旧 JSON、nhentai 原句、不同数字、中部不匹配、后缀、替换、操作顺序、文件/目录、冲突/验证/扩展名均有实现或测试覆盖。
- 数字约束只接受一个或多个 ASCII 数字，且必须同时满足指定位置和两侧字面边界；不会执行任意正则或脚本。
- 空字面前缀、空字面后缀和空替换目标均为安全 no-op；结构化变换未改变基础名时规则引擎不产生建议。
- 修改集中于 Task 1 的模型、确定性解析/执行及保存接线，没有实现 Task 2 的语义模型判断或 Task 3 的编辑预览 UI。
- 现有 85 个测试与新增 14 个测试共同通过，未发现回归。

## 疑虑 / 后续边界

- 含 `同人志` 语义条件的 nhentai 草稿在当前规则引擎中仍按既有策略阻塞为“需要本地 AI 判断”；这是 Task 2 的预期接续点。
- 通用删除前缀/后缀只接受引号明确包围的字面量；未明确边界的自然语言会得到警告而不是被猜测执行，以避免误删。操作编辑和预览属于 Task 3。
