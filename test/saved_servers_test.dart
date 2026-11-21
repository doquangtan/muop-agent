import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/connection/domain/saved_servers.dart';

void main() {
  test('địa chỉ mới đứng đầu, bỏ trùng', () {
    expect(rememberServer(['a:1', 'b:2'], 'b:2'), ['b:2', 'a:1']);
    expect(rememberServer(['a:1'], 'c:3'), ['c:3', 'a:1']);
  });

  test('chuỗi rỗng không được ghi nhận', () {
    expect(rememberServer(['a:1'], '   '), ['a:1']);
  });

  test('giữ tối đa kMaxSavedServers mục', () {
    final full = [for (var i = 0; i < kMaxSavedServers; i++) 's$i:1'];
    final out = rememberServer(full, 'new:1');
    expect(out.length, kMaxSavedServers);
    expect(out.first, 'new:1');
    expect(out.contains('s${kMaxSavedServers - 1}:1'), isFalse);
  });

  test('xóa một địa chỉ khỏi danh sách', () {
    expect(forgetServer(['a:1', 'b:2'], ' a:1 '), ['b:2']);
    expect(forgetServer(['a:1'], 'x:9'), ['a:1']);
  });
}
