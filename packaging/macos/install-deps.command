#!/bin/bash
# Cài các gói máy chủ Mướp Agents cần trên macOS: Homebrew, ffmpeg (quay màn hình), FUSE-T (mount project máy khác).
# Gói .pkg mở file này trong Terminal sau khi cài nếu còn thiếu. Cài Homebrew và FUSE-T cần mật khẩu admin
# của Mac: nhập trực tiếp trong Terminal (installer không lưu mật khẩu).
# MUOP_DEPS_CHECK_ONLY=1: chỉ in trạng thái, không cài (dùng để kiểm tra).

BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
done
FFMPEG_OK=0
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [ -x "$candidate" ]; then FFMPEG_OK=1; break; fi
done
FUSE_OK=0
if [ -e /usr/local/lib/libfuse-t.dylib ] || [ -e /opt/homebrew/lib/libfuse-t.dylib ]; then FUSE_OK=1; fi

status() {
  echo "Homebrew : $([ -n "$BREW" ] && echo "có ($BREW)" || echo "CHƯA CÓ")"
  echo "ffmpeg   : $([ "$FFMPEG_OK" = 1 ] && echo "có" || echo "CHƯA CÓ")"
  echo "FUSE-T   : $([ "$FUSE_OK" = 1 ] && echo "có" || echo "CHƯA CÓ")"
}

echo "== Mướp Agents: kiểm tra gói cần thiết cho máy chủ"
status

if [ "${MUOP_DEPS_CHECK_ONLY:-0}" = 1 ]; then
  exit 0
fi

if [ -z "$BREW" ]; then
  echo ""
  echo "-- Cài Homebrew (theo hướng dẫn chính thức https://brew.sh, cần mật khẩu Mac)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
  done
fi

if [ -z "$BREW" ]; then
  echo ""
  echo "Không tìm thấy Homebrew sau khi cài. Kiểm tra lại rồi chạy lại file này."
else
  eval "$("$BREW" shellenv)"
  if [ "$FFMPEG_OK" != 1 ]; then
    echo ""
    echo "-- Cài ffmpeg"
    "$BREW" install ffmpeg
  fi
  if [ "$FUSE_OK" != 1 ]; then
    echo ""
    echo "-- Cài FUSE-T (cần mật khẩu Mac)"
    "$BREW" install --cask fuse-t
  fi
fi

echo ""
echo "== Trạng thái sau khi cài"
FFMPEG_OK=0; FUSE_OK=0; BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
done
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [ -x "$candidate" ]; then FFMPEG_OK=1; break; fi
done
if [ -e /usr/local/lib/libfuse-t.dylib ] || [ -e /opt/homebrew/lib/libfuse-t.dylib ]; then FUSE_OK=1; fi
status
echo ""
echo "Nếu vừa cài FUSE-T hoặc ffmpeg, khởi động lại máy chủ để nhận: launchctl kickstart -k gui/$(id -u)/vn.muop.agent-server"
echo ""
read -r -n 1 -p "Nhấn phím bất kỳ để đóng cửa sổ này..." _
echo ""
