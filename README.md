# AI File Organizer V2.1

一个原生 macOS 收件箱整理助手。用户授权一个收件箱与一个同卷资料库，应用在本地生成可审核的移动方案，确认后执行，并为每次操作保留可恢复日志。

## 当前能力

- SwiftUI 三栏工作台：左侧导航、按完整目标路径分组的整理计划、文件检查器与固定执行栏。
- 扫描、内容分析、AI 分类、预检、移动和撤销的真实阶段进度。
- 直接子项增量扫描；跳过隐藏文件、符号链接和特殊文件。
- 最多四层目标目录扫描；同名叶子目录用完整相对路径区分。
- UTType、文件名、用户规则、已有资料库样本和目标目录画像共同驱动分类。
- PDF 前三页文字、扫描 PDF 首页 OCR、有限文本、按需图片 OCR，以及目录两层/200 项摘要。
- Apple Foundation Models guided generation；不可用时完整降级。
- AI 只能选择候选 ID 或提议一级新目录，不能传递任意路径。
- 自然语言规则先转换为可编辑草稿，用户确认后才保存和生效。
- 已确认并成功执行的移动会形成可撤回学习样本；资料库已有内容只作为弱证据。
- GRDB/SQLite 持久化会话、规则、学习、计划、逐项结果和跨启动历史。
- 同卷限制、不可变计划、目录内容清单、无覆盖移动、崩溃恢复和跨启动撤销。

## 开发

需要 Xcode 26、macOS 26 SDK 与 Swift 6.2+。`AIFileOrganizer.xcodeproj` 包含 App、Core、单元测试和 UI 测试目标；`project.yml` 是可复现的工程定义。

```bash
swift test
swift run AIFileOrganizerChecks
swift run AIFileOrganizer
./scripts/build-app.sh
xcodegen generate
xcodebuild -project AIFileOrganizer.xcodeproj -scheme AIFileOrganizer test
```

命令行打包脚本生成 ad-hoc 签名的本机 `.app`。Developer ID 签名、公证和正式分发需要付费 Apple Developer 账号，当前不在完成条件内。

如果本机 Command Line Tools 的编译器与 macOS 26 SDK 不匹配，可临时用随附的 15.4 SDK 验证基础模式：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk swift run --disable-sandbox AIFileOrganizerChecks
```

## 安全边界

- V2.1 不删除、不覆盖、不自动重命名、不跨卷移动。
- 目录与应用包整体处理；不递归拆散。
- 所有移动必须来自用户确认的计划。
- 撤销只删除由应用创建且仍为空的目录。

后台下载建议和重命名建议尚未启用；未来会作为输入/提案适配器进入同一审核、预检与执行边界，不能绕过用户确认直接操作文件。
