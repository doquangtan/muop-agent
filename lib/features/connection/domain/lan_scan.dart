/// Quét mạng LAN tìm máy chủ muop-agent. Thuần Dart, không phụ thuộc IO (test được).
library;

/// Máy chủ tìm thấy khi quét: đã trả lời `/api/ping` đúng định dạng của muop-agent.
class LanServer {
  const LanServer({required this.ip, this.hostname = '', this.engine = ''});

  final String ip;
  final String hostname;
  final String engine;
}

/// Tên `app` mà server trả trong `/api/ping`
const String kMuopServerAppName = 'muop-agent-rust-server';

/// Dải IP cần quét từ danh sách IPv4 của máy client: mỗi địa chỉ LAN lấy dải /24 của nó
/// (`a.b.c.1` … `a.b.c.254`). Bỏ loopback và link-local (169.254.x.x). Không trùng dải.
List<String> lanHostsFor(Iterable<String> localIpv4) {
  final prefixes = <String>[];
  for (final ip in localIpv4) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) continue;
    if (parts[0] == '127' || (parts[0] == '169' && parts[1] == '254')) continue;
    final prefix = parts.take(3).join('.');
    if (!prefixes.contains(prefix)) prefixes.add(prefix);
  }
  return [
    for (final prefix in prefixes)
      for (var host = 1; host <= 254; host++) '$prefix.$host',
  ];
}

/// Interface ảo (Docker, libvirt, VPN, tunnel...) không phải mạng LAN của máy: bỏ qua khi quét.
final RegExp _virtualInterface = RegExp(
  r'^(lo|docker|br-|virbr|veth|vmnet|vboxnet|wt\d|tun|tap|tailscale|utun|zt|wg)',
);

bool isVirtualInterfaceName(String name) => _virtualInterface.hasMatch(name);

/// `true` nếu JSON trả từ `/api/ping` là của muop-agent server
bool isMuopServerPing(Map<dynamic, dynamic> json) =>
    '${json['app'] ?? ''}' == kMuopServerAppName;

/// Sắp xếp theo địa chỉ IP (so từng octet theo số, không theo chữ)
List<LanServer> sortByIp(List<LanServer> servers) {
  List<int> key(String ip) =>
      ip.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final sorted = [...servers]..sort((a, b) {
    final ka = key(a.ip);
    final kb = key(b.ip);
    for (var i = 0; i < 4; i++) {
      final c = ka[i].compareTo(kb[i]);
      if (c != 0) return c;
    }
    return 0;
  });
  return sorted;
}
