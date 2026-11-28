/// localStorage của trình duyệt. Chỉ web có; native và test trên VM dùng bản trống (không đọc được gì).
library;

export 'web_local_storage_stub.dart'
    if (dart.library.io) 'web_local_storage_stub.dart'
    if (dart.library.js_interop) 'web_local_storage_web.dart';
