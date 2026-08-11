import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/config.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/primitives.dart';

/// "Admin (new)" — a walkthrough of a school's first day on the platform.
///
/// Every piece of state here lives in this widget and dies with it. Nothing is
/// written to Supabase and no API is called, which is the point: it shows how
/// onboarding works without touching the seeded school the rest of the demo
/// depends on. Close the tab and it is as if you were never here.
///
/// The invite link it shows is illustrative — it is not a route. Pasting it
/// lands on the router's not-found page, which says so.
class DemoSetupScreen extends StatefulWidget {
  const DemoSetupScreen({super.key});

  @override
  State<DemoSetupScreen> createState() => _DemoSetupScreenState();
}

class _DemoClass {
  _DemoClass(this.grade, this.section);
  final int grade;
  final String section;
  final List<String> students = [];
  String get name => '$grade$section';
}

class _DemoTeacher {
  _DemoTeacher(this.name, this.department, this.subjects);
  final String name;
  final String department;
  final List<String> subjects;
}

const _departments = <String, List<String>>{
  'Maths': ['Mathematics'],
  'Science': ['Physics', 'Chemistry', 'Biology'],
  'English': ['English'],
  'Hindi': ['Hindi'],
  'Social Studies': ['History', 'Geography', 'Civics'],
  'Computer Science': ['Computer Science'],
  'Physical Education': ['Games'],
};

class _DemoSetupScreenState extends State<DemoSetupScreen> {
  final List<_DemoClass> _classes = [];
  final List<_DemoTeacher> _teachers = [];
  String? _inviteToken;

  int get _studentCount =>
      _classes.fold(0, (n, c) => n + c.students.length);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to sign in',
          onPressed: () => context.go('/login'),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Admin (new)', style: theme.textTheme.titleLarge),
            Text('Your first day on SchoolSync',
                style: theme.textTheme.bodySmall),
          ],
        ),
        toolbarHeight: 68,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppColors.border),
        ),
      ),
      body: SingleChildScrollView(
        child: PageBody(children: [
          const Callout(
            message: 'This is a preview. Nothing here is saved.',
            detail: 'Add classes, students and teachers to see how setup '
                'works — none of it is written to the database, so the demo '
                'school is untouched.',
            tone: Tone.brand,
            icon: Icons.science_outlined,
          ),
          const SizedBox(height: AppSpace.xl),

          Wrap(spacing: AppSpace.md, runSpacing: AppSpace.md, children: [
            StatTile(
              value: '${_classes.length}',
              label: 'Classes',
              icon: Icons.grid_view_rounded,
              tone: Tone.brand,
            ),
            StatTile(
              value: '$_studentCount',
              label: 'Students',
              icon: Icons.groups_outlined,
              tone: Tone.neutral,
            ),
            StatTile(
              value: '${_teachers.length}',
              label: 'Teachers joined',
              icon: Icons.person_outline,
              tone: Tone.success,
            ),
          ]),
          const SizedBox(height: AppSpace.xl),

          _ClassesCard(
            classes: _classes,
            onAdd: (grade, sections) => setState(() {
              for (final s in sections) {
                final exists =
                    _classes.any((c) => c.grade == grade && c.section == s);
                if (!exists) _classes.add(_DemoClass(grade, s));
              }
              _classes.sort((a, b) => a.name.compareTo(b.name));
            }),
            onAddStudent: (cls, name) =>
                setState(() => cls.students.add(name)),
            onRemoveStudent: (cls, name) =>
                setState(() => cls.students.remove(name)),
            onRemoveClass: (cls) => setState(() => _classes.remove(cls)),
          ),
          const SizedBox(height: AppSpace.xl),

          _InviteCard(
            token: _inviteToken,
            teachers: _teachers,
            onGenerate: () => setState(
                () => _inviteToken = 'demo-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'),
            onJoined: (t) => setState(() => _teachers.add(t)),
            onRemove: (t) => setState(() => _teachers.remove(t)),
          ),
          const SizedBox(height: AppSpace.xl),

          _NextCard(
            ready: _classes.isNotEmpty && _teachers.isNotEmpty,
            classes: _classes.length,
            teachers: _teachers.length,
          ),
          const SizedBox(height: AppSpace.xl),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// classes and students
// ---------------------------------------------------------------------

class _ClassesCard extends StatefulWidget {
  const _ClassesCard({
    required this.classes,
    required this.onAdd,
    required this.onAddStudent,
    required this.onRemoveStudent,
    required this.onRemoveClass,
  });

  final List<_DemoClass> classes;
  final void Function(int grade, List<String> sections) onAdd;
  final void Function(_DemoClass, String) onAddStudent;
  final void Function(_DemoClass, String) onRemoveStudent;
  final void Function(_DemoClass) onRemoveClass;

  @override
  State<_ClassesCard> createState() => _ClassesCardState();
}

class _ClassesCardState extends State<_ClassesCard> {
  int _grade = 6;
  final _sections = <String>{'A', 'B'};
  _DemoClass? _open;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Step 1 · Classes and students',
      subtitle: 'Add a grade, choose its sections, then name the students.',
      icon: Icons.grid_view_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 130,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Grade', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<int>(
                      initialValue: _grade,
                      isExpanded: true,
                      items: [
                        for (var g = 1; g <= 12; g++)
                          DropdownMenuItem(
                              value: g, child: Text('Grade $g')),
                      ],
                      onChanged: (v) => setState(() => _grade = v ?? 6),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Sections', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: AppSpace.xs,
                      children: [
                        for (final s in const ['A', 'B', 'C', 'D', 'E'])
                          FilterChip(
                            label: Text(s),
                            selected: _sections.contains(s),
                            onSelected: (on) => setState(() =>
                                on ? _sections.add(s) : _sections.remove(s)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _sections.isEmpty
                    ? null
                    : () => widget.onAdd(
                        _grade, _sections.toList()..sort()),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add classes'),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),

          if (widget.classes.isEmpty)
            const EmptyState(
              icon: Icons.grid_view_outlined,
              title: 'No classes yet',
              message: 'Pick a grade and its sections above.',
            )
          else
            Column(
              children: [
                for (final c in widget.classes)
                  _ClassRow(
                    cls: c,
                    expanded: identical(_open, c),
                    onToggle: () => setState(
                        () => _open = identical(_open, c) ? null : c),
                    onAddStudent: (n) => widget.onAddStudent(c, n),
                    onRemoveStudent: (n) => widget.onRemoveStudent(c, n),
                    onRemoveClass: () {
                      if (identical(_open, c)) _open = null;
                      widget.onRemoveClass(c);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ClassRow extends StatefulWidget {
  const _ClassRow({
    required this.cls,
    required this.expanded,
    required this.onToggle,
    required this.onAddStudent,
    required this.onRemoveStudent,
    required this.onRemoveClass,
  });

  final _DemoClass cls;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String) onAddStudent;
  final void Function(String) onRemoveStudent;
  final VoidCallback onRemoveClass;

  @override
  State<_ClassRow> createState() => _ClassRowState();
}

class _ClassRowState extends State<_ClassRow> {
  final _student = TextEditingController();

  @override
  void dispose() {
    _student.dispose();
    super.dispose();
  }

  void _add() {
    final name = _student.text.trim();
    if (name.isEmpty) return;
    widget.onAddStudent(name);
    _student.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cls = widget.cls;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: widget.onToggle,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(children: [
                IconTile(
                  icon: Icons.class_outlined,
                  tone: Tone.brand,
                  size: 34,
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Class ${cls.name}',
                          style: theme.textTheme.titleSmall),
                      Text(
                        cls.students.isEmpty
                            ? 'No students yet'
                            : '${cls.students.length} student'
                                '${cls.students.length == 1 ? '' : 's'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  tooltip: 'Remove class',
                  color: AppColors.textSecondary,
                  onPressed: widget.onRemoveClass,
                ),
                Icon(
                  widget.expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: AppColors.textSecondary,
                ),
              ]),
            ),
          ),
          if (widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.md, 0, AppSpace.md, AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _student,
                        onSubmitted: (_) => _add(),
                        decoration: const InputDecoration(
                          hintText: 'Student name',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    FilledButton.tonal(
                      onPressed: _add,
                      child: const Text('Add'),
                    ),
                  ]),
                  const SizedBox(height: AppSpace.md),
                  if (cls.students.isEmpty)
                    Text('Type a name and press Enter.',
                        style: theme.textTheme.bodySmall)
                  else
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: [
                        for (final s in cls.students)
                          Chip(
                            label: Text(s),
                            onDeleted: () => widget.onRemoveStudent(s),
                            deleteIcon: const Icon(Icons.close, size: 15),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// invite link
// ---------------------------------------------------------------------

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.token,
    required this.teachers,
    required this.onGenerate,
    required this.onJoined,
    required this.onRemove,
  });

  final String? token;
  final List<_DemoTeacher> teachers;
  final VoidCallback onGenerate;
  final void Function(_DemoTeacher) onJoined;
  final void Function(_DemoTeacher) onRemove;

  String get _link => '${AppConfig.appOrigin}/#/join/$token';

  Future<void> _openJoinForm(BuildContext context) async {
    final teacher = await showDialog<_DemoTeacher>(
      context: context,
      builder: (_) => const _JoinDialog(),
    );
    if (teacher != null) onJoined(teacher);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Step 2 · Invite your teachers',
      subtitle: 'One link. Every teacher fills in their own details.',
      icon: Icons.link_rounded,
      tone: Tone.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Send this to your staff group. Each teacher opens it, sets their '
            'own password, and picks their department and subjects — you never '
            'type a staff record yourself.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.lg),

          if (token == null)
            FilledButton.icon(
              onPressed: onGenerate,
              icon: const Icon(Icons.add_link_rounded, size: 18),
              label: const Text('Generate invite link'),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const StatusPill(label: 'Active', tone: Tone.success),
                    const SizedBox(width: AppSpace.sm),
                    Text('${teachers.length} joined',
                        style: theme.textTheme.bodySmall),
                  ]),
                  const SizedBox(height: AppSpace.sm),
                  SelectableText(
                    _link,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _link));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invite link copied')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy link'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _openJoinForm(context),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('See what a teacher sees'),
              ),
            ]),
          ],

          if (teachers.isNotEmpty) ...[
            const SizedBox(height: AppSpace.lg),
            const Divider(),
            const SizedBox(height: AppSpace.sm),
            Text('Joined so far', style: theme.textTheme.labelLarge),
            const SizedBox(height: AppSpace.sm),
            for (final t in teachers)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const IconTile(
                    icon: Icons.person_outline, tone: Tone.success, size: 34),
                title: Text(t.name),
                subtitle: Text(
                  t.subjects.isEmpty
                      ? t.department
                      : '${t.department} · ${t.subjects.join(', ')}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: AppColors.textSecondary,
                  onPressed: () => onRemove(t),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// What a teacher sees after opening the link. Shown as a dialog so the story
/// stays on one screen — the admin can demonstrate both sides without
/// navigating away and losing the state they just built.
class _JoinDialog extends StatefulWidget {
  const _JoinDialog();

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  String _department = _departments.keys.first;
  final Set<String> _subjects = {};

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subjects = _departments[_department] ?? const <String>[];

    return AlertDialog(
      title: const Text('Join your school'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('This is the page your teachers land on.',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpace.lg),

                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                      labelText: 'Full name', hintText: 'Anjali Nair'),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? 'Enter a name'
                      : null,
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) =>
                      (v == null || !v.contains('@')) ? 'Enter an email' : null,
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  validator: (v) => (v == null || v.length < 8)
                      ? 'Use at least 8 characters'
                      : null,
                ),
                const SizedBox(height: AppSpace.md),

                DropdownButtonFormField<String>(
                  initialValue: _department,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Department'),
                  items: [
                    for (final d in _departments.keys)
                      DropdownMenuItem(value: d, child: Text(d)),
                  ],
                  onChanged: (v) => setState(() {
                    _department = v ?? _department;
                    _subjects.clear();  // stale once the department changes
                  }),
                ),
                const SizedBox(height: AppSpace.md),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Subjects you teach',
                      style: theme.textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final s in subjects)
                      FilterChip(
                        label: Text(s),
                        selected: _subjects.contains(s),
                        onSelected: (on) => setState(() =>
                            on ? _subjects.add(s) : _subjects.remove(s)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _DemoTeacher(
                  _name.text.trim(), _department, _subjects.toList()..sort()),
            );
          },
          child: const Text('Create my account'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// what happens next
// ---------------------------------------------------------------------

class _NextCard extends StatelessWidget {
  const _NextCard({
    required this.ready,
    required this.classes,
    required this.teachers,
  });

  final bool ready;
  final int classes;
  final int teachers;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Step 3 · Build the timetable',
      subtitle: 'Once classes and staff exist, the solver takes over.',
      icon: Icons.calendar_month_rounded,
      tone: ready ? Tone.brand : Tone.neutral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ready
                ? 'With $classes classes and $teachers teachers, the solver '
                    'would now place every period without a clash and explain '
                    'anything it could not fit.'
                : 'Add some classes and let a teacher join, and this step '
                    'unlocks.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.md),
          const Callout(
            message: 'Nothing on this page was saved.',
            detail: 'Sign in as Admin to see the real system running against '
                'the seeded school.',
            tone: Tone.neutral,
            icon: Icons.info_outline_rounded,
          ),
        ],
      ),
    );
  }
}
