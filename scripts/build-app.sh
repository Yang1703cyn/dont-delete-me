#!/bin/bash
#
# 把「别删我」打包成可以双击打开的 .app。
#
#   用法：scripts/build-app.sh
#   产物：build/DontDeleteMe.app（build/ 已在 .gitignore 里）
#
# 做三件事：编译发布版 → 手工组装 .app 目录结构 → 本机临时签名（ad-hoc）。
# 只需要 CommandLineTools，不需要完整的 Xcode。不做公证、不做安装镜像——那是发布阶段的事。
#
# 图标（都是可选的，没有也不报错）：
#   Assets/AppIcon.icns                     应用图标；没有就用系统默认的应用图标
#   Assets/MenuBarIcon.pdf                  菜单栏图标（推荐：单色矢量图）
#   Assets/MenuBarIcon.png / @2x / @3x      菜单栏图标（位图，18×18 点）
#   菜单栏图标会被当作"模板图"（只取形状，颜色由系统按深浅色菜单栏决定）；
#   没有就用系统符号占位。
#
# 想试试别处的图标而不动 Assets/，可以临时换一个目录：
#   DDM_ASSETS_DIR=/某个目录 scripts/build-app.sh

set -euo pipefail

PRODUCT="DontDeleteMe"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RESOURCES="Sources/$PRODUCT/Resources"
ASSETS="${DDM_ASSETS_DIR:-Assets}"
APP="build/$PRODUCT.app"

echo "==> 检查 Info.plist 和文案"
plutil -lint "$RESOURCES/Info.plist" "$RESOURCES"/*.lproj/*.strings >/dev/null

echo "==> 编译发布版"
# 编译过程的输出很长，平时不显示；失败时整段打出来。
BUILD_LOG="$(mktemp -t ddm-build-app)"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c release --product "$PRODUCT" >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG"
    echo "==> 编译失败"
    exit 1
fi
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$RESOURCES"/*.lproj "$APP/Contents/Resources/"

if [ -f "$ASSETS/AppIcon.icns" ]; then
    cp "$ASSETS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
    echo "    应用图标：$ASSETS/AppIcon.icns"
else
    echo "    应用图标：没有 $ASSETS/AppIcon.icns，使用系统默认图标"
fi

menu_bar_icon_found=no
for name in MenuBarIcon.pdf MenuBarIcon.png MenuBarIcon@2x.png MenuBarIcon@3x.png; do
    if [ -f "$ASSETS/$name" ]; then
        cp "$ASSETS/$name" "$APP/Contents/Resources/$name"
        menu_bar_icon_found=yes
        echo "    菜单栏图标：$ASSETS/$name"
    fi
done
if [ "$menu_bar_icon_found" = no ]; then
    echo "    菜单栏图标：$ASSETS/ 里没有 MenuBarIcon，使用系统符号占位"
fi

echo "==> 本机临时签名"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "==> 完成：$ROOT/$APP（版本 $VERSION）"
echo "    打开：open \"$ROOT/$APP\""
