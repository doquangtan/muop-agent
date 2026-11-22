#!/usr/bin/env bash
# Đóng gói muop-agent-server (Rust) + ứng dụng Linux (Flutter) thành một file .deb.
#
# Cài:    sudo apt install ./build/deb/muop-agent_<version>_amd64.deb
# Nâng cấp: cài file .deb mới cùng cách; postinst tự khởi động lại server đang chạy.
#
# Dùng: make deb   (hoặc bash packaging/build-deb.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
CARGO="${CARGO:-cargo}"
PKG="muop-agent"
ARCH="$(dpkg --print-architecture)"

# pubspec: "version: 1.1.0+2" -> Debian version "1.1.0-2" (dấu + không hợp lệ trong version Debian)
PUB_VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\(+[0-9]*\)\?\).*/\1/p' "$ROOT/pubspec.yaml" | head -n1)"
if [ -z "$PUB_VERSION" ]; then
    echo "Không đọc được version trong pubspec.yaml" >&2
    exit 1
fi
DEB_VERSION="${PUB_VERSION/+/-}"

OUT="$ROOT/build/deb"
STAGE="$OUT/${PKG}_${DEB_VERSION}_${ARCH}"
BUNDLE="$ROOT/build/linux/x64/release/bundle"

echo "==> Build server (Rust release)"
(cd "$ROOT/server" && "$CARGO" build --release)
SERVER_BIN="$ROOT/server/target/release/muop-agent-server"

echo "==> Build ứng dụng Linux (Flutter release)"
(cd "$ROOT" && "$FLUTTER" build linux --release)
if [ ! -x "$BUNDLE/muop_agent" ]; then
    echo "Thiếu bundle Flutter: $BUNDLE/muop_agent" >&2
    exit 1
fi

echo "==> Chuẩn bị thư mục đóng gói"
rm -rf "$STAGE"
mkdir -p \
    "$STAGE/DEBIAN" \
    "$STAGE/usr/bin" \
    "$STAGE/usr/lib/$PKG" \
    "$STAGE/usr/lib/systemd/user" \
    "$STAGE/usr/share/applications" \
    "$STAGE/usr/share/icons/hicolor/512x512/apps"

install -m 0755 "$SERVER_BIN" "$STAGE/usr/bin/muop-agent-server"
cp -a "$BUNDLE/." "$STAGE/usr/lib/$PKG/"
install -m 0755 "$ROOT/packaging/muop-agent-launcher" "$STAGE/usr/bin/$PKG"
install -m 0644 "$ROOT/packaging/muop-agent-server.service" \
    "$STAGE/usr/lib/systemd/user/muop-agent-server.service"
install -m 0644 "$ROOT/packaging/vn.muop.agents.desktop" \
    "$STAGE/usr/share/applications/vn.muop.agents.desktop"
python3 -I -c "from PIL import Image; Image.open('$ROOT/assets/logo.png').convert('RGBA').resize((512,512), Image.LANCZOS).save('$STAGE/usr/share/icons/hicolor/512x512/apps/vn.muop.agents.png')" \
    || install -m 0644 "$ROOT/assets/logo.png" "$STAGE/usr/share/icons/hicolor/512x512/apps/vn.muop.agents.png"

echo "==> Tính phụ thuộc thư viện (dpkg-shlibdeps)"
SHLIB_DIR="$OUT/shlibs"
rm -rf "$SHLIB_DIR"
mkdir -p "$SHLIB_DIR/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\nDescription: tmp\n' "$PKG" "$PKG" \
    > "$SHLIB_DIR/debian/control"
SHLIB_TARGETS=(-e"$STAGE/usr/lib/$PKG/muop_agent" -e"$STAGE/usr/bin/muop-agent-server")
for so in "$STAGE/usr/lib/$PKG/lib/"*.so; do
    SHLIB_TARGETS+=(-e"$so")
done
SHLIB_OUT="$(cd "$SHLIB_DIR" && dpkg-shlibdeps -O -l"$STAGE/usr/lib/$PKG/lib" \
    "${SHLIB_TARGETS[@]}" 2>"$SHLIB_DIR/shlibdeps.log")"
SHLIB_DEPENDS="$(printf '%s\n' "$SHLIB_OUT" | sed -n 's/^shlibs:Depends=//p')"
if [ -z "$SHLIB_DEPENDS" ]; then
    echo "dpkg-shlibdeps không trả về phụ thuộc; xem $SHLIB_DIR/shlibdeps.log" >&2
    exit 1
fi

# Công cụ mà server dùng trực tiếp (wizard cũng kiểm tra các gói này)
APP_DEPENDS="${SHLIB_DEPENDS}, fuse3, git, curl, openssh-client"

echo "==> Ghi control và script cài đặt"
INSTALLED_SIZE="$(du -sk "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEB_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: muop-agent packager <packaging@localhost>
Depends: $APP_DEPENDS
Description: Mướp Agent Monitor (server + ứng dụng Linux)
 Gói gồm muop-agent-server (Rust, chạy nền qua systemd --user, cổng 8787)
 và ứng dụng Linux Desktop (Flutter). Dữ liệu người dùng nằm trong
 ~/.local/share/muop-agent và không bị xóa khi gỡ hoặc nâng cấp gói.
EOF
install -m 0755 "$ROOT/packaging/debian/postinst" "$STAGE/DEBIAN/postinst"
install -m 0755 "$ROOT/packaging/debian/prerm" "$STAGE/DEBIAN/prerm"
install -m 0755 "$ROOT/packaging/debian/postrm" "$STAGE/DEBIAN/postrm"

echo "==> Đóng gói .deb"
DEB_FILE="$OUT/${PKG}_${DEB_VERSION}_${ARCH}.deb"
rm -f "$DEB_FILE"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB_FILE" >/dev/null
echo "✅ Đã tạo: $DEB_FILE"
dpkg-deb -I "$DEB_FILE" | sed -n '1,20p'
