import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_controller.dart';
import '../core/operations_repository.dart';
import '../widgets/hod_approvals_card.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/today_periods_card.dart';
import '../widgets/ui/primitives.dart';

/// A teacher's day: anything awaiting their approval, then their periods.
class TeacherPortal extends ConsumerWidget {
  const TeacherPortal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    final approvals = ref.watch(pendingApprovalsProvider);
    final pending = approvals.whenOrNull(data: (l) => l.length) ?? 0;

    return AppShell(
      title: 'Good day, ${profile?.fullName.split(' ').first ?? ''}',
      subtitle: [
        if (profile?.departmentName != null) profile!.departmentName!,
        if (profile?.isApprover ?? false) 'Head of Department',
      ].join(' · '),
      actions: [
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: StatusPill(
              label: '$pending awaiting you',
              tone: Tone.danger,
              icon: Icons.approval_outlined,
            ),
          ),
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () {
            ref.invalidate(periodsTodayProvider);
            ref.invalidate(pendingApprovalsProvider);
          },
        ),
      ],
      child: const PageBody(maxWidth: 900, children: [
        // Renders itself away unless this teacher is an approver with a
        // queue, so a plain teacher never sees an empty panel.
        HodApprovalsCard(),
        TodayPeriodsCard(),
      ]),
    );
  }
}
