package vn.muop.muop_agent

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "vn.muop.muop_agent/file_opener"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Giữ màn hình luôn sáng khi mở ứng dụng muop-agent
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "openFile") {
                    val filePath = call.argument<String>("path") ?: ""
                    if (filePath.isBlank()) {
                        result.error("INVALID_PATH", "Đường dẫn tệp trống", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("NOT_FOUND", "Tệp không tồn tại: $filePath", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                        val ext = file.extension.lowercase()
                        val mimeType = when (ext) {
                            "apk" -> "application/vnd.android.package-archive"
                            "pdf" -> "application/pdf"
                            "json", "yaml", "yml", "toml", "md", "txt", "log",
                            "dart", "rs", "go", "py", "js", "ts", "html", "css", "sh", "xml" -> "text/plain"
                            "png" -> "image/png"
                            "jpg", "jpeg" -> "image/jpeg"
                            "webp" -> "image/webp"
                            "zip" -> "application/zip"
                            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
                        }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(Intent.createChooser(intent, "Mở tệp ${file.name}"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", e.message ?: "Không thể mở tệp", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
