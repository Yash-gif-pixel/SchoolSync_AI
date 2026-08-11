import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/dates.dart';
import '../core/seating_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/exam_calendar.dart';
import '../widgets/seating_room_grid.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

/// Exam seating.
///
/// An exam is a season: name it, say which grades are in it, then mark the
/// days each grade sits on the calendar. Seating is generated per day, using
/// only the rooms belonging to the grades writing that day — so on Tuesday
/// only Tuesday's grades leave their classrooms.
class SeatingScreen extends ConsumerStatefulWidget {
  const SeatingScreen({super.key});

  @override
  ConsumerState<SeatingScreen> createState() => _SeatingScreenState();
}

class _SeatingScreenState extends ConsumerState<SeatingScreen> {
  String? _examId;
  String? _error;

  Future<void> _newExam() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => const _NewExamDialog(),
    );
    if (id == null) return;
    ref.invalidate(examsProvider);
    setState(() => _examId = id);
  }

  Future<void> _delete(Exam exam) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${exam.name}"?'),
        content: Text('Its ${exam.sittings.length} scheduled day(s) and any '
            'seating plans will be removed. Students and rooms are not '
            'affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ref.read(seatingRepositoryProvider).deleteExam(exam.id);
      if (_examId == exam.id) setState(() => _examId = null);
      ref.invalidate(examsProvider);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = readableApiError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final exams = ref.watch(examsProvider);

    return AppShell(
      title: 'Exam seating',
      subtitle: 'Plan the season, then seat each day',
      child: PageBody(children: [
        if (_error != null) ...[
          Callout(message: _error!, tone: Tone.danger),
          const SizedBox(height: AppSpace.lg),
        ],

        SectionCard(
          title: 'Exams',
          subtitle: 'An exam runs over many days. Grades sit on their own '
              'dates.',
          icon: Icons.event_note_outlined,
          trailing: FilledButton.icon(
            onPressed: _newExam,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New exam'),
          ),
          child: exams.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Callout(
              message: 'Could not load exams.',
              detail: e is ApiException ? readableApiError(e) : '$e',
              tone: Tone.danger,
            ),
            data: (list) => list.isEmpty
                ? EmptyState(
                    icon: Icons.event_busy_outlined,
                    title: 'No exams yet',
                    message: 'Create one, then mark its days on the calendar.',
                    action: FilledButton(
                      onPressed: _newExam,
                      child: const Text('New exam'),
                    ),
                  )
                : Column(
                    children: [
                      for (final e in list)
                        _ExamRow(
                          exam: e,
                          selected: e.id == _examId,
                          onOpen: () => setState(
                              () => _examId = e.id == _examId ? null : e.id),
                          onDelete: () => _delete(e),
                        ),
                    ],
                  ),
          ),
        ),

        if (_examId != null) ...[
          const SizedBox(height: AppSpace.xl),
          _ScheduleView(examId: _examId!),
        ],
        const SizedBox(height: AppSpace.xl),
      ]),
    );
  }
}

/// FastAPI puts the readable reason in `detail`. Shown to an administrator,
/// so a raw JSON body will not do.
String readableApiError(ApiException e) {
  final at = e.message.indexOf('"detail":"');
  if (at == -1) return e.message;
  final rest = e.message.substring(at + 10);
  final end = rest.indexOf('"');
  return end == -1 ? rest : rest.substring(0, end);
}

String _fmt(DateTime d) => Dates.isoToDisplay(d.toIso8601String());

// ---------------------------------------------------------------------

class _ExamRow extends StatelessWidget {
  const _ExamRow({
    required this.exam,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
  });

  final Exam exam;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = exam.sittings.length;
    final planned = exam.plannedDays;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: selected ? AppColors.brandTint : AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border:
            Border.all(color: selected ? AppColors.brand : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(exam.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    [
                      exam.gradeLabel,
                      if (exam.firstDay != null)
                        '${_fmt(exam.firstDay!)} – ${_fmt(exam.lastDay!)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Delete exam',
              onPressed: onDelete,
            ),
          ]),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusPill(
                label: days == 0 ? 'No dates set' : '$days day(s) scheduled',
                tone: days == 0 ? Tone.warning : Tone.neutral,
              ),
              if (days > 0)
                StatusPill(
                  label: planned == days
                      ? 'All days seated'
                      : '$planned of $days seated',
                  tone: planned == days ? Tone.success : Tone.warning,
                ),
              FilledButton.tonal(
                onPressed: onOpen,
                child: Text(selected ? 'Close' : 'Open calendar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------

class _NewExamDialog extends ConsumerStatefulWidget {
  const _NewExamDialog();

  @override
  ConsumerState<_NewExamDialog> createState() => _NewExamDialogState();
}

class _NewExamDialogState extends ConsumerState<_NewExamDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _grades = <int>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_grades.isEmpty) {
      setState(() => _error = 'Pick at least one grade.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final exam = await ref.read(seatingRepositoryProvider).createExam(
            name: _name.text.trim(),
            grades: _grades.toList()..sort(),
          );
      if (mounted) Navigator.pop(context, exam.id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = readableApiError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('New exam'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  Callout(message: _error!, tone: Tone.danger),
                  const SizedBox(height: AppSpace.md),
                ],
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Exam name',
                    hintText: 'Half-Yearly Examination 2026',
                  ),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? 'Give the exam a name'
                      : null,
                ),
                const SizedBox(height: AppSpace.lg),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Grades taking this exam',
                      style: theme.textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (var g = 1; g <= 10; g++)
                      FilterChip(
                        label: Text('$g'),
                        selected: _grades.contains(g),
                        onSelected: (on) => setState(
                            () => on ? _grades.add(g) : _grades.remove(g)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'You pick the actual dates next, per grade, on a calendar.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Creating…' : 'Create exam'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------

class _ScheduleView extends ConsumerStatefulWidget {
  const _ScheduleView({required this.examId});
  final String examId;

  @override
  ConsumerState<_ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends ConsumerState<_ScheduleView> {
  String? _openSittingId;
  String? _busySittingId;
  String? _error;

  void _refresh() {
    ref.invalidate(scheduleProvider(widget.examId));
    ref.invalidate(examsProvider);
  }

  Future<void> _addSitting(Exam exam, DateTime day) async {
    final existing = exam.sittings
        .where((s) =>
            s.sitsOn.year == day.year &&
            s.sitsOn.month == day.month &&
            s.sitsOn.day == day.day)
        .toList();

    final result = await showDialog<_SittingDraft>(
      context: context,
      builder: (_) => _DayDialog(
        day: day,
        roster: exam.grades,
        existing: existing,
      ),
    );
    if (result == null) return;

    try {
      if (result.deleteId != null) {
        await ref
            .read(seatingRepositoryProvider)
            .deleteSitting(result.deleteId!);
      } else {
        await ref.read(seatingRepositoryProvider).addSitting(
              examId: exam.id,
              sitsOn: day,
              grades: result.grades,
              paper: result.paper,
            );
      }
      _refresh();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = readableApiError(e));
    }
  }

  Future<void> _generate(Sitting sitting) async {
    setState(() {
      _busySittingId = sitting.id;
      _error = null;
    });
    try {
      final res =
          await ref.read(seatingRepositoryProvider).generate(sitting.id);
      ref.invalidate(seatingPlanProvider(sitting.id));
      _refresh();
      if (!mounted) return;
      final errors =
          res.diagnostics.where((d) => d.severity == 'error').toList();
      setState(() {
        if (errors.isNotEmpty) {
          _error = errors.first.message;
        } else {
          _openSittingId = sitting.id;
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = readableApiError(e));
    } finally {
      if (mounted) setState(() => _busySittingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(scheduleProvider(widget.examId));

    return schedule.when(
      loading: () => const SectionCard(
        title: 'Exam calendar',
        icon: Icons.calendar_month_outlined,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SectionCard(
        title: 'Exam calendar',
        icon: Icons.calendar_month_outlined,
        child: Callout(
          message: 'Could not load the schedule.',
          detail: e is ApiException ? readableApiError(e) : '$e',
          tone: Tone.danger,
        ),
      ),
      data: (s) {
        final exam = s.exam;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Exam calendar',
              subtitle: 'Tap a day to set which grades sit on it.',
              icon: Icons.calendar_month_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null) ...[
                    Callout(message: _error!, tone: Tone.danger),
                    const SizedBox(height: AppSpace.md),
                  ],
                  ExamCalendar(
                    sittings: exam.sittings,
                    onPickDay: (d) => _addSitting(exam, d),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Wrap(spacing: AppSpace.lg, runSpacing: AppSpace.sm, children: [
                    _Legend(
                        colour: AppColors.brand, label: 'Scheduled, not seated'),
                    _Legend(colour: AppColors.success, label: 'Seated'),
                  ]),
                  for (final d in s.diagnostics) ...[
                    const SizedBox(height: AppSpace.md),
                    Callout(
                      message: d.message,
                      detail: d.detail,
                      tone: switch (d.severity) {
                        'error' => Tone.danger,
                        'warning' => Tone.warning,
                        _ => Tone.neutral,
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),

            SectionCard(
              title: 'Days',
              subtitle: '${exam.sittings.length} scheduled',
              icon: Icons.event_available_outlined,
              child: exam.sittings.isEmpty
                  ? const EmptyState(
                      icon: Icons.event_busy_outlined,
                      title: 'Nothing scheduled yet',
                      message: 'Tap a day on the calendar above.',
                    )
                  : Column(
                      children: [
                        for (final sit in exam.sittings)
                          _SittingRow(
                            sitting: sit,
                            busy: _busySittingId == sit.id,
                            open: _openSittingId == sit.id,
                            onGenerate: () => _generate(sit),
                            onToggle: () => setState(() => _openSittingId =
                                _openSittingId == sit.id ? null : sit.id),
                          ),
                      ],
                    ),
            ),

            if (_openSittingId != null) ...[
              const SizedBox(height: AppSpace.lg),
              _PlanView(sittingId: _openSittingId!),
            ],
          ],
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.colour, required this.label});
  final Color colour;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _SittingRow extends StatelessWidget {
  const _SittingRow({
    required this.sitting,
    required this.busy,
    required this.open,
    required this.onGenerate,
    required this.onToggle,
  });

  final Sitting sitting;
  final bool busy;
  final bool open;
  final VoidCallback onGenerate;
  final VoidCallback onToggle;

  static const _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = sitting.planStats;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_weekdays[sitting.sitsOn.weekday - 1]} ${_fmt(sitting.sitsOn)}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (sitting.paper != null) sitting.paper!,
              sitting.gradeLabel,
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!sitting.hasPlan)
                const StatusPill(label: 'Not seated', tone: Tone.warning)
              else ...[
                StatusPill(
                  label: '${stats?['seated'] ?? 0} seated',
                  tone: Tone.success,
                ),
                StatusPill(
                  label: '${stats?['rooms_used'] ?? 0} rooms',
                  tone: Tone.neutral,
                ),
                if (((stats?['adjacent_same_class'] as num?) ?? 0) > 0)
                  StatusPill(
                    label: '${stats?['adjacent_same_class']} side by side',
                    tone: Tone.warning,
                  )
                else
                  const StatusPill(
                      label: 'No same-class neighbours', tone: Tone.success),
              ],
              FilledButton.tonal(
                onPressed: busy ? null : onGenerate,
                child: Text(busy
                    ? 'Working…'
                    : sitting.hasPlan
                        ? 'Regenerate'
                        : 'Generate seating'),
              ),
              if (sitting.hasPlan)
                OutlinedButton(
                  onPressed: onToggle,
                  child: Text(open ? 'Hide plan' : 'View plan'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------

class _SittingDraft {
  const _SittingDraft({this.grades = const [], this.paper, this.deleteId});
  final List<int> grades;
  final String? paper;
  final String? deleteId;
}

class _DayDialog extends StatefulWidget {
  const _DayDialog({
    required this.day,
    required this.roster,
    required this.existing,
  });

  final DateTime day;
  final List<int> roster;
  final List<Sitting> existing;

  @override
  State<_DayDialog> createState() => _DayDialogState();
}

class _DayDialogState extends State<_DayDialog> {
  final _paper = TextEditingController();
  final _grades = <int>{};

  @override
  void dispose() {
    _paper.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sunday = widget.day.weekday == DateTime.sunday;

    return AlertDialog(
      title: Text(_fmt(widget.day)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sunday) ...[
                const Callout(
                  message: 'This is a Sunday.',
                  tone: Tone.warning,
                ),
                const SizedBox(height: AppSpace.md),
              ],

              if (widget.existing.isNotEmpty) ...[
                Text('Already scheduled', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                for (final s in widget.existing)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.paper ?? 'Untitled paper'),
                    subtitle: Text(s.gradeLabel),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      color: AppColors.danger,
                      tooltip: 'Remove this sitting',
                      onPressed: () => Navigator.pop(
                          context, _SittingDraft(deleteId: s.id)),
                    ),
                  ),
                const Divider(),
                const SizedBox(height: AppSpace.sm),
              ],

              Text('Add a paper on this day',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              TextField(
                controller: _paper,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Paper (optional)',
                  hintText: 'Mathematics',
                ),
              ),
              const SizedBox(height: AppSpace.lg),

              Text('Grades sitting', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              if (widget.roster.isEmpty)
                Text('This exam has no grades on its roster.',
                    style: theme.textTheme.bodySmall)
              else
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final g in widget.roster)
                      FilterChip(
                        label: Text('Grade $g'),
                        selected: _grades.contains(g),
                        onSelected: (on) => setState(
                            () => on ? _grades.add(g) : _grades.remove(g)),
                      ),
                  ],
                ),
              const SizedBox(height: 6),
              Text(
                'Only these grades leave their classrooms. Everyone else has '
                'a normal school day.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _grades.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    _SittingDraft(
                      grades: _grades.toList()..sort(),
                      paper: _paper.text.trim(),
                    ),
                  ),
          child: const Text('Add sitting'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------

class _PlanView extends ConsumerWidget {
  const _PlanView({required this.sittingId});
  final String sittingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(seatingPlanProvider(sittingId));

    return plan.when(
      loading: () => const SectionCard(
        title: 'Seating plan',
        icon: Icons.event_seat_outlined,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SectionCard(
        title: 'Seating plan',
        icon: Icons.event_seat_outlined,
        child: Callout(
          message: 'Could not load the plan.',
          detail: e is ApiException ? readableApiError(e) : '$e',
          tone: Tone.danger,
        ),
      ),
      data: (p) {
        if (p.isEmpty) {
          return const SectionCard(
            title: 'Seating plan',
            icon: Icons.event_seat_outlined,
            child: EmptyState(
              icon: Icons.event_seat_outlined,
              title: 'No plan for this day yet',
              message: 'Use "Generate seating" above.',
            ),
          );
        }

        final s = p.stats;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Seating plan',
              subtitle: '${p.rooms.length} rooms',
              icon: Icons.event_seat_outlined,
              tone: Tone.success,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.md,
                    children: [
                      StatTile(
                        value: '${s['seated'] ?? 0}',
                        label: 'Students seated',
                        icon: Icons.groups_outlined,
                        tone: Tone.brand,
                      ),
                      StatTile(
                        value: '${s['rooms_used'] ?? 0}',
                        label: 'Rooms used',
                        hint: 'of ${s['rooms_available'] ?? 0} available',
                        icon: Icons.meeting_room_outlined,
                      ),
                      StatTile(
                        value:
                            '${(((s['occupancy'] as num?) ?? 0) * 100).round()}%',
                        label: 'Occupancy',
                        hint: '${s['seats_available'] ?? 0} seats',
                        icon: Icons.chair_alt_outlined,
                      ),
                      StatTile(
                        value: '${s['adjacent_same_class'] ?? 0}',
                        label: 'Same-class neighbours',
                        tone: ((s['adjacent_same_class'] as num?) ?? 0) > 0
                            ? Tone.warning
                            : Tone.success,
                        icon: Icons.shield_outlined,
                      ),
                    ],
                  ),
                  for (final d in p.diagnostics) ...[
                    const SizedBox(height: AppSpace.md),
                    Callout(
                      message: d.message,
                      detail: d.detail,
                      tone: switch (d.severity) {
                        'error' => Tone.danger,
                        'warning' => Tone.warning,
                        _ => Tone.success,
                      },
                    ),
                  ],
                ],
              ),
            ),
            for (final room in p.rooms) ...[
              const SizedBox(height: AppSpace.lg),
              SeatingRoomGrid(room: room),
            ],
          ],
        );
      },
    );
  }
}
