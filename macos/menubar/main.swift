// muop-agent-tray: biểu tượng menu bar của Mướp Agents.
//
// Do MÁY CHỦ khởi chạy (xem server/src/infra/mac_tray.rs), không phụ thuộc app Flutter.
// Helper chỉ nói chuyện với máy chủ qua REST ở 127.0.0.1 và tự thoát khi máy chủ dừng.
// Build: swiftc -O -framework AppKit -o muop-agent-tray main.swift

import Cocoa

// MARK: - Cấu hình

var serverPort = 8787
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = Int(args[i + 1]) {
    serverPort = p
}
let baseURL = "http://127.0.0.1:\(serverPort)"

// MARK: - Thoát

/// Chỉ true khi helper tự thoát (máy chủ mất, helper mồ côi). Quit do HỆ THỐNG yêu cầu (ví dụ hộp thoại
/// "Quit & Reopen" sau khi cấp quyền Ghi màn hình) bị từ chối để biểu tượng không biến mất.
var exitRequested = false

func helperExit() {
    exitRequested = true
    NSApp.terminate(nil)
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return exitRequested ? .terminateNow : .terminateCancel
    }
}
let helperDelegate = HelperDelegate()

// MARK: - Menu bar

final class TrayController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleItem = NSMenuItem(title: "Quay màn hình", action: #selector(toggleScreen), keyEquivalent: "")
    private let copyItem = NSMenuItem(title: "Sao chép địa chỉ RTSP", action: #selector(copyRtspURL), keyEquivalent: "")
    private let openItem = NSMenuItem(title: "Mở Mướp Agents", action: #selector(openApp), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Dừng máy chủ", action: #selector(stopServer), keyEquivalent: "")
    private var rtspURL = ""
    private var offlineCount = 0
    private var timer: Timer?

    override init() {
        super.init()
        if let button = statusItem.button {
            // Luôn có chữ dự phòng: nếu icon không tải được thì nút vẫn hiện được
            if let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Mướp Agents") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = "Mướp"
            }
            button.toolTip = "Mướp Agents"
        }
        let menu = NSMenu()
        for item in [toggleItem, copyItem] {
            item.target = self
            menu.addItem(item)
        }
        copyItem.isEnabled = false
        menu.addItem(.separator())
        openItem.target = self
        menu.addItem(openItem)
        stopItem.target = self
        menu.addItem(stopItem)
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Mỗi 2 giây: máy chủ đã thoát (helper mồ côi, hoặc không trả lời liên tiếp) thì helper cũng thoát
    private func tick() {
        if getppid() == 1 {
            helperExit()
            return
        }
        refresh()
    }

    private func refresh() {
        fetch("/api/screen/status", method: "GET") { [weak self] json in
            DispatchQueue.main.async { self?.apply(json) }
        }
    }

    private func apply(_ status: [String: Any]?) {
        guard let status = status else {
            offlineCount += 1
            if offlineCount >= 3 {
                helperExit()
                return
            }
            toggleItem.title = "Máy chủ đang tắt"
            toggleItem.isEnabled = false
            copyItem.isEnabled = false
            stopItem.isEnabled = false
            return
        }
        offlineCount = 0
        let streaming = status["streaming"] as? Bool ?? false
        let starting = status["starting"] as? Bool ?? false
        let error = status["error"] as? String ?? ""
        rtspURL = status["rtspUrl"] as? String ?? ""

        if starting {
            toggleItem.title = "Đang bật quay màn hình…"
        } else if streaming {
            toggleItem.title = "Tắt quay màn hình"
        } else {
            toggleItem.title = "Quay màn hình"
        }
        toggleItem.isEnabled = true
        toggleItem.state = streaming ? .on : .off
        copyItem.isEnabled = !rtspURL.isEmpty
        stopItem.isEnabled = true
        statusItem.button?.toolTip = error.isEmpty ? "Mướp Agents" : error
    }

    /// GET/POST tới máy chủ; trả về JSON (nil nếu không trả lời)
    private func fetch(_ path: String, method: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: baseURL + path) else { done(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                done(nil)
                return
            }
            done(try? JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        }.resume()
    }

    @objc private func toggleScreen() {
        fetch("/api/screen/toggle", method: "POST") { _ in
            // Bật cần vài giây (ffmpeg khởi động): hỏi lại sau đó
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    @objc private func copyRtspURL() {
        guard !rtspURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rtspURL, forType: .string)
    }

    /// Mở app Flutter theo bundle id (không hardcode đường dẫn cài đặt)
    @objc private func openApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", "vn.muop.agents"]
        try? task.run()
    }

    /// Dừng máy chủ: hỏi xác nhận vì mọi client đang kết nối sẽ bị ngắt
    @objc private func stopServer() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dừng máy chủ Mướp Agents?"
        alert.informativeText = "Mọi client đang kết nối sẽ bị ngắt và quay màn hình sẽ tắt. Máy chủ sẽ tự khởi động lại khi bạn đăng nhập lần sau."
        alert.addButton(withTitle: "Dừng máy chủ")
        alert.addButton(withTitle: "Hủy")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        fetch("/api/server/shutdown", method: "POST") { _ in
            // Máy chủ thoát sau ~0.3 giây; helper thấy máy chủ mất rồi tự thoát ở lần kiểm tra kế tiếp
        }
    }
}

// MARK: - Khởi chạy

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = helperDelegate
let tray = TrayController()
app.run()
