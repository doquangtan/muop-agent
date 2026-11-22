/// Ghép đường dẫn trên máy chủ (Linux) từ thư mục gốc và tên mục con.
/// Gốc lấy từ server (`meta.workspaceRoot`); không có gốc thì trả về tên, không đoán đường dẫn.
String joinServerPath(String base, String name) {
  final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  if (root.isEmpty) return name;
  return '$root/$name';
}
