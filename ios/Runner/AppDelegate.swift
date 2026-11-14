import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentInteractionControllerDelegate {
  /// Giữ tham chiếu để UIDocumentInteractionController không bị giải phóng khi đang hiển thị
  private var documentController: UIDocumentInteractionController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MuopFileOpener") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "vn.muop.muop_agent/file_opener",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleFileOpenerCall(call, result: result)
    }
  }

  private func handleFileOpenerCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let path = (args?["path"] as? String) ?? ""
    switch call.method {
    case "saveToDocuments":
      let name = (args?["name"] as? String) ?? ""
      do {
        let saved = try copyToDocuments(sourcePath: path, displayName: name)
        result(saved)
      } catch {
        result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
      }
    case "openFile":
      DispatchQueue.main.async {
        self.presentDocument(path: path, result: result)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Sao chép file tạm vào thư mục Documents của app (hiện trong app Tệp > Trên iPhone > Muop Agent).
  /// Trùng tên thì thêm tiền tố thời gian.
  private func copyToDocuments(sourcePath: String, displayName: String) throws -> String {
    let fileManager = FileManager.default
    let docs = try fileManager.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var destination = docs.appendingPathComponent(displayName)
    if fileManager.fileExists(atPath: destination.path) {
      let stamp = Int(Date().timeIntervalSince1970)
      destination = docs.appendingPathComponent("\(stamp)_\(displayName)")
    }
    try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath), to: destination)
    return destination.path
  }

  /// Mở tệp bằng trình xem nội bộ của iOS (có nút chia sẻ / mở bằng ứng dụng khác)
  private func presentDocument(path: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "NOT_FOUND", message: "Tệp không tồn tại: \(path)", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "NO_VIEW", message: "Không tìm thấy màn hình để mở tệp", details: nil))
      return
    }
    let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    controller.delegate = self
    documentController = controller
    if controller.presentPreview(animated: true) {
      result(true)
    } else if controller.presentOpenInMenu(from: host.view.bounds, in: host.view, animated: true) {
      result(true)
    } else {
      result(FlutterError(code: "OPEN_ERROR", message: "Không có ứng dụng nào mở được tệp này", details: nil))
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return topViewController() ?? UIViewController()
  }
}
