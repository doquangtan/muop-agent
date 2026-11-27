import Cocoa
import FlutterMacOS

/// App Flutter chỉ là CLIENT. Máy chủ là LaunchAgent riêng (`vn.muop.agent-server`) và biểu tượng menu bar
/// do máy chủ khởi chạy: thoát app không ảnh hưởng đến máy chủ đang chạy nền.
@main
class AppDelegate: FlutterAppDelegate {
  private let pingURL = URL(string: "http://127.0.0.1:8787/api/ping")!

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    Task { await ensureServerRunning() }
  }

  /// Máy chủ chưa trả lời (chưa cài LaunchAgent, hoặc đã dừng thủ công): nhờ launchd khởi động lại.
  /// Không sở hữu tiến trình máy chủ; nếu LaunchAgent chưa được cài thì lệnh này không làm gì.
  private func ensureServerRunning() async {
    if await serverAnswers() { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["kickstart", "gui/\(getuid())/vn.muop.agent-server"]
    do {
      try task.run()
    } catch {
      NSLog("muop-agent: không gọi được launchctl: \(error.localizedDescription)")
    }
  }

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
}
