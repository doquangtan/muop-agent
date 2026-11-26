#!/usr/bin/env bash
# Đóng gói CHỈ muop-agent-server (không có app Flutter) thành .deb cho máy không có GUI, ví dụ NAS Synology (DSM).
#
# Binary được build tĩnh bằng musl trong container Alpine, SQLite đóng gói sẵn trong binary
# (feature `bundled-sqlite`). Nhờ vậy gói không phụ thuộc glibc hay libsqlite3 của máy đích
# (DSM 7.1 dùng glibc 2.26, không đủ cho binary build trên máy dev cần GLIBC_2.39).
#
# Dùng:  make deb-server   (hoặc bash packaging/build-server-deb.sh)
# Cài:   sudo dpkg -i build/deb-server/muop-agent-server_<version>_amd64.deb
# Yêu cầu: docker (có quyền chạy container) và kết nối mạng để tải gói Alpine/crates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="muop-agent-server"
ARCH="amd64"
IMAGE="${BUILD_IMAGE:-rust:alpine}"

# pubspec: "version: 1.1.0+7" -> Debian version "1.1.0-7" (dấu + không hợp lệ trong version Debian)
PUB_VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\(+[0-9]*\)\?\).*/\1/p' "$ROOT/pubspec.yaml" | head -n1)"
if [ -z "$PUB_VERSION" ]; then
    echo "Không đọc được version trong pubspec.yaml" >&2
    exit 1
fi
DEB_VERSION="${PUB_VERSION/+/-}"

OUT="$ROOT/build/deb-server"
STAGE="$OUT/${PKG}_${DEB_VERSION}_${ARCH}"
BIN="$OUT/muop-agent-server"

mkdir -p "$OUT"
rm -f "$BIN"

echo "==> Build server (musl, tĩnh, bundled-sqlite) trong container $IMAGE"
# Mã nguồn mount chỉ đọc và copy vào /work (bỏ target/ của máy dev) để cargo có thể
# ghi Cargo.lock trong container mà không chạm vào repo. Thư mục target nằm trong volume để build lại nhanh.
docker run --rm \
    -v "$ROOT/server:/src:ro" \
    -v muop-agent-nas-target:/target \
    -v muop-agent-cargo-registry:/root/.cargo/registry \
    -v "$OUT:/out" \
    "$IMAGE" sh -c '
        set -eu
        mkdir -p /work
        (cd /src && tar --exclude=./target -cf - .) | tar -C /work -xf -
        cd /work
        # --target tường minh: crt-static chỉ áp dụng cho binary đích, không cho proc-macro của host.
        CARGO_TARGET_DIR=/target RUSTFLAGS="-C target-feature=+crt-static" \
            cargo build --release --target x86_64-unknown-linux-musl --features bundled-sqlite
        install -m 0755 /target/x86_64-unknown-linux-musl/release/muop-agent-server /out/muop-agent-server
    '

if [ ! -x "$BIN" ]; then
    echo "Không tạo được binary: $BIN" >&2
    exit 1
fi

echo "==> Kiểm tra binary không phụ thuộc thư viện động"
if readelf -d "$BIN" 2>/dev/null | grep -q NEEDED; then
    echo "Binary còn phụ thuộc thư viện động:" >&2
    readelf -d "$BIN" | grep NEEDED >&2
    exit 1
fi

echo "==> Chuẩn bị thư mục đóng gói"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin"
install -m 0755 "$BIN" "$STAGE/usr/bin/muop-agent-server"

INSTALLED_SIZE="$(du -sk "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEB_VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: muop-agent packager <packaging@localhost>
Description: Mướp Agent server (không giao diện, cổng 8787)
 muop-agent-server chạy nền như dịch vụ systemd, phục vụ REST và Socket.IO
 cho ứng dụng Mướp Agent trên máy khác trong LAN. Không cần ứng dụng Linux
 Desktop. Binary build tĩnh, không phụ thuộc thư viện hệ thống.
 Dữ liệu người dùng nằm trong ~/.local/share/muop-agent và không bị xóa khi gỡ gói.
EOF
install -m 0755 "$ROOT/packaging/server/postinst" "$STAGE/DEBIAN/postinst"
install -m 0755 "$ROOT/packaging/server/prerm" "$STAGE/DEBIAN/prerm"
install -m 0755 "$ROOT/packaging/server/postrm" "$STAGE/DEBIAN/postrm"

echo "==> Đóng gói .deb"
DEB_FILE="$OUT/${PKG}_${DEB_VERSION}_${ARCH}.deb"
rm -f "$DEB_FILE"
# gzip: dpkg-deb của DSM (Synology NAS) quá cũ, không đọc được nén zstd mặc định của dpkg hiện đại.
dpkg-deb -Zgzip -z9 --root-owner-group --build "$STAGE" "$DEB_FILE" >/dev/null
echo "✅ Đã tạo: $DEB_FILE"
dpkg-deb -I "$DEB_FILE" | sed -n '1,14p'
