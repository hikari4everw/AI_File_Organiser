# AI File Organizer V2.2

一个原生 macOS 收件箱整理助手。用户授权一个收件箱与一个同卷资料库，应用在本地生成可审核的移动方案，确认后执行，并为每次操作保留可恢复日志。

## 当前能力

- SwiftUI 三栏工作台：左侧导航、按完整目标路径分组的整理计划、文件检查器与固定执行栏。
- 扫描、内容分析、AI 分类、预检、移动和撤销的真实阶段进度。
- 直接子项增量扫描；跳过隐藏文件、符号链接和特殊文件。
- 最多四层目标目录扫描；同名叶子目录用完整相对路径区分。
- UTType、文件名、用户规则、已有资料库样本和目标目录画像共同驱动分类。
- PDF 前三页文字、扫描 PDF 首页 OCR、有限文本、按需图片 OCR，以及目录两层/200 项摘要。
- Apple Foundation Models guided generation；不可用时完整降级。
- 本地 AI 文件名建议：只针对明确异常名称自动分析，普通项目也可手动请求。
- 文件名模板支持 `{原标题}`、`{标题}`、`{作者}`、`{日期}`；扩展名始终锁定。
- 移动与改名独立审核，可只移动、只改名、移动并改名或全部保留。
- AI 只能选择候选 ID 或提议一级新目录，不能传递任意路径。
- 自然语言规则先转换为可编辑的整理/命名草稿，用户确认后才保存和生效。
- 可用当前项目或外部文件教会系统一个跨工作区的文件概念；概念与目标目录分开保存，默认目标可选。
- 已知概念可直接生成“概念 → 目标目录”规则草稿；正例、反例和概念纠正不会直接移动文件。
- 可主动下载约 173 MB 的本地图像模型，为 PDF、EPUB、图片和有界目录样本生成相似概念候选；通过本地校准门槛的视觉候选会标为“高度相似”，但仍需人工确认后才能触发概念规则。
- 讲义、账单等有文本的文件还会生成有界的本地哈希文本特征；未下载图像模型时也可提出待审核的文本相似候选。
- 已确认并成功执行的移动与改名会形成可撤回学习样本；资料库已有内容只作为弱证据。
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

当前测试基线为 **205 个单元测试（25 个套件）**，另有 `AIFileOrganizerChecks` 的 11 项核心安全检查。若本机 SwiftPM 的用户级缓存不可写（受限环境），需要显式指定可写的模块缓存并关闭沙箱：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox
```

概念特征提取用例默认跳过：它们需要本地已编译的 MobileCLIP 包，通过 `AI_FILE_ORGANIZER_TEST_MODEL` 指向该包路径才会执行。

如果本机 Command Line Tools 的编译器与 macOS 26 SDK 不匹配，可临时用随附的 15.4 SDK 验证基础模式：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk swift run --disable-sandbox AIFileOrganizerChecks
```

## 安全边界

- V2.2 不删除、不覆盖、不自动追加数字、不改变扩展名、不跨卷移动。
- 目录与应用包整体处理；不递归拆散。
- `.app` 等应用包不提供改名建议；普通目录可整体移动和改名，内部名称不变。
- 所有移动和改名必须来自用户确认的不可变计划。
- 撤销只删除由应用创建且仍为空的目录。

后台下载建议尚未启用；未来只作为输入适配器创建同一种整理会话和提案，不能绕过用户确认直接操作文件。

概念模型只在用户点击“下载本地图像模型”后从 Apple 发布的固定版本下载，并在安装前校验每个文件的大小和 SHA-256。未安装模型时仍可手动记录概念和明确标签，但不会为新文件生成图像相似候选。固定版本视觉模型使用已冻结的 `0.75` 相似度和 `0.02` 候选差值标记“高度相似”；文本相似和未达门槛的视觉结果继续作为普通待审核候选。无论置信度如何，概念规则都只接受用户明确确认的标签。
