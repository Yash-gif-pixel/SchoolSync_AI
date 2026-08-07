import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/auth_controller.dart';

/// Reads straight from Supabase with the teacher's own JWT — so every number
/// here is already filtered by RLS. A teacher sees their classes and their
/// leave, never the whole school.
final teacherSummaryProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final auth = ref.watch(authControllerProvider);
  final uid = auth.profile?.id;
  if (uid == null) return {};

  final sb = Supabase.instance.client;

  final assignments = await sb
      .from('teaching_assignments')
      .select('periods_per_week, requires_lab, '
          'classes(name), subjects(name)')
      .eq('teacher_id', uid);

  final students =
      await sb.from('students').count(CountOption.exact);
  final leaves = await sb
      .from('leave_requests')
      .select('id, from_date, status')
      .order('from_date', ascending: false)
      .limit(5);

  final rows = (assignments as List).cast<Map<String, dynamic>>();
  final periods = rows.fold<int>(
      0, (sum, r) => sum + (r['periods_per_week'] as int? ?? 0));
  final classes = rows
      .map((r) => (r['classes'] as Map?)?['name'] as String?)
      .whereType<String>()
      .toSet();

  return {
    'assignments': rows,
    'periods': periods,
    'classes': classes.toList()..sort(),
    'visible_students': students,
    'recent_leaves': (leaves as List).cast<Map<String, dynamic>>(),
  };
});

class TeacherSummaryCard extends ConsumerWidget {
  const TeacherSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(teacherSummaryProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: summary.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Text('Could not load your data: $e',
              style: TextStyle(color: theme.colorScheme.error)),
          data: (d) {
            if (d.isEmpty) return const Text('No data');
            final classes = (d['classes'] as List).cast<String>();
            final assignments =
                (d['assignments'] as List).cast<Map<String, dynamic>>();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.calendar_today_outlined,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Your teaching load',
                      style: theme.textTheme.titleMedium),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _Stat('${d['periods']}', 'Periods / week'),
                  _Stat('${classes.length}', 'Classes'),
                  _Stat('${d['visible_students']}', 'Students you can see'),
                  _Stat('${(d['recent_leaves'] as List).length}',
                      'Your leave records'),
                ]),
                const SizedBox(height: 18),
                Text('Classes: ${classes.join(', ')}',
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                ...assignments.map((a) {
                  final cls = (a['classes'] as Map?)?['name'] ?? '?';
                  final sub = (a['subjects'] as Map?)?['name'] ?? '?';
                  final lab = a['requires_lab'] == true;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      SizedBox(
                          width: 52,
                          child: Text('$cls',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                      Expanded(child: Text('$sub${lab ? '  (lab)' : ''}')),
                      Text('${a['periods_per_week']}/wk',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                  );
                }),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    const Icon(Icons.shield_outlined, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'These counts come straight from Supabase using your '
                        'own login — Row Level Security filters them, not the UI.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 165,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
