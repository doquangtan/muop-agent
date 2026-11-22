# Đường dẫn công cụ theo HOME của user (không cố định theo máy). Ghi đè bằng biến môi trường nếu cần.
FLUTTER ?= $(HOME)/flutter-3.47.7/bin/flutter
CARGO ?= $(HOME)/.cargo/bin/cargo

.PHONY: install-desktop-entry run server build-server build build-linux build-apk build-all analyze restart-linux clean start-daemon stop-daemon restart-daemon status-daemon deb

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
