import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/directory_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

/// The student roll, class by class.
///
/// Eighteen hundred names is far too many to render at once, so each class is
/// a collapsed row and only the open one builds its list. Search looks across
/// the whole roll and opens whichever classes contain a match.
class StudentsScreen extends ConsumerStatefulWidget {
  const StudentsScreen({super.key});

  @override
  ConsumerState<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends ConsumerState<StudentsScreen> {
  final _search = TextEditingController();
  String? _open;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roll = ref.watch(rollProvider);
    final query = _search.text.trim().toLowerCase();

    return AppShell(
      title: 'Students',
      subtitle: 'The roll, class by class',
      child: PageBody(children: [
        roll.when(
          loading: () => const SectionCard(
            title: 'Loading the roll',
            icon: Icons.groups_outlined,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) => SectionCard(
            title: 'Students',
            icon: Icons.groups_outlined,
            child: Callout(
              message: 'Could not load the roll.',
              detail: '$e',
              tone: Tone.danger,
            ),
          ),
          data: (r) {
            final grouped = r.byClass;
            final matching = query.isEmpty
                ? grouped
                : {
                    for (final entry in grouped.entries)
                      if (entry.value.any((s) =>
                          s.name.toLowerCase().contains(query) ||
                          '${s.rollNo ?? ''}' == query))
                        entry.key: entry.value
                            .where((s) =>
                                s.name.toLowerCase().contains(query) ||
                                '${s.rollNo ?? ''}' == query)
                            .toList(),
                  };

            final names = matching.keys.toList()
              ..sort((a, b) => _classOrder(a).compareTo(_classOrder(b)));

            final shown =
                matching.values.fold(0, (n, list) => n + list.length);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.md,
                  children: [
                    StatTile(
                      value: '${r.students.length}',
                      label: 'Students on roll',
                      icon: Icons.groups_outlined,
                      tone: Tone.brand,
                    ),
                    StatTile(
                      value: '${r.classes.length}',
                      label: 'Classes',
                      icon: Icons.meeting_room_outlined,
                    ),
                    StatTile(
                      value: r.classes.isEmpty
                          ? '—'
                          : (r.students.length / r.classes.length)
                              .toStringAsFixed(0),
                      label: 'Average class size',
                      icon: Icons.chair_alt_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.xl),

                SectionCard(
                  title: 'By class',
                  subtitle: query.isEmpty
                      ? 'Tap a class to see its register.'
                      : '$shown match in ${names.length} class(es)',
                  icon: Icons.list_alt_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon:
                              const Icon(Icons.search_rounded, size: 18),
                          hintText: 'Search by name or roll number',
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded,
                                      size: 18),
                                  onPressed: () => setState(_search.clear),
                                ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),

                      if (names.isEmpty)
                        EmptyState(
                          icon: Icons.person_search_outlined,
                          title: 'No students match "$query"',
                          message: 'Try a different name or roll number.',
                        )
                      else
                        for (final name in names)
                          _ClassBlock(
                            className: name,
                            students: matching[name]!,
                            // A search result is worth opening on sight;
                            // eighteen hundred names are not.
                            open: query.isNotEmpty || _open == name,
                            onToggle: () => setState(
                                () => _open = _open == name ? null : name),
                          ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.xl),
      ]),
    );
  }

  /// "10A" must sort after "9D", so compare the number, not the string.
  static int _classOrder(String name) {
    final digits = RegExp(r'^\d+').firstMatch(name)?.group(0);
    final grade = int.tryParse(digits ?? '') ?? 99;
    final section = name.replaceFirst(digits ?? '', '');
    return grade * 100 + (section.isEmpty ? 0 : section.codeUnitAt(0));
  }
}

class _ClassBlock extends StatelessWidget {
  const _ClassBlock({
    required this.className,
    required this.students,
    required this.open,
    required this.onToggle,
  });

  final String className;
  final List<Student> students;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(children: [
                const IconTile(
                    icon: Icons.class_outlined, tone: Tone.brand, size: 34),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text('Class $className',
                      style: theme.textTheme.titleSmall),
                ),
                StatusPill(
                    label: '${students.length} students', tone: Tone.neutral),
                const SizedBox(width: AppSpace.sm),
                Icon(
                  open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: AppColors.textSecondary,
                ),
              ]),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.md, 0, AppSpace.md, AppSpace.md),
              child: Column(
                children: [
                  const Divider(),
                  for (final s in students)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: SizedBox(
                        width: 34,
                        child: Text(
                          '${s.rollNo ?? '—'}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      title: Text(s.name, style: theme.textTheme.bodyMedium),
                      subtitle: s.guardianName == null
                          ? null
                          : Text(
                              [
                                s.guardianName!,
                                ?s.guardianPhone,
                              ].join(' · '),
                              style: theme.textTheme.labelSmall,
                            ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
