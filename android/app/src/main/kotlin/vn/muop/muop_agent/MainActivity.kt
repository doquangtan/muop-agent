package vn.muop.muop_agent

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

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
                when (call.method) {
                    "openFile" -> openFile(call.argument<String>("path") ?: "", result)
                    "saveToDownloads" -> saveToDownloads(
                        call.argument<String>("path") ?: "",
                        call.argument<String>("name") ?: "",
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun mimeFor(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return when (ext) {
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
    }

    /// Sao chép file tạm sang thư mục Downloads công khai qua MediaStore (Android 10+, không cần quyền ghi).
    /// Trả về content URI để mở lại tệp.
    private fun saveToDownloads(sourcePath: String, displayName: String, result: MethodChannel.Result) {
        if (sourcePath.isBlank() || displayName.isBlank()) {
            result.error("INVALID_ARGS", "Thiếu đường dẫn hoặc tên tệp", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Cần Android 10 trở lên để lưu vào Downloads", null)
            return
        }
        val source = File(sourcePath)
        if (!source.exists()) {
            result.error("NOT_FOUND", "Tệp tạm không tồn tại: $sourcePath", null)
            return
        }
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeFor(displayName))
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        var uri: Uri? = null
        try {
            val created = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("Không tạo được mục trong Downloads")
            uri = created
            val out = resolver.openOutputStream(created)
                ?: throw IOException("Không mở được luồng ghi Downloads")
            out.use { stream -> source.inputStream().use { it.copyTo(stream) } }
            val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(created, done, null, null)
            result.success(created.toString())
        } catch (e: Exception) {
            uri?.let { resolver.delete(it, null, null) }
            result.error("SAVE_ERROR", e.message ?: "Không lưu được vào Downloads", null)
        }
    }

    private fun openFile(filePath: String, result: MethodChannel.Result) {
        if (filePath.isBlank()) {
            result.error("INVALID_PATH", "Đường dẫn tệp trống", null)
            return
        }
        try {
            // Tệp đã nằm trong Downloads (MediaStore): mở bằng content URI có sẵn
            if (filePath.startsWith("content://")) {
                val contentUri = Uri.parse(filePath)
                val mimeType = contentResolver.getType(contentUri) ?: "*/*"
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(contentUri, mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(Intent.createChooser(intent, "Mở tệp"))
                result.success(true)
                return
            }

            val file = File(filePath)
            if (!file.exists()) {
                result.error("NOT_FOUND", "Tệp không tồn tại: $filePath", null)
                return
            }
            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeFor(file.name))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "Mở tệp ${file.name}"))
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_ERROR", e.message ?: "Không thể mở tệp", null)
        }
    }
}
