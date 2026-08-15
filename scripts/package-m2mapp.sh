#!/bin/bash
# 把 SPM 编译出来的 M2MApp 可执行文件包装成一个真正的、可以双击打开的
# macOS .app。SPM 不会给普通的 executableTarget 自动做这件事——Xcode
# 才会，但这个项目用的是 `swift build`，不是 Xcode。
#
# 用法：
#   swift build -c release
#   scripts/package-m2mapp.sh
#   rm -rf /Applications/M2MApp.app && cp -R .build/M2MApp.app /Applications/
#
# 产出：.build/M2MApp.app
#
# 重要：只应该 `open` /Applications 里那份，绝对不要直接打开
# .build/M2MApp.app。macOS 的 Control Center 是在进程外托管 MenuBarExtra
# 的状态栏图标的；如果两个 App 包共用同一个 CFBundleIdentifier（比如测试时
# 打开过一次 .build/M2MApp.app，又装了一份到 /Applications），系统会把
# 这个状态栏图标的身份判定为有冲突/被阻止，发一个"隐藏"的指令——而一个只有
# 菜单栏图标、没有传统窗口的 App 会把这理解成"没什么可显示了"然后自己退出，
# 大概一秒钟之内就没了。这个问题在 2026-08-15 排查了很久，最后靠
# `lsregister -dump` 才确认是重复注册导致的。这个脚本每次都会把
# .build/M2MApp.app 从 LaunchServices 里注销掉，避免开发过程中不小心
# 打开了 build 目录里那份、留下同样的冲突。

set -euo pipefail
cd "$(dirname "$0")/.."

BINARY=".build/release/M2MApp"
APP_DIR=".build/M2MApp.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

if [ ! -f "$BINARY" ]; then
    echo "错误：找不到 $BINARY —— 请先执行 'swift build -c release'" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY" "$APP_DIR/Contents/MacOS/M2MApp"

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>M2MApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.kivi1998.m2mdisplay</string>
    <key>CFBundleName</key>
    <string>M2M Display</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 把 build 目录里那份从 LaunchServices 注销掉，这样它就不可能跟
# /Applications 里那份共用同一个身份共存——详见上面的"重要"说明。
"$LSREGISTER" -u "$APP_DIR" 2>/dev/null || true

echo "已打包：$APP_DIR"
