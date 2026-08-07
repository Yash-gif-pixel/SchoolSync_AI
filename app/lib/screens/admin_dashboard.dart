import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_controller.dart';
import '../widgets/action_board_card.dart';
import '../widgets/backend_status_card.dart';
import '../widgets/document_queue_card.dart';
import '../widgets/forecast_card.dart';
import '../widgets/phase_roadmap_card.dart';
import '../widgets/timetable_summary_card.dart';
import '../widgets/user_chip.dart';

class AdminDashboard extends ConsumerWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: const [UserChip()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Welcome, ${profile?.fullName ?? ''}',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Macro view — full visibility across the school',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          // First on the page: it is the only card that tells the admin
          // something needs doing right now.
          const ActionBoardCard(),
          const SizedBox(height: 16),
          // Second: what is coming, after what is already here.
          const ForecastSummaryCard(),
          const SizedBox(height: 16),
          const DocumentQueueCard(),
          const SizedBox(height: 16),
          const TimetableSummaryCard(),
          const SizedBox(height: 16),
          const BackendStatusCard(),
          const SizedBox(height: 16),
          const PhaseRoadmapCard(isAdmin: true),
        ],
      ),
    );
  }
}
