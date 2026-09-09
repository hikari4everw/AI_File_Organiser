#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

if [[ "${AIFO_BASIC_MODE:-0}" == "1" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
  export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
elif [[ "$(xcode-select -p)" == *"CommandLineTools"* ]]; then
  echo "需要安装完整 Xcode 才能构建包含 Foundation Models 的版本。" >&2
  echo "仅验证基础模式可运行：AIFO_BASIC_MODE=1 ./scripts/build-app.sh" >&2
  exit 1
fi

app_dir="$project_root/dist/AI File Organizer.app"

if [[ "${AIFO_BASIC_MODE:-0}" == "1" ]]; then
  swift build --disable-sandbox -c release --product AIFileOrganizer
  bin_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
  contents="$app_dir/Contents"
  rm -rf "$app_dir"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp "$bin_dir/AIFileOrganizer" "$contents/MacOS/AIFileOrganizer"
  sed \
    -e 's/$(EXECUTABLE_NAME)/AIFileOrganizer/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.markco.AIFileOrganizer/g' \
    -e 's/$(PRODUCT_NAME)/AI File Organizer/g' \
    "$project_root/Config/Info.plist" > "$contents/Info.plist"
  codesign --force --deep --sign - --entitlements "$project_root/Config/AIFileOrganizer.entitlements" "$app_dir"
else
  xcodebuild \
    -project "$project_root/AIFileOrganizer.xcodeproj" \
    -scheme AIFileOrganizer \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$project_root/.xcode-derived" \
    -clonedSourcePackagesDirPath "$project_root/.build" \
    -skipPackageUpdates \
    build
  built_app="$project_root/.xcode-derived/Build/Products/Release/AI File Organizer.app"
  rm -rf "$app_dir"
  mkdir -p "$project_root/dist"
  ditto "$built_app" "$app_dir"
fi

echo "$app_dir"
