# 构建与发布

## 当前环境

当前机器已安装 Xcode 26.6，可直接验证 Foundation Models 分支、单元测试、UI 测试和 Release 构建。以下基础模式命令仅用于没有完整 Xcode 的备用环境。

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
