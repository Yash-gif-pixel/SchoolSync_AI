import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/timetable_repository.dart';
import '../models/timetable.dart';
import '../widgets/timetable_grid.dart';

/// Generate and inspect the master timetable.
class TimetableScreen extends ConsumerStatefulWidget {
  const TimetableScreen({super.key});

  @override
  ConsumerState<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends ConsumerState<TimetableScreen> {
  bool _solving = false;
  SolveOutcome? _lastRun;
  String? _selectedClass;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _solving = true;
      _error = null;
      _lastRun = null;
    });
    try {
      final outcome = await ref.read(timetableRepositoryProvider).generate();
      setState(() => _lastRun = outcome);
      ref.invalidate(activeTimetableProvider);
      ref.invalidate(timetableVersionsProvider);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _solving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(activeTimetableProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetable'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(activeTimetableProvider),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _GenerateCard(
            solving: _solving,
            onGenerate: _generate,
            error: _error,
            outcome: _lastRun,
          ),
          const SizedBox(height: 18),
          active.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load the timetable: $e'),
              ),
            ),
            data: (tt) {
              if (tt.entries.isEmpty) {
                return _EmptyState(solving: _solving);
              }
              final classes = tt.classNames.toList();
              final selected = _selectedClass ?? classes.first;
              return Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text('Master timetable', style: theme.textTheme.titleMedium),
                        const SizedBox(width: 12),
                        if (tt.version?.isActive ?? false)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: const Text('live'),
                            backgroundColor: Colors.green.shade50,
                            labelStyle: TextStyle(
                                color: Colors.green.shade800, fontSize: 12),
                          ),
                        const Spacer(),
                        SizedBox(
                          width: 150,
                          child: DropdownButtonFormField<String>(
                            initialValue: selected,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Class',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final c in classes)
                                DropdownMenuItem(value: c, child: Text(c)),
                            ],
                            onChanged: (v) => setState(() => _selectedClass = v),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 16),
                      TimetableGrid(timetable: tt, className: selected),
                      const SizedBox(height: 8),
                      Text(
                        '${tt.entries.length} periods scheduled across '
                        '${classes.length} classes',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _GenerateCard extends StatelessWidget {
  const _GenerateCard({
    required this.solving,
    required this.onGenerate,
    required this.error,
    required this.outcome,
  });

  final bool solving;
  final VoidCallback onGenerate;
  final String? error;
  final SolveOutcome? outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.auto_awesome_motion_outlined,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Text('Generate the timetable', style: theme.textTheme.titleMedium),
              const Spacer(),
              FilledButton.icon(
                onPressed: solving ? null : onGenerate,
                icon: solving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow),
                label: Text(solving ? 'Solving…' : 'Generate'),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              'A constraint solver places every period so no teacher or class '
              'is ever double-booked, labs stay within capacity, and subjects '
              'spread across the week.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (solving) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text('Takes up to 20 seconds. A valid timetable is found in the '
                  'first second; the rest is spent removing teacher idle periods.',
                  style: theme.textTheme.bodySmall),
            ],
            if (error != null) ...[
              const SizedBox(height: 14),
              _Box(
                colour: theme.colorScheme.error,
                icon: Icons.error_outline,
                child: Text(error!),
              ),
            ],
            if (outcome != null) ...[
              const SizedBox(height: 16),
              _Outcome(outcome: outcome!),
            ],
          ],
        ),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.outcome});
  final SolveOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = outcome.stats;
    final ok = outcome.placedEverything;

    final before = s['gaps_before_optimising'];
    final after = s['teacher_gaps'];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Box(
        colour: ok ? Colors.green.shade700 : theme.colorScheme.error,
        icon: ok ? Icons.check_circle_outline : Icons.error_outline,
        child: Text(
          ok
              ? 'Every period placed. ${outcome.activated ? 'Published as the live timetable.' : ''}'
              : '${s['unplaced_periods']} periods could not be placed — see below.',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 10, runSpacing: 10, children: [
        _Stat('${s['entries'] ?? 0}', 'periods placed'),
        _Stat('${s['wall_seconds'] ?? '?'}s', 'solve time'),
        _Stat(_fmt(s['variables']), 'variables'),
        if (before != null && after != null)
          _Stat('$before → $after', 'teacher idle gaps', highlight: true),
      ]),
      if (outcome.diagnostics.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          '${outcome.errorCount} problem(s), ${outcome.warningCount} note(s)',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        for (final d in outcome.diagnostics.take(12))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Box(
              colour: d.isError
                  ? theme.colorScheme.error
                  : const Color(0xFFB26A00),
              icon: d.isError
                  ? Icons.error_outline
                  : Icons.warning_amber_rounded,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.message),
                if (d.detail != null)
                  Text(d.detail!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ),
        if (outcome.diagnostics.length > 12)
          Text('… and ${outcome.diagnostics.length - 12} more',
              style: theme.textTheme.bodySmall),
      ],
    ]);
  }

  static String _fmt(Object? n) {
    final v = (n as num?)?.toInt() ?? 0;
    return v.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label, {this.highlight = false});
  final String value;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = highlight ? theme.colorScheme.primary : null;
    return Container(
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: (colour ?? theme.colorScheme.onSurfaceVariant)
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600, color: colour)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.colour, required this.icon, required this.child});
  final Color colour;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 10),
        Expanded(child: child),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.solving});
  final bool solving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 50),
      alignment: Alignment.center,
      child: Column(children: [
        Icon(Icons.grid_off_outlined, size: 40, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Text(
          solving ? 'Solving…' : 'No timetable published yet — generate one above.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
