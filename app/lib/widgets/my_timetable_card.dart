import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/timetable_repository.dart';
import '../models/timetable.dart';
import 'timetable_grid.dart';

/// The teacher's own week, from the live timetable.
class MyTimetableCard extends ConsumerWidget {
  const MyTimetableCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myTimetableProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.calendar_month_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Text('Your week', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => ref.invalidate(myTimetableProvider),
              ),
            ]),
            const SizedBox(height: 12),
            mine.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              error: (e, _) => Text('Could not load your timetable: $e',
                  style: TextStyle(color: theme.colorScheme.error)),
              data: (tt) {
                if (tt.entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Row(children: [
                      Icon(Icons.info_outline,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'No timetable has been published yet. It will appear '
                          'here once an administrator generates one.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ]),
                  );
                }
                final byDay = <int, int>{};
                for (final e in tt.entries) {
                  byDay[e.dayOfWeek] = (byDay[e.dayOfWeek] ?? 0) + 1;
                }
                final busiest = byDay.entries.isEmpty
                    ? null
                    : byDay.entries.reduce((a, b) => a.value >= b.value ? a : b);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _Pill('${tt.entries.length}', 'periods a week'),
                      _Pill('${tt.entries.map((e) => e.className).toSet().length}',
                          'classes'),
                      if (busiest != null)
                        _Pill(dayNamesLong[busiest.key],
                            'busiest (${busiest.value} periods)'),
                    ]),
                    const SizedBox(height: 16),
                    TimetableGrid(
                      timetable: tt,
                      showTeacher: false,
                      showClass: true,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
