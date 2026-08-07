import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/timetable_repository.dart';

/// Admin dashboard entry point into the timetable engine.
class TimetableSummaryCard extends ConsumerWidget {
  const TimetableSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeTimetableProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/timetable'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.grid_view_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('Smart Timetable', style: theme.textTheme.titleMedium),
                const Spacer(),
                const Icon(Icons.chevron_right),
              ]),
              const SizedBox(height: 6),
              Text(
                'A constraint solver places every period without double-booking '
                'a teacher, a class or a lab.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              active.when(
                loading: () => const SizedBox(
                  height: 22, width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Text('Timetable unavailable',
                    style: TextStyle(color: theme.colorScheme.error)),
                data: (tt) {
                  if (tt.entries.isEmpty) {
                    return Row(children: [
                      Icon(Icons.info_outline,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      const Text('Not generated yet — tap to build one.'),
                    ]);
                  }
                  final s = tt.version?.stats ?? const {};
                  return Wrap(spacing: 10, runSpacing: 10, children: [
                    _Pill(
                      value: '${tt.entries.length}',
                      label: 'periods scheduled',
                      colour: Colors.green.shade600,
                    ),
                    _Pill(
                      value: '${tt.classNames.length}',
                      label: 'classes covered',
                      colour: theme.colorScheme.primary,
                    ),
                    if (s['wall_seconds'] != null)
                      _Pill(
                        value: '${s['wall_seconds']}s',
                        label: 'to solve',
                        colour: theme.colorScheme.onSurfaceVariant,
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
