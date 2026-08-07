import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_controller.dart';
import '../widgets/phase_roadmap_card.dart';
import '../widgets/teacher_summary_card.dart';
import '../widgets/user_chip.dart';

class TeacherPortal extends ConsumerWidget {
  const TeacherPortal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Teacher Portal'),
        actions: const [UserChip()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Welcome, ${profile?.fullName ?? ''}',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (profile?.departmentName != null)
                        profile!.departmentName!,
                      if (profile?.isApprover ?? false) 'Head of Department',
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (profile?.isApprover ?? false)
              Chip(
                avatar: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('Can approve leave'),
                backgroundColor: theme.colorScheme.secondaryContainer,
              ),
          ]),
          const SizedBox(height: 20),
          const TeacherSummaryCard(),
          const SizedBox(height: 16),
          const PhaseRoadmapCard(isAdmin: false),
        ],
      ),
    );
  }
}
