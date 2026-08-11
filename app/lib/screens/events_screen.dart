import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/dates.dart';
import '../core/directory_repository.dart';
import '../core/events_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/event_row.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

/// School events — Annual Day, Sports Day, inspections.
///
/// Anything that takes staff off the timetable without being leave. Naming the
/// specific teachers rather than a headcount is the point: the staffing
/// forecast can then see the shortage coming, and it is obvious who is not
/// available to cover a colleague that week.
class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key});

  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> {
  String? _error;

  Future<void> _newEvent() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _NewEventDialog(),
    );
    if (created == true) ref.invalidate(eventsProvider);
  }

  Future<void> _delete(SchoolEvent e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${e.name}"?'),
        content: Text(
            '${e.teachers.length} teacher(s) will be released for those '
            '${e.days} day(s), and the staffing forecast will update.'),
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
      await ref.read(eventsRepositoryProvider).delete(e.id);
      ref.invalidate(eventsProvider);
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = _readable(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(eventsProvider);

    return AppShell(
      title: 'School events',
      subtitle: 'Who is off the timetable, and when',
      child: PageBody(children: [
        if (_error != null) ...[
          Callout(message: _error!, tone: Tone.danger),
          const SizedBox(height: AppSpace.lg),
        ],

        events.when(
          loading: () => const SectionCard(
            title: 'Events',
            icon: Icons.celebration_outlined,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) => SectionCard(
            title: 'Events',
            icon: Icons.celebration_outlined,
            child: Callout(
              message: 'Could not load events.',
              detail: e is ApiException ? _readable(e) : '$e',
              tone: Tone.danger,
            ),
          ),
          data: (list) {
            final upcoming = list.where((e) => !e.isOver).toList();
            final past = list.where((e) => e.isOver).toList().reversed.toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (upcoming.isNotEmpty) ...[
                  _Summary(events: upcoming),
                  const SizedBox(height: AppSpace.xl),
                ],

                SectionCard(
                  title: 'Upcoming and running',
                  subtitle: 'Teachers listed here are unavailable to teach or '
                      'to cover.',
                  icon: Icons.celebration_outlined,
                  trailing: FilledButton.icon(
                    onPressed: _newEvent,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('New event'),
                  ),
                  child: upcoming.isEmpty
                      ? EmptyState(
                          icon: Icons.event_available_outlined,
                          title: 'Nothing scheduled',
                          message: 'Add Annual Day, Sports Day, or anything '
                              'else that takes staff off the timetable.',
                          action: FilledButton(
                            onPressed: _newEvent,
                            child: const Text('New event'),
                          ),
                        )
                      : Column(
                          children: [
                            for (final e in upcoming)
                              EventRow(
                                event: e,
                                onDelete: () => _delete(e),
                              ),
                          ],
                        ),
                ),

                if (past.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.xl),
                  SectionCard(
                    title: 'Past events',
                    subtitle: '${past.length} finished',
                    icon: Icons.history_rounded,
                    tone: Tone.neutral,
                    child: Column(
                      children: [
                        for (final e in past.take(10))
                          EventRow(
                            event: e,
                            onDelete: () => _delete(e),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.xl),
      ]),
    );
  }
}

String _readable(ApiException e) {
  final at = e.message.indexOf('"detail":"');
  if (at == -1) return e.message;
  final rest = e.message.substring(at + 10);
  final end = rest.indexOf('"');
  return end == -1 ? rest : rest.substring(0, end);
}

String _fmt(DateTime d) => Dates.isoToDisplay(d.toIso8601String());

// ---------------------------------------------------------------------

class _Summary extends StatelessWidget {
  const _Summary({required this.events});
  final List<SchoolEvent> events;

  @override
  Widget build(BuildContext context) {
    // A teacher on two events counts once here; teacher-days counts the load.
    final people = <String>{for (final e in events) ...e.teachers.map((t) => t.id)};
    final teacherDays = events.fold(0, (n, e) => n + e.teacherDays);
    final running = events.where((e) => e.isRunning).length;

    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.md,
      children: [
        StatTile(
          value: '${events.length}',
          label: 'Events ahead',
          icon: Icons.celebration_outlined,
          tone: Tone.brand,
        ),
        StatTile(
          value: '${people.length}',
          label: 'Staff committed',
          hint: 'across all events',
          icon: Icons.groups_outlined,
        ),
        StatTile(
          value: '$teacherDays',
          label: 'Teacher-days lost',
          hint: 'staff x days',
          icon: Icons.schedule_outlined,
          tone: teacherDays > 40 ? Tone.warning : Tone.neutral,
        ),
        if (running > 0)
          StatTile(
            value: '$running',
            label: 'Running today',
            icon: Icons.play_circle_outline,
            tone: Tone.warning,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------

class _NewEventDialog extends ConsumerStatefulWidget {
  const _NewEventDialog();

  @override
  ConsumerState<_NewEventDialog> createState() => _NewEventDialogState();
}

class _NewEventDialogState extends ConsumerState<_NewEventDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _search = TextEditingController();
  final _picked = <String>{};

  DateTimeRange? _range;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  int get _days => _range == null
      ? 0
      : _range!.end.difference(_range!.start).inDays + 1;

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDateRange: _range ??
          DateTimeRange(start: now, end: now.add(const Duration(days: 1))),
      helpText: 'Which days is the event on?',
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_range == null) {
      setState(() => _error = 'Pick the days the event runs.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(eventsRepositoryProvider).create(
            name: _name.text.trim(),
            startsOn: _range!.start,
            endsOn: _range!.end,
            teacherIds: _picked.toList(),
          );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _readable(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staff = ref.watch(staffProvider);
    final query = _search.text.trim().toLowerCase();

    return AlertDialog(
      title: const Text('New event'),
      content: SizedBox(
        width: 520,
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
                    labelText: 'Event name',
                    hintText: 'Annual Day 2026',
                  ),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? 'Give the event a name'
                      : null,
                ),
                const SizedBox(height: AppSpace.lg),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Days', style: theme.textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: Text(
                      _range == null
                          ? 'No dates picked yet'
                          : _days == 1
                              ? _fmt(_range!.start)
                              : '${_fmt(_range!.start)} – '
                                  '${_fmt(_range!.end)}  ($_days days)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickDates,
                    icon: const Icon(Icons.calendar_month_outlined, size: 16),
                    label: Text(_range == null ? 'Pick days' : 'Change'),
                  ),
                ]),
                const SizedBox(height: AppSpace.lg),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Staff tied up${_picked.isEmpty ? '' : ' (${_picked.length})'}',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    hintText: 'Search by name or department',
                  ),
                ),
                const SizedBox(height: AppSpace.sm),

                staff.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpace.lg),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Callout(
                    message: 'Could not load the staff list.',
                    detail: e is ApiException ? _readable(e) : '$e',
                    tone: Tone.danger,
                  ),
                  data: (people) {
                    final shown = people.where((p) {
                      if (query.isEmpty) return true;
                      return p.name.toLowerCase().contains(query) ||
                          (p.department ?? '').toLowerCase().contains(query);
                    }).toList();

                    if (shown.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(AppSpace.md),
                        child: Text('Nobody matches "$query".',
                            style: theme.textTheme.bodySmall),
                      );
                    }

                    // Bounded and scrollable: fifty five names inside a dialog
                    // would push the buttons off the bottom of the screen.
                    return Container(
                      height: 240,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final p = shown[i];
                          return CheckboxListTile(
                            dense: true,
                            value: _picked.contains(p.id),
                            title: Text(p.name,
                                style: theme.textTheme.bodyMedium),
                            subtitle: Text(p.subtitle,
                                style: theme.textTheme.labelSmall),
                            onChanged: (on) => setState(() => on == true
                                ? _picked.add(p.id)
                                : _picked.remove(p.id)),
                          );
                        },
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  _picked.isEmpty || _days == 0
                      ? 'These teachers will not be available to teach or to '
                          'cover on those days.'
                      : '${_picked.length} staff x $_days day(s) = '
                          '${_picked.length * _days} teacher-days off the '
                          'timetable. The staffing forecast will pick this up.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Creating…' : 'Create event'),
        ),
      ],
    );
  }
}
