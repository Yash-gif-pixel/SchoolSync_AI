import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/operations_repository.dart';

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
    final theme = Theme.of(context);
    final connected = !live.isLoading && !live.hasError;

    final needsAction = board.whenOrNull(data: (b) => b.needsAction) ?? 0;
    final urgent = needsAction > 0;

    return Card(
      elevation: 0,
      color: urgent
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/action-board'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  urgent ? Icons.notifications_active : Icons.notifications_none,
                  color: urgent
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text('Action Board', style: theme.textTheme.titleMedium),
                const SizedBox(width: 10),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? Colors.green.shade500
                        : theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 5),
                Text(connected ? 'live' : 'offline',
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                const Icon(Icons.chevron_right),
              ]),
              const SizedBox(height: 6),
              Text(
                'Approved leave appears here with ranked cover suggestions, '
                'the moment it is approved.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              board.when(
                loading: () => const SizedBox(
                  height: 22, width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Text('Board unavailable',
                    style: TextStyle(color: theme.colorScheme.error)),
                data: (b) {
                  if (b.groups.isEmpty) {
                    return Row(children: [
                      Icon(Icons.check_circle_outline,
                          size: 16, color: Colors.green.shade600),
                      const SizedBox(width: 8),
                      const Text('Nothing needs attention.'),
                    ]);
                  }
                  return Wrap(spacing: 10, runSpacing: 10, children: [
                    _Pill(
                      value: '${b.needsAction}',
                      label: 'periods to cover',
                      colour: b.needsAction > 0
                          ? theme.colorScheme.error
                          : Colors.green.shade600,
                    ),
                    _Pill(
                      value: '${b.groups.length}',
                      label: 'absences',
                      colour: theme.colorScheme.primary,
                    ),
                    _Pill(
                      value: '${b.totalPeriods - b.needsAction}',
                      label: 'already covered',
                      colour: Colors.green.shade600,
                    ),
                  ]);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.value, required this.label, required this.colour});
  final String value;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour.withValues(alpha: 0.30)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600, color: colour)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
