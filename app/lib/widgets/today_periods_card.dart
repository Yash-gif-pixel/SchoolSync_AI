import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';
import '../screens/attendance_screen.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

/// Today's teaching, with attendance one tap away.
class TodayPeriodsCard extends ConsumerWidget {
  const TodayPeriodsCard({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, TodayPeriod p) async {
    final msg = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AttendanceScreen(
          classId: p.classId,
          slotId: p.slotId,
          className: p.className,
          subjectName: p.subjectName,
        ),
      ),
    );
    ref.invalidate(periodsTodayProvider);
    if (msg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${p.className}: $msg')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periods = ref.watch(periodsTodayProvider);

    return SectionCard(
      title: 'Today',
      subtitle: 'Attendance starts with everyone present — mark only the '
          'empty desks',
      icon: Icons.how_to_reg_outlined,
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 20),
        onPressed: () => ref.invalidate(periodsTodayProvider),
      ),
      child: periods.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        error: (e, _) => Callout(
          tone: Tone.danger,
          message: 'Could not load today',
          detail: '$e',
        ),
        data: (list) {
          if (list.isEmpty) {
            return const Callout(
              tone: Tone.neutral,
              icon: Icons.free_breakfast_outlined,
              message: 'No periods scheduled for you today.',
            );
          }
          final outstanding = list.where((p) => !p.marked).length;

          return Column(children: [
            if (outstanding > 0) ...[
              Callout(
                tone: Tone.warning,
                icon: Icons.pending_actions,
                message: outstanding == 1
                    ? '1 period still needs attendance'
                    : '$outstanding periods still need attendance',
              ),
              gap12,
            ],
            for (final p in list)
              _PeriodTile(period: p, onTap: () => _open(context, ref, p)),
          ]);
        },
      ),
    );
  }
}

class _PeriodTile extends StatelessWidget {
  const _PeriodTile({required this.period, required this.onTap});

  final TodayPeriod period;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = period;
    final tone = p.marked ? Tone.success : Tone.warning;

    // A hand-built row rather than a ListTile: the trailing control and the
    // leading badge both have intrinsic widths, so the text between them must
    // be the part that gives. Expanded is what guarantees that at any width.
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md, vertical: AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tone.bg,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text('P${p.slotIndex}',
              style: TextStyle(
                  color: tone.fg, fontWeight: FontWeight.w700, fontSize: 12)),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${p.className} · ${p.subjectName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14),
              ),
              Text(
                [
                  if (p.time.isNotEmpty) p.time,
                  ?p.room,
                  // Whose class it is comes before whether the register is
                  // done — a teacher walking into a room they do not normally
                  // teach needs that first.
                  if (p.isCover) 'covering for ${p.coveringFor}',
                  p.marked ? 'attendance taken' : 'not marked yet',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        if (p.marked)
          Icon(Icons.check_circle, size: 20, color: tone.fg)
        else
          FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
            child: const Text('Take'),
          ),
      ]),
    );
  }
}
