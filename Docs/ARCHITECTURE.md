# V2 架构

## 信任边界

`AppleFoundationModelProvider` 只能生成 `ModelProposal`。模型看到的是目标 ID 和有限上下文，不接收可写路径，也无法访问 `FileManager`。所有输出依次经过结构校验、`DecisionPolicy`、用户审核、`PlanBuilder` 和 `SafePlanExecutor`。

```text
安全书签 → LocalInboxScanner → ItemSnapshot
                            ↓
DestinationIndexer → DeterministicClassifier
                            ↓ 模糊项
         NativeContentExtractor → Foundation Models
                            ↓
                 ClassificationProposal
                            ↓ 用户审核
                    OrganizationPlan
                            ↓ 预检
                        用户确认
                            ↓ 事务日志先落库
                    SafePlanExecutor
                            ↓
                    ExecutionReceipt
```

## 状态与持久化

会话状态为 `idle → scanning → proposing → review → preflighting → executing → completed/partial`，另有 `cancelled/failed`。视图状态不会绕过领域接口直接移动文件。

GRDB 数据库包含八个业务表：`workspaces`、`sessions`、`item_snapshots`、`proposals`、`folder_proposals`、`plans`、`operations`、`decision_records`。计划与文件快照以 Codable JSON 保存，同时保留可索引的状态、路径和外键列。

执行前一次性插入计划与全部操作；每项开始前标记 `running`，完成后立即标记 `completed/failed/blocked`。重试相同计划时，完成项不会重复移动，处于 `running` 且源已消失、目标快照一致的移动视为已完成。

## 文件规则

- 只扫描收件箱直接子项。
- 目录与 macOS package 整体处理。
- 隐藏文件、符号链接和特殊文件跳过。
- 目标必须在资料库之下，新目录必须是资料库的直接子目录。
- 收件箱与资料库必须同卷、分离且不互相包含。
- 同名目标阻止执行；没有覆盖或自动重命名分支。
- 撤销只删除本应用创建且已经为空的目录。

## AI 降级

应用启动时检查 `SystemLanguageModel` 的设备、Apple Intelligence、模型就绪和 Locale 状态。不可用或生成失败时，确定性分类继续工作，剩余项目进入“需要处理”。

当前 `#if canImport(FoundationModels)` 分支允许旧 SDK 编译基础模式；使用匹配的 macOS 26 SDK 构建时自动启用真正的 guided generation provider。
