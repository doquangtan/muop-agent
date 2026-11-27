#!/bin/sh
# Đóng gói .pkg cài đặt Mướp Agents cho macOS: app Flutter + máy chủ + helper menu bar + LaunchAgent + script gói phụ thuộc.
# Máy chủ được đặt trong app bundle "Muop Agents Server.app" (bundle id vn.muop.agent-server) để macOS
# hiện đúng mục trong Privacy & Security → Screen Recording. Chạy trên máy Mac (sau khi đã build app và máy chủ). Dùng:
#   sh packaging/macos/build-pkg.sh <app.app> <muop-agent-server> <muop-agent-tray> <version> <out.pkg>
set -eu

if [ "$#" -ne 5 ]; then
  echo "Cách dùng: $0 <app.app> <muop-agent-server> <muop-agent-tray> <version> <out.pkg>" >&2
  exit 2
fi
APP="$1"
SERVER="$2"
TRAY="$3"
VERSION="$4"
OUT="$5"
HERE=$(cd "$(dirname "$0")" && pwd)
SERVER_BUNDLE_NAME="Muop Agents Server.app"
# Tên file app hiển thị trong Finder/Applications là tên bundle (không phải CFBundleDisplayName)
APP_BUNDLE_NAME="Mướp Agents.app"

ROOT=$(mktemp -d /tmp/muop-pkg-root.XXXXXX)
WORK=$(mktemp -d /tmp/muop-pkg-work.XXXXXX)
trap 'rm -rf "$ROOT" "$WORK"' EXIT

BUNDLE="$ROOT/Applications/$SERVER_BUNDLE_NAME"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$ROOT/Applications" "$ROOT/Library/LaunchAgents"

# ditto giữ nguyên chữ ký và thuộc tính mở rộng của bundle
ditto "$APP" "$ROOT/Applications/$APP_BUNDLE_NAME"

# Máy chủ + helper menu bar nằm cùng thư mục MacOS của bundle server (helper được tìm theo current_exe)
cp "$SERVER" "$BUNDLE/Contents/MacOS/muop-agent-server"
cp "$TRAY" "$BUNDLE/Contents/MacOS/muop-agent-tray"
chmod 755 "$BUNDLE/Contents/MacOS/muop-agent-server" "$BUNDLE/Contents/MacOS/muop-agent-tray"
# Icon của app Flutter (cùng bộ biểu tượng Mướp Agents) cho bundle máy chủ, để mục Screen Recording có icon
cp "$APP/Contents/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>vn.muop.agent-server</string>
  <key>CFBundleName</key><string>Mướp Agents Server</string>
  <key>CFBundleDisplayName</key><string>Mướp Agents Server</string>
  <key>CFBundleExecutable</key><string>muop-agent-server</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Ký ad-hoc: helper ký trước, bundle ký sau (TCC nhận diện theo bundle id)
codesign --force --sign - "$BUNDLE/Contents/MacOS/muop-agent-tray"
codesign --force --sign - --identifier vn.muop.agent-server "$BUNDLE/Contents/MacOS/muop-agent-server"
codesign --force --sign - "$BUNDLE"

cp "$HERE/vn.muop.agent-server.plist" "$ROOT/Library/LaunchAgents/vn.muop.agent-server.plist"
chmod 644 "$ROOT/Library/LaunchAgents/vn.muop.agent-server.plist"

# Script cài gói phụ thuộc (Homebrew, ffmpeg, FUSE-T), postinstall mở nó trong Terminal khi còn thiếu
mkdir -p "$ROOT/Library/Application Support/MuopAgent"
cp "$HERE/install-deps.command" "$ROOT/Library/Application Support/MuopAgent/install-deps.command"
chmod 755 "$ROOT/Library/Application Support/MuopAgent/install-deps.command"

# Không cho installer chuyển vị trí bundle sang bản cùng định danh đang có ở nơi khác (ví dụ ~/Applications)
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist" >/dev/null
# Đặt BundleIsRelocatable=false cho MỌI bundle trong component (pkgbuild --analyze không luôn ghi khóa này)
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$WORK/component.plist" >/dev/null 2>&1; do
  if ! /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$WORK/component.plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$WORK/component.plist"
  fi
  i=$((i + 1))
done

chmod 755 "$HERE/scripts/preinstall" "$HERE/scripts/postinstall"
mkdir -p "$(dirname "$OUT")"
pkgbuild \
  --root "$ROOT" \
  --component-plist "$WORK/component.plist" \
  --scripts "$HERE/scripts" \
  --identifier vn.muop.agents \
  --version "$VERSION" \
  --install-location / \
  "$OUT"
echo "PKG_BUILT=$OUT"
