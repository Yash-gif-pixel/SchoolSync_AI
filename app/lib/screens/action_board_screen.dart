import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';
import '../models/timetable.dart' show dayNames;
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

/// Cover that needs an administrator's decision.
///
/// Proactive by design: it is a queue of things needing action, not something
/// to go looking for. Absences appear here the moment an HOD approves leave,
/// pushed over a websocket — no refresh, no polling.
class ActionBoardScreen extends ConsumerStatefulWidget {
  const ActionBoardScreen({super.key});

  @override
  ConsumerState<ActionBoardScreen> createState() => _ActionBoardScreenState();
}

class _ActionBoardScreenState extends ConsumerState<ActionBoardScreen> {
  String? _busyId;

  Future<void> _confirm(CoverCandidate c) async {
    setState(() => _busyId = c.substitutionId);
    try {
      final msg = await ref
          .read(operationsRepositoryProvider)
          .confirmCover(c.substitutionId);
      ref.invalidate(actionBoardProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ]),
          backgroundColor: Colors.green.shade700,
        ));
      }
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
    final board = ref.watch(actionBoardProvider);
    final live = ref.watch(coverChangesProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Action Board',
      subtitle: 'Cover that needs a decision — updates itself',
      actions: [
        _LiveBadge(connected: !live.isLoading && !live.hasError),
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(actionBoardProvider),
        ),
      ],
      child: board.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load the board: $e',
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        ),
        data: (b) {
          if (b.groups.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing needs your attention',
              message: 'Approved leave shows up here automatically, with '
                  'ranked cover suggestions. This page updates itself.',
            );
          }
          return PageBody(
            maxWidth: 1000,
            children: [
              Row(children: [
                Text('${b.needsAction} periods need cover',
                    style: theme.textTheme.titleMedium),
                const SizedBox(width: 10),
                if (b.needsAction == 0)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.check, size: 16, color: Colors.green.shade800),
                    label: const Text('all covered'),
                    backgroundColor: Colors.green.shade50,
                  ),
              ]),
              const SizedBox(height: 4),
              Text('${b.totalPeriods} periods across ${b.groups.length} absences',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              for (final g in b.groups)
                _AbsenceCard(
                  group: g,
                  busyId: _busyId,
                  onConfirm: _confirm,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: connected
            ? 'Connected — new absences appear here without a refresh'
            : 'Reconnecting…',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? Colors.green.shade500 : theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: 6),
          Text(connected ? 'live' : 'offline',
              style: theme.textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class _AbsenceCard extends StatelessWidget {
  const _AbsenceCard({
    required this.group,
    required this.busyId,
    required this.onConfirm,
  });

  final CoverGroup group;
  final String? busyId;
  final ValueChanged<CoverCandidate> onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = group;
    final done = g.allCovered;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: (done ? Colors.green : theme.colorScheme.error)
                  .withValues(alpha: 0.15),
              child: Icon(
                done ? Icons.check : Icons.person_off_outlined,
                size: 18,
                color: done ? Colors.green.shade700 : theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g.absentTeacher} away',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  [
                    g.dateRange,
                    if (g.absentDepartment != null) g.absentDepartment!,
                    if (g.reason != null) g.reason!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(done
                  ? '${g.periods.length} covered'
                  : '${g.unconfirmed} of ${g.periods.length} to cover'),
              backgroundColor: done
                  ? Colors.green.shade50
                  : theme.colorScheme.errorContainer,
            ),
          ]),
          const SizedBox(height: 14),
          for (final p in g.periods)
            _PeriodRow(period: p, busyId: busyId, onConfirm: onConfirm),
        ]),
      ),
    );
  }
}

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({
    required this.period,
    required this.busyId,
    required this.onConfirm,
  });

  final CoverPeriod period;
  final String? busyId;
  final ValueChanged<CoverCandidate> onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = period;
    final day = DateTime.tryParse(p.date);
    final dayLabel = day == null ? p.date : '${dayNames[day.weekday]} ${p.date}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${p.className} · ${p.subjectName}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(
            [dayLabel, 'P${p.slotIndex}', if (p.room != null) p.room!].join(' · '),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
        const SizedBox(height: 10),
        if (p.isConfirmed)
          Row(children: [
            Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Text('${p.confirmedTeacher ?? 'A substitute'} is covering this',
                style: TextStyle(color: Colors.green.shade800)),
          ])
        else if (p.candidates.isEmpty)
          Row(children: [
            Icon(Icons.warning_amber_rounded,
                size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            const Text('No one is free this period.'),
          ])
        else
          Column(children: [
            for (final c in p.candidates)
              _CandidateRow(
                candidate: c,
                busy: busyId == c.substitutionId,
                onConfirm: () => onConfirm(c),
              ),
          ]),
      ]),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.busy,
    required this.onConfirm,
  });

  final CoverCandidate candidate;
  final bool busy;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = candidate;
    final best = c.rank == 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: best
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : theme.colorScheme.surfaceContainerHighest,
          ),
          child: Text('${c.rank}',
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: best ? theme.colorScheme.primary : null)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(c.teacherName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: best ? FontWeight.w600 : FontWeight.normal)),
              ),
              if (best) ...[
                const SizedBox(width: 6),
                Text('best match',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ],
            ]),
            // The reasoning is shown, not hidden — "why this person?" is the
            // first question an administrator asks.
            Text(c.rationale,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        best
            ? FilledButton(
                onPressed: busy ? null : onConfirm,
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14)),
                child: busy
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Confirm'),
              )
            : TextButton(
                onPressed: busy ? null : onConfirm,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Pick'),
              ),
      ]),
    );
  }
}

