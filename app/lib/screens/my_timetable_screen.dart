import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/timetable_repository.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/teacher_summary_card.dart';
import '../widgets/ui/primitives.dart';
import '../widgets/my_timetable_card.dart';

class MyTimetableScreen extends ConsumerWidget {
  const MyTimetableScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppShell(
      title: 'My timetable',
      subtitle: 'Your week, from the published master timetable',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(myTimetableProvider),
        ),
      ],
      child: const PageBody(children: [
        MyTimetableCard(),
        gap16,
        TeacherSummaryCard(),
      ]),
    );
  }
}
