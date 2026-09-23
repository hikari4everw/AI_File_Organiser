# 构建与发布

## 当前环境

本机安装 **Xcode 27.0（27A266a）**，Swift 6.4，可验证 Foundation Models 分支、单元测试和 Release 构建。

**UI 测试当前无法运行**：本机 CoreSimulator 版本落后于 Xcode 要求，`xcodebuild` 会报
`CoreSimulator is out of date. Current version (1051.55.0) is older than build version (1171.7.0)`
并禁用模拟器设备支持，同时 `DVTCoreDeviceCore` 插件加载失败。需要更新 Xcode 命令行工具或
系统组件后才能执行 `xcodebuild -project AIFileOrganizer.xcodeproj -scheme AIFileOrganizer test`。
在此之前，UI 测试用例的改动属于“未在本机执行过”。

`xcodebuild` 在受限沙箱下还会因为无法写入 `~/Library/Caches/org.swift.swiftpm` 而无法解析依赖；
用 `swift build` / `swift test` 配合下面的模块缓存参数可以绕过。

以下基础模式命令仅用于没有完整 Xcode 的备用环境。

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift run --disable-sandbox AIFileOrganizerChecks
```

生成基础模式 `.app`：

```bash
AIFO_BASIC_MODE=1 ./scripts/build-app.sh
```

## 完整模式

1. 确认 `xcode-select -p` 指向 `/Applications/Xcode.app/Contents/Developer`。
2. 执行 `xcodegen generate` 重新生成工程。
3. 运行 `swift test` 和 `xcodebuild -project AIFileOrganizer.xcodeproj -scheme AIFileOrganizer test`。
4. 运行 `./scripts/build-app.sh` 生成带 Foundation Models 的 ad-hoc 本机 App。

## 正式发布

获得付费 Apple Developer 账号后，将脚本中的 ad-hoc 签名替换为 Developer ID Application，随后执行公证和 stapling。V2.2 不集成 Sparkle，也不提交 Mac App Store。
