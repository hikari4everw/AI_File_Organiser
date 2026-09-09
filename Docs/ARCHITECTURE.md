# V2.1 架构

## 信任边界

`AppleFoundationModelProvider` 只能生成 `ModelProposal`。模型看到的是目标 ID 和有限上下文，不接收可写路径，也无法访问 `FileManager`。所有输出依次经过结构校验、`DecisionPolicy`、用户审核、`PlanBuilder` 和 `SafePlanExecutor`。

```text
安全书签 → LocalInboxScanner → ItemSnapshot
                            ↓
四层 DestinationCatalog → 规则 + 资料库画像 + DeterministicClassifier
                            ↓ 模糊项
 NativeContentExtractor / DirectoryAnalyzer → Foundation Models
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

GRDB 还持久化目标目录、用户规则、学习事件和样本。计划与文件快照以 Codable JSON 保存，同时保留可索引的状态、路径和外键列。切换工作区只取消激活，不级联删除历史，因此重新授权后仍可查询旧计划。

执行前一次性插入计划与全部操作；每项开始前标记 `running`，完成后立即标记 `completed/failed/blocked`。重试相同计划时，完成项不会重复移动，处于 `running` 且源已消失、目标快照一致的移动视为已完成。

## 文件规则

- 只扫描收件箱直接子项。
- 目录与 macOS package 整体处理。
- 隐藏文件、符号链接和特殊文件跳过。
- 目标必须在资料库之下，新目录必须是资料库的直接子目录。
- 收件箱与资料库必须同卷、分离且不互相包含。
- 同名目标阻止执行；没有覆盖或自动重命名分支。
- 撤销只删除本应用创建且已经为空的目录。
- 普通目录移动前保存有界递归清单；内部内容变化会阻止撤销。

## 规则与学习

自然语言通过 Apple Foundation Models guided generation 转成 `RuleDraft`。草稿中的条件与目标可编辑，只有用户点击保存才成为 `OrganizationRule`。确定性条件优先执行；不同规则命中不同目标时强制审核；语义条件作为模型提示但不会绕过决策策略。

`LearningService` 合并两类信号：目标目录中有界采样的现有内容，以及用户确认计划中实际成功的移动。前者只增强目标画像，后者按操作 ID 去重。撤销成功会停用对应学习样本，不会删除用户编写的规则。

## 未来扩展边界

后台下载检测只负责提交新项目，重命名功能只负责产生“建议名称”。两者未来都必须进入当前会话、审核、不可变计划、预检和操作日志流程；后台适配器与 AI 提供方不能直接调用文件系统。

## AI 降级

应用启动时检查 `SystemLanguageModel` 的设备、Apple Intelligence、模型就绪和 Locale 状态。不可用或生成失败时，确定性分类继续工作，剩余项目进入“需要处理”。

当前 `#if canImport(FoundationModels)` 分支允许旧 SDK 编译基础模式；使用匹配的 macOS 26 SDK 构建时自动启用真正的 guided generation provider。
