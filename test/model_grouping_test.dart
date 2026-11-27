import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/chat/domain/model_groups.dart';

void main() {
  group('parseModelId', () {
    test('splits a known effort suffix from agy ids', () {
      final parsed = parseModelId('agy:gemini-4-argon-medium');
      expect(parsed.groupId, 'agy:gemini-4-argon');
      expect(parsed.effort, 'medium');
    });

    test('keeps ids without an effort suffix as their own group', () {
      final parsed = parseModelId('agy:gemini-pro-orchestrator-g1-pro');
      expect(parsed.groupId, 'agy:gemini-pro-orchestrator-g1-pro');
      expect(parsed.effort, isNull);
    });

    test('does not treat a trailing number as an effort', () {
      final parsed = parseModelId('claude-cli:claude-sonnet-5-5');
      expect(parsed.groupId, 'claude-cli:claude-sonnet-5-5');
      expect(parsed.effort, isNull);
    });
  });

  group('groupModels', () {
    test('groups efforts under one name and orders them low to max', () {
      final groups = groupModels(
        const [
          'agy:gemini-4-argon-high',
          'agy:gemini-4-argon-low',
          'agy:gemini-4-argon-medium',
          'agy:gemini-3.8-flash-xhigh',
        ],
        const {'agy:gemini-4-argon-medium': 'Gemini 4 Argon (Medium)'},
      );

      expect(groups.length, 2);
      final argon = groups.first;
      expect(argon.id, 'agy:gemini-4-argon');
      expect(argon.label, 'Gemini 4 Argon');
      expect(argon.options.map((o) => o.effort).toList(), [
        'low',
        'medium',
        'high',
      ]);
      expect(groups.last.options.single.effort, 'xhigh');
    });

    test('keeps variant names in parentheses so Orchestrator models stay distinct', () {
      final groups = groupModels(
        const [
          'agy:gemini-pro-orchestrator-neon',
          'agy:gemini-pro-orchestrator',
          'agy:gemini-pro-orchestrator-argon',
        ],
        const {
          'agy:gemini-pro-orchestrator-neon': 'Orchestrator (Neon)',
          'agy:gemini-pro-orchestrator': 'Orchestrator (Carbon)',
          'agy:gemini-pro-orchestrator-argon': 'Orchestrator (Argon)',
        },
      );

      expect(groups.map((g) => g.label).toList(), [
        'Orchestrator (Neon)',
        'Orchestrator (Carbon)',
        'Orchestrator (Argon)',
      ]);
    });

    test('falls back to a title-cased name when no label is known', () {
      final groups = groupModels(const ['agy:gpt-oss-120b-medium'], const {});
      expect(groups.single.label, 'Gpt Oss 120b');
    });

    test('keeps the first-seen order of groups', () {
      final groups = groupModels(const [
        'claude-cli:claude-sonnet-5-5',
        'agy:gemini-4-argon-medium',
        'claude-cli:claude-opus-5-5',
      ], const {});
      expect(groups.map((g) => g.id).toList(), [
        'claude-cli:claude-sonnet-5-5',
        'agy:gemini-4-argon',
        'claude-cli:claude-opus-5-5',
      ]);
    });
  });

  group('ModelGroup.preferredOption', () {
    final group = groupModels(const [
      'agy:gemini-4-argon-low',
      'agy:gemini-4-argon-medium',
      'agy:gemini-4-argon-high',
    ], const {}).single;

    test('defaults to medium when there is no current effort', () {
      expect(group.preferredOption().id, 'agy:gemini-4-argon-medium');
    });

    test('keeps the current effort when the group has it', () {
      expect(
        group.preferredOption(currentEffort: 'high').id,
        'agy:gemini-4-argon-high',
      );
    });

    test('falls back to medium when the current effort is missing', () {
      expect(
        group.preferredOption(currentEffort: 'xhigh').id,
        'agy:gemini-4-argon-medium',
      );
    });

    test('uses the first option when medium is not offered', () {
      final noMedium = groupModels(const [
        'agy:gemini-x-high',
        'agy:gemini-x-low',
      ], const {}).single;
      expect(noMedium.preferredOption().id, 'agy:gemini-x-low');
    });
  });

  group('effortLevels từ server', () {
    test('claude-cli có hậu tố mức được gom theo model gốc', () {
      final groups = groupModels(const [
        'claude-cli:claude-sonnet-5-5-low',
        'claude-cli:claude-sonnet-5-5-high',
        'claude-cli:claude-sonnet-5-5-medium',
      ], const {}, effortLevels: const ['low', 'medium', 'high', 'xhigh', 'max']);
      expect(groups, hasLength(1));
      expect(groups.first.id, 'claude-cli:claude-sonnet-5-5');
      expect(groups.first.options.map((o) => o.effort), ['low', 'medium', 'high']);
    });

    test('mức không có trong danh sách server không bị tách thành hậu tố', () {
      final parsed = parseModelId('claude-cli:claude-x-ultra', levels: const ['low', 'high']);
      expect(parsed.groupId, 'claude-cli:claude-x-ultra');
      expect(parsed.effort, isNull);
    });

    test('danh sách rỗng dùng mức dự phòng', () {
      expect(resolveEffortLevels(const []), kFallbackEffortLevels);
      expect(resolveEffortLevels(const ['low']), ['low']);
    });
  });
}
