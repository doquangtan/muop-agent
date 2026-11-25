# Đường dẫn công cụ theo HOME của user (không cố định theo máy). Ghi đè bằng biến môi trường nếu cần.
# Ưu tiên Flutter 3.47.7; không có thì dùng Flutter hiện hành (flutter trong PATH, rồi ~/flutter)
FLUTTER ?= $(shell if [ -x $(HOME)/flutter-3.47.7/bin/flutter ]; then echo $(HOME)/flutter-3.47.7/bin/flutter; elif command -v flutter >/dev/null 2>&1; then command -v flutter; else echo $(HOME)/flutter/bin/flutter; fi)
CARGO ?= $(HOME)/.cargo/bin/cargo

.PHONY: install-desktop-entry run server build-server build-server-mac build build-linux build-apk build-all analyze restart-linux clean start-daemon stop-daemon restart-daemon status-daemon deb

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
# Feature Cargo bật thêm khi build trên Mac, ví dụ MAC_FEATURES=mac-fuse sau khi cài FUSE-T (mount project máy khác).
# FUSE-T chỉ có fuse-t.pc; cần thư mục chứa fuse.pc (alias Name: fuse → -lfuse-t) đặt ở MAC_PKG_CONFIG_PATH trên Mac.
MAC_FEATURES ?=
MAC_PKG_CONFIG_PATH ?=
# Thư mục lib của FUSE-T; pkg-config crate bỏ qua -Wl,-rpath nên phải đưa vào rpath của binary (không thì dyld không tìm thấy libfuse-t)
MAC_FUSE_LIBDIR ?= /usr/local/lib
comma := ,
MAC_SSH = ssh -o BatchMode=yes -o ConnectTimeout=8 $(if $(MAC_SSH_KEY),-i $(MAC_SSH_KEY) -o IdentitiesOnly=yes)
build-server-mac:
	@test -n "$(MAC_HOST)" || (echo "Thiếu MAC_HOST, ví dụ: make build-server-mac MAC_HOST=user@192.168.1.10" && exit 1)
	rsync -az --delete --exclude 'target/' --exclude '__pycache__/' -e "$(MAC_SSH)" server/ $(MAC_HOST):$(MAC_BUILD_DIR)/server/
	$(MAC_SSH) $(MAC_HOST) 'export PATH="/opt/homebrew/bin:$$PATH"; cd $(MAC_BUILD_DIR)/server && . "$$HOME/.cargo/env" && $(if $(MAC_PKG_CONFIG_PATH),PKG_CONFIG_PATH=$(MAC_PKG_CONFIG_PATH) ,)$(if $(findstring mac-fuse,$(MAC_FEATURES)),RUSTFLAGS="-C link-arg=-Wl$(comma)-rpath$(comma)$(MAC_FUSE_LIBDIR)" ,)cargo build --release $(if $(MAC_FEATURES),--features $(MAC_FEATURES),)'
	@echo "✅ Binary macOS: $(MAC_HOST):$(MAC_BUILD_DIR)/server/target/release/muop-agent-server"

# App macOS một file: client Flutter + server đi kèm (Contents/Helpers), ký ad-hoc. Build trên Mac, kết quả copy vào ~/Applications.
# Ví dụ: make build-macos-app MAC_HOST=user@ip MAC_SSH_KEY=... MAC_FEATURES=mac-fuse 'MAC_PKG_CONFIG_PATH=$$HOME/muop-install/pkgconfig'
MAC_APP_DIR ?= /Volumes/Untitled/muop-agent
build-macos-app: build-server-mac
	rsync -az --exclude='.git/' --exclude='build/' --exclude='.dart_tool/' --exclude='server/target/' --exclude='macos/Pods/' --exclude='*.ipa' -e "$(MAC_SSH)" ./ $(MAC_HOST):$(MAC_APP_DIR)/
	$(MAC_SSH) $(MAC_HOST) 'export PATH="/opt/homebrew/bin:$$HOME/flutter/bin:$$PATH"; cd $(MAC_APP_DIR) && flutter pub get && flutter build macos --release && APP=build/macos/Build/Products/Release/muop_agent.app && mkdir -p "$$APP/Contents/Helpers" && cp "$$HOME/$(MAC_BUILD_DIR)/server/target/release/muop-agent-server" "$$APP/Contents/Helpers/" && codesign --force --deep --sign - --entitlements macos/Runner/Release.entitlements "$$APP" && mkdir -p "$$HOME/Applications" && rm -rf "$$HOME/Applications/muop_agent.app" && cp -R "$$APP" "$$HOME/Applications/" && echo "APP_READY=$$HOME/Applications/muop_agent.app"'
	@echo "✅ App macOS: $(MAC_HOST) → ~/Applications/muop_agent.app (bản gốc: $(MAC_APP_DIR)/build/macos/Build/Products/Release/muop_agent.app)"

## Đóng gói server + ứng dụng Linux thành một file .deb (build/deb/)
deb:
	FLUTTER=$(FLUTTER) CARGO=$(CARGO) bash packaging/build-deb.sh

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

## Kiểm tra tĩnh mã nguồn Flutter & Rust
analyze:
	$(FLUTTER) analyze
	cd server && $(CARGO) check

clean:
	$(FLUTTER) clean
	cd server && $(CARGO) clean
