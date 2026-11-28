# Đường dẫn công cụ theo HOME của user (không cố định theo máy). Ghi đè bằng biến môi trường nếu cần.
# Flutter 3.50.1 (~/flutter, checkout tag 3.50.1); không có thì dùng flutter trong PATH
FLUTTER ?= $(shell if [ -x $(HOME)/flutter/bin/flutter ]; then echo $(HOME)/flutter/bin/flutter; elif command -v flutter >/dev/null 2>&1; then command -v flutter; else echo flutter; fi)
CARGO ?= $(HOME)/.cargo/bin/cargo
DX ?= $(HOME)/.cargo/bin/dx

.PHONY: install-desktop-entry run server build-server build-server-mac build build-linux build-apk build-all analyze restart-linux clean start-daemon stop-daemon restart-daemon status-daemon deb deb-server app-run app-build app-check build-web

## Chạy ứng dụng giao diện Flutter trên Linux Desktop
run:
	$(FLUTTER) run -d linux

## Build và khởi chạy Rust Backend Server (Axum + Socket.IO) trên cổng 8787
server:
	cd server && $(CARGO) run --release

## Quản lý Daemon Rust Server qua systemd user service
install-service:
	@mkdir -p $(HOME)/.config/systemd/user
	@sed "s|@REPO@|$(CURDIR)|g" service/muop-agent-server.service > $(HOME)/.config/systemd/user/muop-agent-server.service
	@systemctl --user daemon-reload

start-daemon:
	@systemctl --user daemon-reload
	@systemctl --user enable muop-agent-server.service 2>/dev/null || true
	@systemctl --user restart muop-agent-server.service
	@echo "✅ muop-agent-server daemon đã khởi chạy thành công qua systemd!"

stop-daemon:
	@systemctl --user stop muop-agent-server.service
	@echo "🛑 Đã dừng muop-agent-server daemon!"

restart-daemon:
	@systemctl --user daemon-reload
	@systemctl --user restart muop-agent-server.service
	@echo "🔄 Đã khởi động lại muop-agent-server daemon!"

status-daemon:
	@systemctl --user status muop-agent-server.service --no-pager

## Build binary release cho Rust Backend Server
build-server:
	cd server && $(CARGO) build --release

## Build server cho macOS NGAY TRÊN máy Mac (rsync source qua SSH, cần Rust trên Mac).
## Không ảnh hưởng luồng Linux. Đặt MAC_HOST=user@ip (và MAC_SSH_KEY nếu dùng key riêng).
MAC_BUILD_DIR ?= muop-install
# Feature Cargo bật khi build trên Mac: mac-fuse để mount project máy khác bằng FUSE-T (mặc định bật).
# Binary link YẾU tới libfuse-t (xem RUSTFLAGS bên dưới) nên server vẫn khởi động khi chưa cài FUSE-T;
# FUSE-T là bắt buộc và được cài qua wizard (mục Gói Homebrew). Mount dùng API libfuse (server/src/fsmount/fuse_mac.rs).
MAC_FEATURES ?= mac-fuse
# Thư mục chứa fuse.pc (alias Name: fuse → -lfuse-t). Build tạo file này trên Mac nếu thiếu.
MAC_PKG_CONFIG_PATH ?= $$HOME/$(MAC_BUILD_DIR)/pkgconfig
# Thư mục lib của FUSE-T; pkg-config crate bỏ qua -Wl,-rpath nên phải đưa vào rpath của binary (không thì dyld không tìm thấy libfuse-t)
MAC_FUSE_LIBDIR ?= /usr/local/lib
comma := ,
MAC_SSH = ssh -o BatchMode=yes -o ConnectTimeout=8 $(if $(MAC_SSH_KEY),-i $(MAC_SSH_KEY) -o IdentitiesOnly=yes)
build-server-mac:
	@test -n "$(MAC_HOST)" || (echo "Thiếu MAC_HOST, ví dụ: make build-server-mac MAC_HOST=user@192.168.1.10" && exit 1)
	rsync -az --delete --exclude 'target/' --exclude '__pycache__/' -e "$(MAC_SSH)" server/ $(MAC_HOST):$(MAC_BUILD_DIR)/server/
	$(MAC_SSH) $(MAC_HOST) 'export PATH="/opt/homebrew/bin:$$PATH"; $(if $(findstring mac-fuse,$(MAC_FEATURES)),mkdir -p $(MAC_PKG_CONFIG_PATH) && printf "Name: fuse\nDescription: alias của FUSE-T\nVersion: 2.9.9\nLibs: -L$(MAC_FUSE_LIBDIR) -lfuse-t\nCflags: -D_FILE_OFFSET_BITS=64\n" > $(MAC_PKG_CONFIG_PATH)/fuse.pc && ,)cd $(MAC_BUILD_DIR)/server && . "$$HOME/.cargo/env" && $(if $(MAC_PKG_CONFIG_PATH),PKG_CONFIG_PATH=$(MAC_PKG_CONFIG_PATH) ,)$(if $(findstring mac-fuse,$(MAC_FEATURES)),RUSTFLAGS="-C link-arg=-L$(MAC_FUSE_LIBDIR) -C link-arg=-Wl$(comma)-rpath$(comma)$(MAC_FUSE_LIBDIR) -C link-arg=-Wl$(comma)-weak-lfuse-t" ,)cargo build --release $(if $(MAC_FEATURES),--features $(MAC_FEATURES),)'
	@echo "✅ Binary macOS: $(MAC_HOST):$(MAC_BUILD_DIR)/server/target/release/muop-agent-server"

# Gói cài đặt macOS (.pkg): app Flutter + máy chủ + tray menu bar, ký ad-hoc. Build trên Mac, kết quả kéo về thư mục gốc.
# Ví dụ: make build-macos-app MAC_HOST=user@ip MAC_SSH_KEY=... MAC_FEATURES=mac-fuse 'MAC_PKG_CONFIG_PATH=/Users/<user>/muop-install/pkgconfig'
# Lưu ý: MAC_PKG_CONFIG_PATH phải là đường dẫn tuyệt đối (make không mở rộng $HOME đúng trong biến này).
MAC_APP_DIR ?= /Volumes/Untitled/muop-agent
MAC_SCP = scp -o BatchMode=yes -o ConnectTimeout=8 $(if $(MAC_SSH_KEY),-i $(MAC_SSH_KEY) -o IdentitiesOnly=yes)
APP_VERSION := $(shell sed -n 's/^version: *//p' pubspec.yaml | tr '+' '-')
build-macos-app: build-server-mac
	rsync -az --exclude='.git/' --exclude='build/' --exclude='.dart_tool/' --exclude='server/target/' --exclude='macos/Pods/' --exclude='*.ipa' --exclude='*.pkg' -e "$(MAC_SSH)" ./ $(MAC_HOST):$(MAC_APP_DIR)/
	$(MAC_SSH) $(MAC_HOST) 'export PATH="/opt/homebrew/bin:$$HOME/flutter/bin:$$PATH"; cd $(MAC_APP_DIR) && flutter pub get && flutter build macos --release && flutter build web --release && APP=build/macos/Build/Products/Release/muop_agent.app && SIGN="-"; if [ -f "$$HOME/muop-install/signing/pw" ] && security unlock-keychain -p "$$(cat $$HOME/muop-install/signing/pw)" "$$HOME/Library/Keychains/muop-signing.keychain-db" 2>/dev/null; then security list-keychains -d user -s "$$HOME/Library/Keychains/muop-signing.keychain-db" "$$HOME/Library/Keychains/login.keychain-db"; SIGN="Muop Agents Local Signing"; fi && codesign --force --deep --sign "$$SIGN" --entitlements macos/Runner/Release.entitlements "$$APP" && echo "signed: $$SIGN" && (cd macos/menubar && swiftc -O -framework AppKit -o "$$HOME/$(MAC_BUILD_DIR)/muop-agent-tray" main.swift) && sh packaging/macos/build-pkg.sh "$$APP" "$$HOME/$(MAC_BUILD_DIR)/server/target/release/muop-agent-server" "$$HOME/$(MAC_BUILD_DIR)/muop-agent-tray" "$(APP_VERSION)" "$(MAC_APP_DIR)/build/macos-pkg/muop-agent-macos-$(APP_VERSION).pkg" "$(MAC_APP_DIR)/build/web" && echo "PKG_BUILT_OK"'
	$(MAC_SCP) $(MAC_HOST):$(MAC_APP_DIR)/build/macos-pkg/muop-agent-macos-$(APP_VERSION).pkg ./
	@echo "✅ Gói cài đặt: ./muop-agent-macos-$(APP_VERSION).pkg (cài bằng: make install-macos-pkg MAC_HOST=...)"

# Đưa gói sang Mac và mở trình cài đặt. Trình cài tự tắt app/máy chủ đang chạy rồi cài bản mới (nâng cấp).
# Cần mật khẩu admin của Mac: nhập trong cửa sổ Installer.
install-macos-pkg:
	@test -n "$(MAC_HOST)" || (echo "Thiếu MAC_HOST, ví dụ: make install-macos-pkg MAC_HOST=user@192.168.1.10" && exit 1)
	PKG=$$(ls -t muop-agent-macos-*.pkg | head -1) && $(MAC_SCP) "$$PKG" $(MAC_HOST):/tmp/muop-agent-macos.pkg && $(MAC_SSH) $(MAC_HOST) 'open /tmp/muop-agent-macos.pkg' && echo "✅ Đã mở trình cài đặt trên Mac: $$PKG"

# Tự mở app khi đăng nhập/khởi động lại máy Mac: LaunchAgent gọi `open -g` tới ~/Applications/muop_agent.app.
# Tắt: make macos-autostart-off MAC_HOST=user@ip. Template: macos/autostart/vn.muop.agents.autostart.plist.in
MAC_AUTOSTART_LABEL = vn.muop.agents.autostart
macos-autostart-on:
	@test -n "$(MAC_HOST)" || (echo "Thiếu MAC_HOST, ví dụ: make macos-autostart-on MAC_HOST=user@192.168.1.10" && exit 1)
	cat macos/autostart/vn.muop.agents.autostart.plist.in | $(MAC_SSH) $(MAC_HOST) 'P="$$HOME/Library/LaunchAgents/$(MAC_AUTOSTART_LABEL).plist"; mkdir -p "$$HOME/Library/LaunchAgents" "$$HOME/Library/Logs/muop-agent"; sed "s|__HOME__|$$HOME|g" > "$$P" && launchctl bootout gui/$$(id -u)/$(MAC_AUTOSTART_LABEL) 2>/dev/null; launchctl bootstrap gui/$$(id -u) "$$P" && echo "autostart: bật ($$P)"'

macos-autostart-off:
	@test -n "$(MAC_HOST)" || (echo "Thiếu MAC_HOST, ví dụ: make macos-autostart-off MAC_HOST=user@192.168.1.10" && exit 1)
	$(MAC_SSH) $(MAC_HOST) 'P="$$HOME/Library/LaunchAgents/$(MAC_AUTOSTART_LABEL).plist"; launchctl bootout gui/$$(id -u)/$(MAC_AUTOSTART_LABEL) 2>/dev/null; rm -f "$$P" && echo "autostart: đã tắt"'

## Đóng gói server + ứng dụng Linux thành một file .deb (build/deb/)
deb:
	FLUTTER=$(FLUTTER) CARGO=$(CARGO) bash packaging/build-deb.sh

## Đóng gói CHỈ server thành .deb tĩnh (musl, qua Docker) cho máy không có GUI, ví dụ NAS (build/deb-server/)
deb-server:
	bash packaging/build-server-deb.sh

## Build bản Flutter web (release) rồi đưa vào thư mục máy chủ phục vụ ở cổng 8788 (không cần khởi động lại máy chủ).
## Mở: http://<IP máy chủ>:8788. Thư mục đích: $(WEB_DIR) (đổi bằng MUOP_WEB_DIR cho máy chủ).
WEB_DIR ?= $(HOME)/.local/share/muop-agent/web
build-web:
	$(FLUTTER) build web --release
	@rm -rf "$(WEB_DIR)" && mkdir -p "$(WEB_DIR)" && cp -r build/web/. "$(WEB_DIR)/"
	@echo "✅ Bản web đã cập nhật: $(WEB_DIR) (mở http://<IP máy chủ>:8788)"

## Cài desktop entry + icon cho người dùng hiện tại để dock hiện đúng tên "Mướp Agents" và icon
install-desktop-entry:
	@mkdir -p "$(HOME)/.local/share/applications" "$(HOME)/.local/share/icons/hicolor/512x512/apps"
	@python3 -I -c "from PIL import Image; Image.open('assets/logo.png').convert('RGBA').resize((512,512), Image.LANCZOS).save('$(HOME)/.local/share/icons/hicolor/512x512/apps/vn.muop.agents.png')" 2>/dev/null || cp assets/logo.png "$(HOME)/.local/share/icons/hicolor/512x512/apps/vn.muop.agents.png"
	@sed 's#^Exec=.*#Exec=$(PWD)/build/linux/x64/release/bundle/muop_agent#' packaging/vn.muop.agents.desktop > "$(HOME)/.local/share/applications/vn.muop.agents.desktop"
	@update-desktop-database "$(HOME)/.local/share/applications" >/dev/null 2>&1 || true
	@gtk-update-icon-cache -q -t -f "$(HOME)/.local/share/icons/hicolor" >/dev/null 2>&1 || true

## Build bản thực thi Linux Desktop Release và tự động restart nếu đang chạy
build: build-linux

build-linux:
	$(FLUTTER) build linux --release
	@$(MAKE) --no-print-directory install-desktop-entry
	@if pgrep -x "muop_agent" > /dev/null; then \
		echo "🔄 Phát hiện muop_agent đang chạy trên Linux Desktop. Đang tắt tiến trình cũ và khởi động lại bản build mới..."; \
		killall muop_agent 2>/dev/null || pkill -x "muop_agent" 2>/dev/null || true; \
		sleep 1; \
		if command -v systemd-run >/dev/null 2>&1; then \
			systemd-run --user "$(PWD)/build/linux/x64/release/bundle/muop_agent" >/dev/null 2>&1; \
		else \
			nohup "$(PWD)/build/linux/x64/release/bundle/muop_agent" >/dev/null 2>&1 & \
		fi; \
		echo "✅ Đã khởi động lại muop_agent mới thành công!"; \
	else \
		echo "ℹ️ muop_agent không chạy. Bản build Linux đã sẵn sàng tại build/linux/x64/release/bundle/muop_agent"; \
	fi

## Khởi động lại ứng dụng Linux Desktop
restart-linux:
	@killall muop_agent 2>/dev/null || pkill -x "muop_agent" 2>/dev/null || true
	@sleep 1
	@if command -v systemd-run >/dev/null 2>&1; then \
		systemd-run --user "$(PWD)/build/linux/x64/release/bundle/muop_agent" >/dev/null 2>&1; \
	else \
		nohup "$(PWD)/build/linux/x64/release/bundle/muop_agent" >/dev/null 2>&1 & \
	fi
	@echo "✅ Đã mở lại muop_agent trên Linux Desktop!"

## Build file cài đặt Android APK Release (copy ra ./muop-agent-release.apk)
build-apk:
	$(FLUTTER) build apk --release
	cp build/app/outputs/flutter-apk/app-release.apk ./muop-agent-release.apk
	@echo "✅ APK Release đã sẵn sàng tại: $(PWD)/muop-agent-release.apk"

## Build trọn gói cả Android và Linux (tự restart Linux nếu đang mở)
build-all: build-apk build-linux
	@echo "🎉 Hoàn tất build Dual-Platform: APK & Linux Desktop Release!"

## Client Dioxus (app/): chạy thử trên Linux Desktop, tự tải lại khi sửa mã
app-run:
	cd app && $(DX) serve --desktop

## Build client Dioxus Linux Desktop Release
app-build:
	cd app && $(DX) build --desktop --release

## Kiểm tra client Dioxus: định dạng, clippy (lỗi = cảnh báo), test
app-check:
	cd app && $(CARGO) fmt --check && $(CARGO) clippy --all-targets -- -D warnings && $(CARGO) test

## Kiểm tra tĩnh mã nguồn Flutter & Rust
analyze:
	$(FLUTTER) analyze
	cd server && $(CARGO) check

clean:
	$(FLUTTER) clean
	cd server && $(CARGO) clean
