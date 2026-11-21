/// Danh sách server đã kết nối trước đây (mới nhất đứng đầu). Thuần Dart, không phụ thuộc IO.
const int kMaxSavedServers = 10;

/// Đưa [address] lên đầu danh sách (bỏ trùng, giữ tối đa [kMaxSavedServers] mục)
List<String> rememberServer(List<String> servers, String address) {
  final clean = address.trim();
  if (clean.isEmpty) return List.of(servers);
  return [clean, ...servers.where((s) => s != clean)]
      .take(kMaxSavedServers)
      .toList();
}

/// Bỏ [address] khỏi danh sách
List<String> forgetServer(List<String> servers, String address) =>
    servers.where((s) => s != address.trim()).toList();
