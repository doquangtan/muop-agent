FLUTTER=/home/john/flutter/bin/flutter
CARGO=/home/john/.cargo/bin/cargo

.PHONY: run server build-server build build-linux build-apk build-all analyze restart-linux clean start-daemon stop-daemon restart-daemon status-daemon

## Chạy ứng dụng giao diện Flutter trên Linux Desktop
run:
	$(FLUTTER) run -d linux

## Build và khởi chạy Rust Backend Server (Axum + Socket.IO) trên cổng 8787
server:
	cd server && $(CARGO) run --release

## Quản lý Daemon Rust Server qua systemd user service
install-service:
	@mkdir -p $(HOME)/.config/systemd/user
	@cp -f service/muop-agent-server.service $(HOME)/.config/systemd/user/muop-agent-server.service 2>/dev/null || true
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

## Build bản thực thi Linux Desktop Release và tự động restart nếu đang chạy
build: build-linux

build-linux:
	$(FLUTTER) build linux --release
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
