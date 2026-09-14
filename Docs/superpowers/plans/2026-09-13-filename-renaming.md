# AI 文件名建议与安全重命名实施记录

## 范围

实现本地 AI 文件名建议、独立命名规则、可审核的移动/改名组合、命名学习、安全执行、崩溃恢复及完整撤销。后台下载监控和 Downloads 内原地分类不在本次范围。

## 任务记录

1. 文件名模型、模板与安全校验
   - 新增固定模板字段、模板解析和统一名称验证器。
   - 测试覆盖扩展名锁定、Unicode、非法字符、长度和应用包。
   - 提交：`7a8d0a3 feat: add filename templates and validation`

2. 命名规则与自然语言解释
   - 整理规则和命名规则独立持久化、匹配和编辑。
   - 同一句话可产生两类草稿；冲突命名规则只阻止改名。
   - 提交：`05b8eb6 feat: add editable naming rules`

3. 本地 AI 文件名建议
   - 新增异常名称检测、内容复用、Foundation Models guided generation 和输出校验。
   - 模型不可用时不生成伪建议。
   - 提交：`28eccb7 feat: generate local filename suggestions`

4. 持久化与命名学习
   - 新增 `v2.2-filename-renaming` 迁移、命名样本和待批准规则建议。
   - 资料库弱风格采样限制为每个目标 30 项。
   - 提交：`19cadc8 feat: persist rename decisions and learning`

5. 不可变计划、执行与撤销
   - 新增 `.rename`；移动并改名保持一个 `.move` 操作。
   - 补齐预检、路径冲突、日志、学习事务和撤销。
   - 提交：`7af9f61 feat: execute and undo safe renames`

6. 应用状态与审核交互
   - 增加名称预览、采用/编辑/恢复、规则管理、摘要和历史路径。
   - UI 测试通过固定演示状态验证关键入口。
   - 提交：`270c4c0 feat: add rename review experience`

7. 集成验收与发布构建
   - 补测 `.rename` 崩溃恢复和漫画目录整体移动/改名。
   - 更新架构、隐私、README、版本和 Xcode 工程。
   - 生成唯一的 `dist/AI File Organizer.app`。

## 验证门槛

```bash
swift test
xcodegen generate
xcodebuild test -project AIFileOrganizer.xcodeproj -scheme AIFileOrganizer -destination 'platform=macOS'
./Scripts/build-app.sh
```

预期：核心测试、macOS UI 测试和 Release App 构建全部成功；`dist` 只包含一个最新应用，版本为 2.2.0。
