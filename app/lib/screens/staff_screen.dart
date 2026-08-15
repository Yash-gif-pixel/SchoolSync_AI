import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/directory_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

/// The staff list, department by department.
///
/// Heads of department are pinned to the top of their own group and the Vice
/// Principal to the top of the page: an org chart that lists everyone
/// alphabetically tells you nothing about who to ask.
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  final _search = TextEditingController();
  String? _busy;

  /// Appointing is a swap, not an addition: the API stands the incumbent down
  /// in the same call, and reports who that was so this can say so out loud.
  Future<void> _appoint(StaffMember p, String role, bool appointed) async {
    setState(() => _busy = p.id);
    try {
      final replaced = await ref.read(directoryRepositoryProvider).appoint(
            profileId: p.id,
            role: role,
            appointed: appointed,
          );
      ref.invalidate(staffProvider);
      if (!mounted) return;
      final what = _roleLabels[role] ?? role;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(appointed
            ? replaced.isEmpty
                ? '${p.name} is now $what.'
                : '${p.name} is now $what, replacing ${replaced.join(', ')}.'
            : '${p.name} is no longer $what.'),
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.danger,
        content: Text(_readable(e)),
      ));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(staffProvider);
    final query = _search.text.trim().toLowerCase();

    return AppShell(
      title: 'Staff',
      subtitle: 'Who works where',
      child: PageBody(children: [
        staff.when(
          loading: () => const SectionCard(
            title: 'Loading the staff list',
            icon: Icons.badge_outlined,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
              child: SlowLoader(),
            ),
          ),
          error: (e, _) => SectionCard(
            title: 'Staff',
            icon: Icons.badge_outlined,
            child: Callout(
              message: 'Could not load the staff list.',
              detail: '$e',
              tone: Tone.danger,
            ),
          ),
          data: (people) {
            final matching = query.isEmpty
                ? people
                : people
                    .where((p) =>
                        p.name.toLowerCase().contains(query) ||
                        p.group.toLowerCase().contains(query) ||
                        (p.title ?? '').toLowerCase().contains(query))
                    .toList();

            final grouped = <String, List<StaffMember>>{};
            for (final p in matching) {
              grouped.putIfAbsent(p.group, () => []).add(p);
            }
            for (final list in grouped.values) {
              // Head of department first, then everyone else by name.
              list.sort((a, b) {
                if (a.isApprover != b.isApprover) return a.isApprover ? -1 : 1;
                return a.name.compareTo(b.name);
              });
            }

            final groups = grouped.keys.toList()..sort();
            final hods = people.where((p) => p.isApprover).length;
            final teaching = people.where((p) => !p.isAdmin).length;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.md,
                  children: [
                    StatTile(
                      value: '${people.length}',
                      label: 'Staff',
                      icon: Icons.badge_outlined,
                      tone: Tone.brand,
                    ),
                    StatTile(
                      value: '$teaching',
                      label: 'Teaching staff',
                      icon: Icons.school_outlined,
                    ),
                    StatTile(
                      value: '${grouped.length}',
                      label: 'Departments',
                      icon: Icons.account_tree_outlined,
                    ),
                    StatTile(
                      value: '$hods',
                      label: 'Heads of department',
                      hint: 'they approve leave',
                      icon: Icons.verified_user_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.xl),

                if (query.isEmpty) ...[
                  _Leadership(
                    staff: people,
                    onAppoint: _appoint,
                    busy: _busy,
                  ),
                  const SizedBox(height: AppSpace.xl),
                ],

                SectionCard(
                  title: 'By department',
                  subtitle: query.isEmpty
                      ? '${groups.length} departments'
                      : '${matching.length} match "$query"',
                  icon: Icons.account_tree_outlined,
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
                          hintText: 'Search by name, department or role',
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

                      if (groups.isEmpty)
                        EmptyState(
                          icon: Icons.person_search_outlined,
                          title: 'Nobody matches "$query"',
                          message: 'Try a different name or department.',
                        )
                      else
                        for (final g in groups) ...[
                          Padding(
                            padding: const EdgeInsets.only(
                                top: AppSpace.md, bottom: AppSpace.xs),
                            child: Row(children: [
                              Text(g,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge),
                              const SizedBox(width: AppSpace.sm),
                              StatusPill(
                                label: '${grouped[g]!.length}',
                                tone: Tone.neutral,
                              ),
                            ]),
                          ),
                          for (final p in grouped[g]!)
                            _StaffTile(
                              person: p,
                              onAppoint: _appoint,
                              busy: _busy,
                            ),
                        ],
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
}

const _roleLabels = {
  'principal': 'Principal',
  'vice_principal': 'Vice Principal',
  'hod': 'Head of Department',
};

String _readable(ApiException e) {
  final at = e.message.indexOf('"detail":"');
  if (at == -1) return e.message;
  final rest = e.message.substring(at + 10);
  final end = rest.indexOf('"');
  return end == -1 ? rest : rest.substring(0, end);
}

typedef AppointFn = Future<void> Function(
    StaffMember person, String role, bool appointed);

/// The two school-wide posts, and who holds them.
///
/// Shown as "Vacant" when nobody does — an empty space reads as still loading,
/// and an unfilled post is exactly the thing an admin opened this page to fix.
class _Leadership extends StatelessWidget {
  const _Leadership({
    required this.staff,
    required this.onAppoint,
    required this.busy,
  });

  final List<StaffMember> staff;
  final AppointFn onAppoint;
  final String? busy;

  StaffMember? _holder(bool Function(StaffMember) test) {
    for (final p in staff) {
      if (test(p)) return p;
    }
    return null;
  }

  Future<void> _pick(BuildContext context, String role) async {
    // Teaching staff only. The API refuses the admin account anyway, and
    // offering a choice that will be rejected is worse than not offering it.
    final choices = staff.where((p) => !p.isAdmin).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final chosen = await showDialog<StaffMember>(
      context: context,
      builder: (_) => _PickPersonDialog(
        title: 'Appoint ${_roleLabels[role]}',
        people: choices,
      ),
    );
    if (chosen != null) await onAppoint(chosen, role, true);
  }

  Widget _post(
    BuildContext context, {
    required String role,
    required String blurb,
    required IconData icon,
    required StaffMember? holder,
  }) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: holder == null ? AppColors.warning : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconTile(
              icon: icon,
              tone: holder == null ? Tone.warning : Tone.success,
              size: 34,
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(holder?.name ?? 'Vacant',
                      style: theme.textTheme.titleSmall),
                  Text('${_roleLabels[role]} · $blurb',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ]),
          const SizedBox(height: AppSpace.sm),
          Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: [
            FilledButton.tonal(
              onPressed: busy != null ? null : () => _pick(context, role),
              child: Text(holder == null ? 'Appoint' : 'Replace'),
            ),
            if (holder != null)
              TextButton(
                onPressed:
                    busy != null ? null : () => onAppoint(holder, role, false),
                style:
                    TextButton.styleFrom(foregroundColor: AppColors.danger),
                child: const Text('Stand down'),
              ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Leadership',
      subtitle: 'Appoint the principal, the vice principal and the heads of '
          'department.',
      icon: Icons.workspace_premium_outlined,
      tone: Tone.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _post(context,
              role: 'principal',
              blurb: 'heads the school',
              icon: Icons.school_outlined,
              holder: _holder((p) => p.isPrincipal)),
          _post(context,
              role: 'vice_principal',
              blurb: 'reviews leave for the heads of department',
              icon: Icons.workspace_premium_outlined,
              holder: _holder((p) => p.isVicePrincipal)),
          Text(
            'Heads of department are appointed from the list below, one per '
            'department. The administrator account is office staff and cannot '
            'hold any of these posts.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PickPersonDialog extends StatefulWidget {
  const _PickPersonDialog({required this.title, required this.people});

  final String title;
  final List<StaffMember> people;

  @override
  State<_PickPersonDialog> createState() => _PickPersonDialogState();
}

class _PickPersonDialogState extends State<_PickPersonDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.people
        : widget.people
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.group.toLowerCase().contains(q))
            .toList();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                hintText: 'Search staff',
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            // Bounded: fifty odd names would push the buttons off screen.
            SizedBox(
              height: 300,
              child: shown.isEmpty
                  ? Center(
                      child: Text('Nobody matches "$q".',
                          style: Theme.of(context).textTheme.bodySmall))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final p = shown[i];
                        return ListTile(
                          dense: true,
                          title: Text(p.name),
                          subtitle: Text(p.subtitle),
                          trailing: p.title == null
                              ? null
                              : StatusPill(
                                  label: p.title!, tone: Tone.neutral),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({
    required this.person,
    required this.onAppoint,
    required this.busy,
  });

  final StaffMember person;
  final AppointFn onAppoint;
  final String? busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial =
        person.name.trim().isEmpty ? '?' : person.name.trim()[0].toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.xs),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.brandTint,
            shape: BoxShape.circle,
          ),
          child: Text(initial,
              style: const TextStyle(
                  color: AppColors.brandDark,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(person.name, style: theme.textTheme.bodyMedium),
              Text(
                [?person.employeeCode, person.subtitle].join(' · '),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        if (person.title != null)
          StatusPill(
            label: person.title!,
            tone: person.isPrincipal || person.isVicePrincipal
                ? Tone.success
                : person.isAdmin
                    ? Tone.neutral
                    : Tone.brand,
          ),

        // Only teaching staff in a department can head one, so nobody else
        // gets a menu that would only ever refuse them.
        if (!person.isAdmin && person.departmentId != null) ...[
          const SizedBox(width: AppSpace.xs),
          PopupMenuButton<String>(
            enabled: busy == null,
            tooltip: 'Appointments',
            icon: const Icon(Icons.more_vert_rounded,
                size: 18, color: AppColors.textSecondary),
            onSelected: (v) => switch (v) {
              'hod_on' => onAppoint(person, 'hod', true),
              'hod_off' => onAppoint(person, 'hod', false),
              'vp' => onAppoint(person, 'vice_principal', true),
              'principal' => onAppoint(person, 'principal', true),
              _ => null,
            },
            itemBuilder: (_) => [
              if (person.isApprover)
                const PopupMenuItem(
                  value: 'hod_off',
                  child: Text('Stand down as head of department'),
                )
              else
                PopupMenuItem(
                  value: 'hod_on',
                  child: Text('Make head of ${person.department}'),
                ),
              if (!person.isVicePrincipal)
                const PopupMenuItem(
                  value: 'vp',
                  child: Text('Appoint as Vice Principal'),
                ),
              if (!person.isPrincipal)
                const PopupMenuItem(
                  value: 'principal',
                  child: Text('Appoint as Principal'),
                ),
            ],
          ),
        ],
      ]),
    );
  }
}
