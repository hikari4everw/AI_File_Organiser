# 构建与发布

## 当前环境

当前机器只有 Command Line Tools。其 Swift 6.3.3 编译器与 macOS 26.5 SDK 的 6.3.2 模块不匹配，因此不能验证 Foundation Models 分支或运行系统测试框架。随附 macOS 15.4 SDK 可以构建并运行基础模式。

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

1. 从 App Store 安装匹配系统版本的完整 Xcode。
2. 执行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
3. 打开 `Package.swift`，等待 GRDB 7.6.1 解析。
4. 运行 `swift test`，并在 Xcode 中启动 `AIFileOrganizer` scheme。
5. 运行 `./scripts/build-app.sh` 生成带 Foundation Models 的 ad-hoc 本机 App。

## 正式发布

获得付费 Apple Developer 账号后，将脚本中的 ad-hoc 签名替换为 Developer ID Application，随后执行公证和 stapling。V2.0 不集成 Sparkle，也不提交 Mac App Store。

