import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Server đi kèm trong app (`Contents/Helpers/muop-agent-server`). Chỉ giữ khi app tự khởi động nó.
  private var serverProcess: Process?
  private let pingURL = URL(string: "http://127.0.0.1:8787/api/ping")!

  /// Menu bar (thay cho system tray của Linux): bật/tắt quay màn hình qua REST của server
  private var statusItem: NSStatusItem?
  private var screenToggleItem: NSMenuItem?
  private var copyRtspItem: NSMenuItem?
  private var stopServerItem: NSMenuItem?
  private var pollTimer: Timer?
  private var rtspURL = ""
  private let screenStatusURL = URL(string: "http://127.0.0.1:8787/api/screen/status")!
  private let screenToggleURL = URL(string: "http://127.0.0.1:8787/api/screen/toggle")!
  private let serverShutdownURL = URL(string: "http://127.0.0.1:8787/api/server/shutdown")!

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    Task { await startBundledServerIfNeeded() }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    pollTimer?.invalidate()
    // Không tắt server khi thoát client: server tiếp tục chạy (kể cả luồng quay màn hình).
    // Lần mở app sau sẽ dùng lại server đang chạy ở cổng 8787.
  }

  // MARK: - Menu bar

  /// Nhật ký chẩn đoán menu bar: ~/Library/Logs/muop-agent/menubar.log
  private func menuLog(_ message: String) {
    let dir = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/muop-agent", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("menubar.log")
    guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      handle.closeFile()
    } else {
      try? data.write(to: url)
    }
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      // Không có icon thì nút có độ rộng 0 và macOS không hiện gì: luôn có chữ dự phòng
      if let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Mướp Agents") {
        icon.isTemplate = true
        button.image = icon
      } else {
        button.title = "Mướp"
      }
      button.toolTip = "Mướp Agents"
    }
    menuLog("setup: statusItem created, button=\(item.button != nil), image=\(item.button?.image != nil), title=\(item.button?.title ?? "")")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self = self else { return }
      let window = item.button?.window
      self.menuLog("check: window=\(window != nil) visible=\(window?.isVisible ?? false) frame=\(String(describing: window?.frame)) level=\(window?.level.rawValue ?? -1)")
    }

    let menu = NSMenu()
    let toggle = NSMenuItem(title: "Quay màn hình", action: #selector(toggleScreen), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)

    let copy = NSMenuItem(title: "Sao chép địa chỉ RTSP", action: #selector(copyRtspURL), keyEquivalent: "")
    copy.target = self
    copy.isEnabled = false
    menu.addItem(copy)

    menu.addItem(.separator())
    let open = NSMenuItem(title: "Mở Mướp Agents", action: #selector(openMainWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)

    let stop = NSMenuItem(title: "Dừng máy chủ", action: #selector(stopServer), keyEquivalent: "")
    stop.target = self
    stop.isEnabled = false
    menu.addItem(stop)

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    item.menu = menu
    statusItem = item
    screenToggleItem = toggle
    copyRtspItem = copy
    stopServerItem = stop

    refreshScreenStatus()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.refreshScreenStatus()
    }
  }

  /// Hỏi server trạng thái quay màn hình rồi cập nhật menu (chạy nền, cập nhật trên main thread)
  private func refreshScreenStatus() {
    var request = URLRequest(url: screenStatusURL)
    request.timeoutInterval = 2
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      let status = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      DispatchQueue.main.async { self?.updateScreenMenu(status) }
    }.resume()
  }

  private func updateScreenMenu(_ status: [String: Any]?) {
    guard let toggle = screenToggleItem else { return }
    // Không có trả lời từ server nghĩa là máy chủ đang tắt: khóa các mục điều khiển
    let online = status != nil
    let streaming = status?["streaming"] as? Bool ?? false
    let starting = status?["starting"] as? Bool ?? false
    let error = status?["error"] as? String ?? ""
    rtspURL = status?["rtspUrl"] as? String ?? ""

    if !online {
      toggle.title = "Máy chủ đang tắt"
    } else if starting {
      toggle.title = "Đang bật quay màn hình…"
    } else if streaming {
      toggle.title = "Tắt quay màn hình"
    } else {
      toggle.title = "Quay màn hình"
    }
    toggle.isEnabled = online
    toggle.state = streaming ? .on : .off
    copyRtspItem?.isEnabled = online && !rtspURL.isEmpty
    stopServerItem?.isEnabled = online
    statusItem?.button?.toolTip = error.isEmpty ? "Mướp Agents" : error
  }

  @objc private func toggleScreen() {
    var request = URLRequest(url: screenToggleURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
      // Bật cần vài giây (ffmpeg khởi động): hỏi lại sau đó
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshScreenStatus() }
    }.resume()
  }

  /// Dừng server đang chạy (cả app đi kèm lẫn server chạy tay). Hỏi xác nhận vì client khác sẽ bị ngắt.
  @objc private func stopServer() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Dừng máy chủ Mướp Agents?"
    alert.informativeText = "Mọi client đang kết nối sẽ bị ngắt và quay màn hình sẽ tắt. Mở lại app sẽ khởi động lại máy chủ."
    alert.addButton(withTitle: "Dừng máy chủ")
    alert.addButton(withTitle: "Hủy")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    var request = URLRequest(url: serverShutdownURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
      // Server thoát sau ~0.3 giây: hỏi lại trạng thái để menu chuyển sang "Máy chủ đang tắt"
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshScreenStatus() }
    }.resume()
  }

  @objc private func copyRtspURL() {
    guard !rtspURL.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(rtspURL, forType: .string)
  }

  @objc private func openMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }

  /// Server đã trả lời ở cổng 8787 (chạy tay hoặc từ app khác) thì dùng luôn, không chạy thêm bản thứ hai
  private func serverAnswers() async -> Bool {
    var request = URLRequest(url: pingURL)
    request.timeoutInterval = 1
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  private func startBundledServerIfNeeded() async {
    if await serverAnswers() { return }
    // Server nằm trong Contents/Helpers của chính app (đường dẫn tương đối với bundle, không hardcode máy)
    let binary = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/muop-agent-server")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      NSLog("muop-agent: không tìm thấy muop-agent-server trong app")
      return
    }
    // Nhật ký server: ~/Library/Logs/muop-agent/server.log
    let logDir = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/muop-agent", isDirectory: true)
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logURL = logDir.appendingPathComponent("server.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)

    let process = Process()
    process.executableURL = binary
    if let log = try? FileHandle(forWritingTo: logURL) {
      process.standardOutput = log
      process.standardError = log
    }
    do {
      try process.run()
      serverProcess = process
    } catch {
      NSLog("muop-agent: không chạy được server: \(error.localizedDescription)")
    }
  }
}
