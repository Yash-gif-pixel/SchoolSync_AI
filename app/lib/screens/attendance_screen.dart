import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';

/// Attendance for one period.
///
/// In a class of 45, roughly 42 are present. Reading 45 names to find 3
/// absentees is the wrong shape of work, so everyone arrives marked present
/// and the teacher taps only the empty desks. One submit for the whole class.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({
    super.key,
    required this.classId,
    required this.slotId,
    required this.className,
    required this.subjectName,
  });

  final String classId;
  final String slotId;
  final String className;
  final String subjectName;

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  Roster? _roster;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(operationsRepositoryProvider).roster(
            classId: widget.classId,
            slotId: widget.slotId,
          );
      setState(() => _roster = r);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Tapping cycles present → absent → late → present. One gesture covers
  /// every case without a menu.
  void _cycle(RosterStudent s) {
    setState(() {
      s.status = switch (s.status) {
        AttendanceStatus.present => AttendanceStatus.absent,
        AttendanceStatus.absent => AttendanceStatus.late,
        AttendanceStatus.late => AttendanceStatus.present,
      };
    });
  }

  Future<void> _submit() async {
    final r = _roster;
    if (r == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final msg = await ref.read(operationsRepositoryProvider).markAttendance(
            classId: r.classId,
            slotId: r.slotId,
            date: r.date,
            students: r.students,
          );
      ref.invalidate(periodsTodayProvider);
      if (mounted) Navigator.of(context).pop(msg);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _roster;

    final absent = r?.students.where((s) => s.status == AttendanceStatus.absent).length ?? 0;
    final late = r?.students.where((s) => s.status == AttendanceStatus.late).length ?? 0;
    final present = (r?.students.length ?? 0) - absent - late;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.className} · ${widget.subjectName}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.centerLeft,
            child: Text(
              r == null
                  ? ''
                  : 'Everyone starts present — tap the empty desks. '
                      'Tap again for late.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : r == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error ?? 'Could not load the class list',
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                )
              : Column(children: [
                  if (r.alreadyMarked)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: theme.colorScheme.secondaryContainer,
                      child: Row(children: [
                        const Icon(Icons.history, size: 18),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('This period was already marked. '
                              'Submitting again will correct it.'),
                        ),
                      ]),
                    ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 132,
                        mainAxisExtent: 104,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: r.students.length,
                      itemBuilder: (_, i) => _StudentTile(
                        student: r.students[i],
                        onTap: () => _cycle(r.students[i]),
                      ),
                    ),
                  ),
                ]),
      bottomNavigationBar: r == null
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(children: [
                  if (_error != null)
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(color: theme.colorScheme.error)),
                    )
                  else
                    Expanded(
                      child: Wrap(spacing: 14, children: [
                        _Count(present, 'present', Colors.green.shade700),
                        _Count(absent, 'absent', theme.colorScheme.error),
                        if (late > 0)
                          _Count(late, 'late', const Color(0xFFB26A00)),
                      ]),
                    ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _submit,
                    icon: _saving
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check, size: 18),
                    label: Text(_saving ? 'Saving…' : 'Submit'),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16)),
                  ),
                ]),
              ),
            ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.n, this.label, this.colour);
  final int n;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$n',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w700, color: colour)),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _StudentTile extends StatelessWidget {
  const _StudentTile({required this.student, required this.onTap});
  final RosterStudent student;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color colour, IconData icon) = switch (student.status) {
      AttendanceStatus.present => (Colors.green.shade600, Icons.check_circle),
      AttendanceStatus.absent => (theme.colorScheme.error, Icons.cancel),
      AttendanceStatus.late => (const Color(0xFFB26A00), Icons.schedule),
    };
    final dimmed = student.status == AttendanceStatus.absent;

    return Material(
      color: dimmed
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.35)
          : colour.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colour.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: colour.withValues(alpha: 0.18),
                  child: Text(
                    student.initials,
                    style: TextStyle(
                      color: colour,
                      fontWeight: FontWeight.w700,
                      // Absent pupils are visually struck out, so a glance at
                      // the grid shows who is missing.
                      decoration: dimmed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Icon(icon, size: 15, color: colour),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                '${student.rollNo}. ${student.fullName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  decoration: dimmed ? TextDecoration.lineThrough : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
