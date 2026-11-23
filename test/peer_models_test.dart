import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/bridge/domain/peer_models.dart';
import 'package:muop_agent/features/chat/domain/model_groups.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

void main() {
  test('peer ids round-trip through the prefix', () {
    final id = toPeerModelId('claude-cli:claude-haiku-5-5-low');
    expect(id, 'peer:claude-cli:claude-haiku-5-5-low');
    expect(isPeerModel(id), isTrue);
    expect(remoteModelId(id), 'claude-cli:claude-haiku-5-5-low');
    // Id máy đang kết nối không bị đổi
    expect(isPeerModel('agy:gemini-4-argon-low'), isFalse);
    expect(remoteModelId('agy:gemini-4-argon-low'), 'agy:gemini-4-argon-low');
  });

  test('merge keeps local models first and drops duplicates', () {
    final merged = mergeModelLists(
      ['claude-cli:claude-sonnet-5-5-low', 'agy:gemini-4-argon-low'],
      ['peer:claude-cli:claude-sonnet-5-5-low', 'peer:agy:gemini-4-argon-low', 'peer:claude-cli:claude-sonnet-5-5-low'],
    );
    expect(merged, [
      'claude-cli:claude-sonnet-5-5-low',
      'agy:gemini-4-argon-low',
      'peer:claude-cli:claude-sonnet-5-5-low',
      'peer:agy:gemini-4-argon-low',
    ]);
  });

  test('peer labels have no machine prefix; the machine name is on the menu section header', () {
    final labels = peerModelLabels(
      remoteModels: ['claude-cli:claude-haiku-5-5-low', 'claude-cli:claude-haiku-5-5-high'],
      remoteLabels: {'claude-cli:claude-haiku-5-5-low': 'Claude Haiku 5.5 (Low)'},
    );
    expect(labels['peer:claude-cli:claude-haiku-5-5-low'], 'Claude Haiku 5.5 (Low)');
    // Không có nhãn từ máy phụ: dùng id gốc
    expect(labels['peer:claude-cli:claude-haiku-5-5-high'], 'claude-cli:claude-haiku-5-5-high');

    // Nhóm model: mức suy luận được tách, tên nhóm không có tiền tố máy
    final groups = groupModels(
      ['peer:claude-cli:claude-haiku-5-5-low', 'peer:claude-cli:claude-haiku-5-5-high'],
      labels,
    );
    expect(groups, hasLength(1));
    expect(groups.first.label, 'Claude Haiku 5.5');
    expect(groups.first.options.map((o) => o.effort), ['low', 'high']);
  });

  test('chat is blocked only for a peer model while the peer is disconnected', () {
    expect(
      peerBlockReason(model: 'peer:claude-cli:claude-haiku-5-5-low', connected: false, host: 'Laptop'),
      contains('Mất kết nối tới máy phụ Laptop'),
    );
    expect(
      peerBlockReason(model: 'peer:claude-cli:claude-haiku-5-5-low', connected: true, host: 'Laptop'),
      isNull,
    );
    // Model của máy đang kết nối không bị khóa khi máy phụ mất kết nối
    expect(
      peerBlockReason(model: 'claude-cli:claude-sonnet-5-5-low', connected: false, host: 'Laptop'),
      isNull,
    );
  });

  test('a conversation from the peer selects the peer model it was run with', () {
    final json = asPeerSessionJson({
      'id': 'cid-1',
      'title': 'Sửa login',
      'status': 'completed',
      'selectedModel': 'claude-cli:claude-haiku-5-5-low',
      'source': 'claude-cli',
      'projectPath': '/home/john/du-an',
      'updatedAt': '2026-11-22T00:00:00+00:00',
      'createdAt': '2026-11-22T00:00:00+00:00',
    });
    expect(json['selectedModel'], 'peer:claude-cli:claude-haiku-5-5-low');

    final session = ConversationSession.fromJson(json);
    expect(session.id, 'cid-1');
    expect(session.selectedModel, 'peer:claude-cli:claude-haiku-5-5-low');
    // Thư mục project giữ nguyên: máy phụ dùng chung đường dẫn
    expect(session.projectPath, '/home/john/du-an');
  });

  test('a peer conversation without a recorded model keeps an empty selection', () {
    expect(asPeerSessionJson({'id': 'cid-2', 'selectedModel': ''})['selectedModel'], '');
    expect(asPeerSessionJson({'id': 'cid-3'})['selectedModel'], '');
  });

  test('tiêu đề conversation máy phụ không gắn tag chữ, bỏ nhãn [Từ máy] của bản cũ', () {
    expect(peerSessionTitle(title: 'tạo file mèo'), 'tạo file mèo');
    expect(peerSessionTitle(title: '  '), '(không tiêu đề)');
    expect(
      peerSessionTitle(title: '[Từ máy ASRock-X99] Tạo file mèo'),
      'Tạo file mèo',
    );
  });
}
