import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/auth_controller.dart';
import '../core/documents_repository.dart';
import '../core/forecast_repository.dart';
import '../core/operations_repository.dart';
import '../core/timetable_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/action_board_card.dart';
import '../widgets/document_queue_card.dart';
import '../widgets/forecast_card.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/timetable_summary_card.dart';
import '../widgets/ui/primitives.dart';

class AdminDashboard extends ConsumerWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    return AppShell(
      title: 'Good day, ${profile?.fullName.split(' ').first ?? ''}',
      subtitle: 'Everything that needs you, in one place',
      actions: [
        IconButton(
          tooltip: 'Refresh everything',
          icon: const Icon(Icons.refresh),
          onPressed: () {
            ref.invalidate(actionBoardProvider);
            ref.invalidate(staffingForecastProvider);
            ref.invalidate(documentQueueProvider);
            ref.invalidate(activeTimetableProvider);
            ref.invalidate(backendHealthProvider);
          },
        ),
      ],
      child: PageBody(children: [
        const _SchoolSummary(),
        gap16,

        // Needs attention now, then what is coming. Everything else after.
        const ActionBoardCard(),
        gap16,
        const ForecastSummaryCard(),
        gap16,

        if (wide)
          const IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: DocumentQueueCard()),
              SizedBox(width: AppSpace.lg),
              Expanded(child: TimetableSummaryCard()),
            ]),
          )
        else ...[
          const DocumentQueueCard(),
          gap16,
          const TimetableSummaryCard(),
        ],
      ]),
    );
  }
}

/// The one-line answer to "how big is this school", which also proves the
/// whole stack is live.
class _SchoolSummary extends ConsumerWidget {
  const _SchoolSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(backendHealthProvider);

    return health.when(
      // No fixed height: this was 52px, sized for a bare spinner, which
      // clipped the cold-start explanation to its first line. The card should
      // grow to fit whatever the loader has to say.
      loading: () => const SectionCard(child: SlowLoader()),
      error: (e, _) => Callout(
        tone: Tone.danger,
        message: 'Cannot reach the API',
        detail: 'Is the backend running? $e',
      ),
      data: (data) {
        final counts = (data['row_counts'] as Map).cast<String, dynamic>();
        String n(String k) => '${counts[k] ?? '—'}';

        return SectionCard(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.xl, vertical: AppSpace.lg),
          child: Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            children: [
              // The first two open a directory. The rest are counts with
              // nowhere useful to go, so they carry a hint saying what they
              // are instead of a chevron promising a screen that isn't there.
              StatTile(
                  value: n('students'),
                  label: 'Students',
                  hint: 'browse by class',
                  icon: Icons.groups_outlined,
                  width: 150,
                  onTap: () => context.go('/students')),
              StatTile(
                  value: n('profiles'),
                  label: 'Staff',
                  hint: 'browse by department',
                  icon: Icons.badge_outlined,
                  width: 150,
                  onTap: () => context.go('/staff')),
              StatTile(
                  value: n('classes'),
                  label: 'Classes',
                  hint: 'sections, 1A to 10D',
                  icon: Icons.meeting_room_outlined,
                  width: 150),
              StatTile(
                  value: n('teaching_assignments'),
                  label: 'Assignments',
                  hint: 'who teaches what',
                  icon: Icons.assignment_outlined,
                  width: 150),
              StatTile(
                  value: n('attendance'),
                  label: 'Attendance marks',
                  hint: 'records to date',
                  icon: Icons.how_to_reg_outlined,
                  width: 150),
            ],
          ),
        );
      },
    );
  }
}
