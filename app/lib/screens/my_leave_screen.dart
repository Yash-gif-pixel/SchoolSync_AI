import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../widgets/leave_card.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';

class MyLeaveScreen extends ConsumerWidget {
  const MyLeaveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppShell(
      title: 'Leave',
      subtitle: 'Request time off and track what has been approved',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(myLeaveProvider),
        ),
      ],
      child: const PageBody(maxWidth: 760, children: [LeaveCard()]),
    );
  }
}
