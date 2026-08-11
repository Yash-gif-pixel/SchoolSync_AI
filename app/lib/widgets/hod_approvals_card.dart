import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

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
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'.replaceFirst('Exception: ', '')),
          backgroundColor: AppColors.danger,
        ));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingApprovalsProvider);

    return pending.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.lg),
          child: SectionCard(
            title: 'Awaiting your approval',
            subtitle: 'Leave requests from your department',
            icon: Icons.approval_outlined,
            tone: Tone.danger,
            accentBorder: AppColors.danger,
            trailing: StatusPill(label: '${list.length}', tone: Tone.danger),
            child: Column(children: [
              for (final l in list)
                _Row(
                  leave: l,
                  busy: _busyId == l.id,
                  onApprove: () => _review(l, true),
                  onReject: () => _review(l, false),
                ),
            ]),
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

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(leave.teacherName ?? 'A teacher',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        Text(
          [leave.dateRange, ?leave.reason].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall,
        ),
      ],
    );

    final buttons = busy
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(onPressed: onReject, child: const Text('Reject')),
            const SizedBox(width: AppSpace.sm),
            FilledButton(
              onPressed: onApprove,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Approve'),
            ),
          ]);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      // Two buttons plus a name will not fit beside each other on a phone, so
      // below 420 the actions move onto their own line rather than being
      // squeezed until something overflows.
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              details,
              const SizedBox(height: AppSpace.md),
              Align(alignment: Alignment.centerRight, child: buttons),
            ],
          );
        }
        return Row(children: [
          Expanded(child: details),
          const SizedBox(width: AppSpace.sm),
          buttons,
        ]);
      }),
    );
  }
}
