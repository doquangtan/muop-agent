import 'package:flutter/material.dart';

import 'agent_core_models.dart';

export 'agent_core_models.dart';

extension AgentWorkflowPhaseUi on AgentWorkflowPhase {
  IconData get icon {
    switch (this) {
      case AgentWorkflowPhase.contractDiscovery:
        return Icons.architecture_rounded;
      case AgentWorkflowPhase.parallelExecution:
        return Icons.call_split_rounded;
      case AgentWorkflowPhase.crossVerification:
        return Icons.verified_rounded;
      case AgentWorkflowPhase.completed:
        return Icons.task_alt_rounded;
    }
  }
}

extension AgentStatusUi on AgentStatus {
  IconData get icon {
    switch (this) {
      case AgentStatus.running:
        return Icons.bolt_rounded;
      case AgentStatus.waiting:
        return Icons.hourglass_top_rounded;
      case AgentStatus.completed:
        return Icons.check_circle_rounded;
      case AgentStatus.error:
        return Icons.error_rounded;
      case AgentStatus.idle:
        return Icons.radio_button_checked_rounded;
    }
  }
}

extension AgentStepUi on AgentStep {
  IconData get icon {
    if (type == 'USER_INPUT') return Icons.person_rounded;
    if (type == 'SYSTEM_MESSAGE') return Icons.hub_rounded;
    if (toolCalls.isNotEmpty) {
      final first = toolCalls.first.name;
      switch (first) {
        case 'read_file':
        case 'view_file_outline':
        case 'view_code_item':
          return Icons.menu_book_rounded;
        case 'write_file':
          return Icons.note_add_rounded;
        case 'edit_file':
          return Icons.edit_note_rounded;
        case 'run_command':
          return Icons.terminal_rounded;
        case 'invoke_subagent':
        case 'define_subagent':
          return Icons.account_tree_rounded;
        case 'send_message':
          return Icons.forward_to_inbox_rounded;
        case 'grep_search':
        case 'find_by_name':
          return Icons.manage_search_rounded;
        default:
          return Icons.build_circle_rounded;
      }
    }
    if (type == 'GENERIC') return Icons.receipt_long_rounded;
    return Icons.psychology_rounded;
  }
}
