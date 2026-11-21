import 'package:flutter_test/flutter_test.dart';

import 'package:muop_agent/features/connection/domain/lan_scan.dart';

void main() {
  test('lanHostsFor: một dải /24 cho mỗi IP LAN, bỏ loopback và link-local', () {
    final hosts = lanHostsFor(['192.168.31.10', '127.0.0.1', '169.254.3.4']);
    expect(hosts.length, 254);
    expect(hosts.first, '192.168.31.1');
    expect(hosts.last, '192.168.31.254');
    expect(hosts.any((h) => h.startsWith('127.')), isFalse);
    expect(hosts.any((h) => h.startsWith('169.254.')), isFalse);
  });

  test('lanHostsFor: hai IP cùng dải chỉ quét một lần', () {
    final hosts = lanHostsFor(['10.0.0.5', '10.0.0.77', '172.16.1.2']);
    expect(hosts.length, 508);
    expect(hosts.where((h) => h == '10.0.0.1').length, 1);
  });

  test('lanHostsFor: bỏ địa chỉ sai định dạng', () {
    expect(lanHostsFor(['abc', '1.2.3']), isEmpty);
  });

  test('isMuopServerPing nhận đúng server muop-agent', () {
    expect(isMuopServerPing({'app': 'muop-agent-rust-server'}), isTrue);
    expect(isMuopServerPing({'app': 'other'}), isFalse);
    expect(isMuopServerPing({}), isFalse);
  });

  test('sortByIp sắp xếp theo số, không theo chữ', () {
    final sorted = sortByIp(const [
      LanServer(ip: '192.168.31.100'),
      LanServer(ip: '192.168.31.20'),
      LanServer(ip: '10.0.0.9'),
    ]).map((s) => s.ip).toList();
    expect(sorted, ['10.0.0.9', '192.168.31.20', '192.168.31.100']);
  });

  test('isVirtualInterfaceName bỏ interface ảo, giữ card mạng thật', () {
    for (final name in ['docker0', 'br-6ecf61f62828', 'virbr0', 'veth1a2b', 'wt0', 'tailscale0', 'lo']) {
      expect(isVirtualInterfaceName(name), isTrue, reason: name);
    }
    for (final name in ['enp5s0', 'eth0', 'wlan0', 'wlp3s0']) {
      expect(isVirtualInterfaceName(name), isFalse, reason: name);
    }
  });
}
