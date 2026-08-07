import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';

/// The head of department's review queue.
///
/// Only rendered for a teacher with `is_approver`, which is what keeps routine
/// leave decisions off the administrator's desk. Approving here immediately
/// runs the substitution matcher, so the admin's Action Board fills in without
/// anyone telling it to.
class HodApprovalsCard extends ConsumerStatefulWidget {
  const HodApprovalsCard({super.key});

  @override
  ConsumerState<HodApprovalsCard> createState() => _HodApprovalsCardState();
}

class _HodApprovalsCardState extends ConsumerState<HodApprovalsCard> {
  String? _busyId;

  Future<void> _review(LeaveRequest l, bool approve) async {
    setState(() => _busyId = l.id);
    try {
      final res = await ref
          .read(operationsRepositoryProvider)
          .reviewLeave(l.id, approve: approve);
      ref.invalidate(pendingApprovalsProvider);

      if (!mounted) return;
      final affected = res['periods_affected'] as int? ?? 0;
      final uncovered = res['periods_without_cover'] as int? ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(approve
            ? '${l.teacherName ?? 'Leave'} approved — $affected period(s) need '
                'cover, suggestions sent to the Action Board'
                '${uncovered > 0 ? ' ($uncovered with nobody free)' : ''}.'
            : 'Request rejected.'),
        backgroundColor: approve ? Colors.green.shade700 : null,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'.replaceFirst('Exception: ', '')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingApprovalsProvider);
    final theme = Theme.of(context);

    return pending.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();

        return Card(
          elevation: 0,
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.approval_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Awaiting your approval',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${list.length}'),
                    backgroundColor: theme.colorScheme.error,
                    labelStyle: const TextStyle(color: Colors.white),
                  ),
                ]),
                const SizedBox(height: 4),
                Text('Leave from your department.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 14),
                for (final l in list)
                  _Row(
                    leave: l,
                    busy: _busyId == l.id,
                    onApprove: () => _review(l, true),
                    onReject: () => _review(l, false),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.leave,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final LeaveRequest leave;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(leave.teacherName ?? 'A teacher',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              [
                leave.dateRange,
                if (leave.reason != null) leave.reason!,
              ].join(' · '),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          TextButton(onPressed: onReject, child: const Text('Reject')),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: onApprove,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Approve'),
          ),
        ],
      ]),
    );
  }
}
