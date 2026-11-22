import 'package:muop_agent/features/bridge/domain/bridge_entities.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Interface (domain) của feature bridge. Presentation chỉ phụ thuộc interface này.
/// Mọi lời gọi đi tới server đang kết nối (`address`), server đó chuyển tiếp tới máy A.
abstract class BridgeRepository {
  Future<BridgeStatus> fetchStatus(String address);

  /// Đặt địa chỉ máy A và kết nối lại. `url` rỗng = ngắt kết nối.
  Future<BridgeStatus> setPeer(String address, {required String url});

  /// Gửi lượt chat tới agent trên máy A. `conversationId` rỗng = conversation mới.
  /// `images` là ảnh đính kèm dạng JSON của chat (`name`, `mimeType`, `dataBase64`).
  Future<BridgeSendResult> sendPrompt(
    String address, {
    required String prompt,
    required String projectPath,
    String conversationId = '',
    String model = '',
    List<Map<String, dynamic>> images = const [],
  });

  /// Tên máy A và danh sách model của máy A
  Future<PeerMeta> fetchPeerMeta(String address);

  /// Danh sách conversation trên máy A (dạng summary, như `sessions:list`)
  Future<List<Map<String, dynamic>>> fetchPeerSessions(String address);

  /// Chi tiết một conversation trên máy A (đầy đủ steps). Null nếu không lấy được.
  Future<Map<String, dynamic>?> fetchPeerSession(String address, {required String id});

  Future<BridgeSendResult> stopTurn(
    String address, {
    required String conversationId,
  });

  /// Tương tác Claude đang chờ phản hồi trên máy A. `interaction` null = không có việc chờ.
  Future<({PendingClaudeInteraction? interaction, String error})> fetchPendingInteraction(
    String address, {
    required String conversationId,
  });

  /// Trả lời câu hỏi hoặc duyệt/góp ý kế hoạch của Claude trên máy A.
  /// Trả về null nếu thành công, ngược lại là thông báo lỗi.
  Future<String?> respondInteraction(
    String address, {
    required String conversationId,
    required String toolUseId,
    required String projectPath,
    required String model,
    required String decision,
    List<Map<String, String>> answers = const [],
    String feedback = '',
  });

  /// Sự kiện do server chuyển tiếp từ máy A (`bridge:*`), theo server đang kết nối
  Stream<BridgeEvent> watchEvents();
}
