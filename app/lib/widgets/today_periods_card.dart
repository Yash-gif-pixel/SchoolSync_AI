import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';
import '../screens/attendance_screen.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${p.className}: $msg'),
        backgroundColor: Colors.green.shade700,
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periods = ref.watch(periodsTodayProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.how_to_reg_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text('Today', style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => ref.invalidate(periodsTodayProvider),
            ),
          ]),
          const SizedBox(height: 4),
          Text('Attendance starts with everyone present — mark only the '
              'empty desks.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          periods.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Text('Could not load today: $e',
                style: TextStyle(color: theme.colorScheme.error)),
            data: (list) {
              if (list.isEmpty) {
                return Row(children: [
                  Icon(Icons.free_breakfast_outlined,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No periods scheduled for you today.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ]);
              }
              final outstanding = list.where((p) => !p.marked).length;
              return Column(children: [
                if (outstanding > 0)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      const Icon(Icons.pending_actions,
                          size: 16, color: Color(0xFFB26A00)),
                      const SizedBox(width: 8),
                      Text('$outstanding period(s) still need attendance',
                          style: const TextStyle(color: Color(0xFF7A4A00))),
                    ]),
                  ),
                for (final p in list)
                  _PeriodTile(period: p, onTap: () => _open(context, ref, p)),
              ]);
            },
          ),
        ]),
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
    final colour = p.marked ? Colors.green.shade600 : const Color(0xFFB26A00);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: ListTile(
        onTap: onTap,
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: colour.withValues(alpha: 0.15),
          child: Text('P${p.slotIndex}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colour, fontWeight: FontWeight.w700)),
        ),
        title: Text('${p.className} · ${p.subjectName}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          if (p.time.isNotEmpty) p.time,
          if (p.room != null) p.room!,
          p.marked ? 'attendance taken' : 'not marked yet',
        ].join(' · ')),
        trailing: p.marked
            ? Icon(Icons.check_circle, size: 20, color: colour)
            : FilledButton.tonal(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('Take'),
              ),
      ),
    );
  }
}
