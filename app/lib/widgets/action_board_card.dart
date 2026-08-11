import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/operations_repository.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

/// Admin dashboard summary of cover needing a decision.
///
/// Subscribed to the same realtime channel as the board itself, so the count
/// changes the instant an HOD approves leave — the administrator is told,
/// rather than having to go and look.
class ActionBoardCard extends ConsumerWidget {
  const ActionBoardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(actionBoardProvider);
    final live = ref.watch(coverChangesProvider);
    final connected = !live.isLoading && !live.hasError;
    final needsAction = board.whenOrNull(data: (b) => b.needsAction) ?? 0;

    return SectionCard(
      title: 'Action Board',
      subtitle: 'Approved leave arrives here with ranked cover suggestions',
      icon: Icons.notifications_none_rounded,
      tone: needsAction > 0 ? Tone.danger : Tone.brand,
      accentBorder: needsAction > 0 ? Tone.danger.fg : null,
      trailing: _LiveDot(connected: connected),
      onTap: () => context.go('/action-board'),
      child: board.when(
        loading: () => const SizedBox(
          height: 22, width: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (e, _) => const Callout(
          tone: Tone.danger,
          message: 'Board unavailable',
        ),
        data: (b) {
          if (b.groups.isEmpty) {
            return const Callout(
              tone: Tone.success,
              message: 'Nothing needs your attention.',
            );
          }
          return Wrap(spacing: AppSpace.md, runSpacing: AppSpace.md, children: [
            StatTile(
              value: '${b.needsAction}',
              label: 'periods to cover',
              tone: b.needsAction > 0 ? Tone.danger : Tone.success,
              width: 150,
            ),
            StatTile(
              value: '${b.groups.length}',
              label: 'absences',
              tone: Tone.brand,
              width: 150,
            ),
            StatTile(
              value: '${b.totalPeriods - b.needsAction}',
              label: 'already covered',
              tone: Tone.success,
              width: 150,
            ),
          ]);
        },
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: connected
          ? 'Connected — new absences appear without a refresh'
          : 'Reconnecting…',
      child: StatusPill(
        label: connected ? 'live' : 'offline',
        tone: connected ? Tone.success : Tone.neutral,
        icon: connected ? Icons.circle : Icons.circle_outlined,
      ),
    );
  }
}
