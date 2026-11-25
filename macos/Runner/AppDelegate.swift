import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Server đi kèm trong app (`Contents/Helpers/muop-agent-server`). Chỉ giữ khi app tự khởi động nó.
  private var serverProcess: Process?
  private let pingURL = URL(string: "http://127.0.0.1:8787/api/ping")!

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await startBundledServerIfNeeded() }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    serverProcess?.terminate()
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
