# AI File Organizer V2

一个原生 macOS 收件箱整理助手。用户授权一个收件箱与一个同卷资料库，应用在本地生成可审核的移动方案，确认后执行，并为每次操作保留可恢复日志。

## 当前能力

- SwiftUI 单窗口：首次设置、整理方案、异常处理、执行回执与撤销。
- 扫描、内容分析、AI 分类、预检、移动和撤销的真实阶段进度。
- 直接子项增量扫描；跳过隐藏文件、符号链接和特殊文件。
- UTType、文件名和目标目录画像驱动的确定性分类。
- PDF 首页文字、有限文本和按需 Vision OCR。
- Apple Foundation Models guided generation；不可用时完整降级。
- AI 只能选择候选 ID 或提议一级新目录，不能传递任意路径。
- GRDB/SQLite 持久化会话、快照、建议、计划、操作和决策。
- 同卷限制、不可变计划、执行前快照、无覆盖移动、崩溃恢复和整批撤销。

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

- V2.0 不删除、不覆盖、不自动重命名、不跨卷移动。
- 目录与应用包整体处理；不递归拆散。
- 所有移动必须来自用户确认的计划。
- 撤销只删除由应用创建且仍为空的目录。
