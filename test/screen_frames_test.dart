import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/screen/data/screen_repository_impl.dart';
import 'package:muop_agent/features/screen/domain/screen_entities.dart';

void main() {
  test('ScreenStatus đọc viewerUrl và các trường trạng thái', () {
    final s = ScreenStatus.fromJson({
      'streaming': true,
      'starting': false,
      'error': '',
      'height': 720,
      'viewerUrl': 'http://192.168.1.10:8788/',
    });
    expect(s.streaming, isTrue);
    expect(s.height, 720);
    expect(s.viewerUrl, 'http://192.168.1.10:8788/');
  });

  test('viewerUrl thay host bằng địa chỉ server đang kết nối', () {
    final repo = ScreenRepositoryImpl(
      SocketGateway(),
      baseUrlOf: () => 'http://10.0.0.7:8787',
    );
    expect(
      repo.viewerUrl('http://192.168.1.10:8788/'),
      'http://10.0.0.7:8788/',
    );
  });

  test('watchFrames lấy khung kế tiếp theo seq và dừng khi hủy', () async {
    final afters = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final req in server) {
        final after = int.parse(req.uri.queryParameters['after'] ?? '0');
        afters.add('$after');
        if (after == 0) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.set('x-frame-seq', '1')
            ..add([1, 2, 3]);
        } else if (after == 1) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.set('x-frame-seq', '2')
            ..add([4]);
        } else {
          // Hết giờ đợi, không có khung mới
          req.response.statusCode = HttpStatus.noContent;
        }
        await req.response.close();
      }
    }());

    final repo = ScreenRepositoryImpl(
      SocketGateway(),
      baseUrlOf: () => 'http://127.0.0.1:${server.port}',
    );
    final frames = <ScreenFrame>[];
    final sub = repo.watchFrames().listen(frames.add);
    while (frames.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await sub.cancel();

    expect(frames.map((f) => f.seq), [1, 2]);
    expect(frames[0].jpeg, [1, 2, 3]);
    expect(frames[1].jpeg, [4]);
    // Yêu cầu sau khung 2 phải dừng: không gọi thêm sau khi hủy
    final count = afters.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(afters.length, lessThanOrEqualTo(count + 1));
    expect(afters.take(2), ['0', '1']);
  });
}
