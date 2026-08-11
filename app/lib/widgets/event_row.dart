import 'package:flutter/material.dart';

import '../core/dates.dart';
import '../core/events_repository.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

/// One school event: when it runs and who it takes off the timetable.
///
/// Public and self-contained so the layout tests can render it without the app
/// shell. A dozen teacher chips inside a Wrap, nested in another Wrap of
/// status pills, is precisely the arrangement that has overflowed here before.
class EventRow extends StatelessWidget {
  const EventRow({super.key, required this.event, required this.onDelete});

  final SchoolEvent event;
  final VoidCallback onDelete;

  static String _fmt(DateTime d) => Dates.isoToDisplay(d.toIso8601String());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dates = event.isMultiDay
        ? '${_fmt(event.startsOn)} – ${_fmt(event.endsOn)}  '
            '(${event.days} days)'
        : _fmt(event.startsOn);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: event.isRunning ? AppColors.warningTint : AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: event.isRunning ? AppColors.warning : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(event.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(dates, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Delete event',
              onPressed: onDelete,
            ),
          ]),
          const SizedBox(height: AppSpace.sm),

          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (event.isRunning)
                const StatusPill(label: 'Running now', tone: Tone.warning),
              StatusPill(
                label: event.teachers.isEmpty
                    ? 'No staff assigned'
                    : '${event.teachers.length} staff',
                tone: event.teachers.isEmpty ? Tone.neutral : Tone.brand,
              ),
              if (event.teachers.isNotEmpty)
                StatusPill(
                  label: '${event.teacherDays} teacher-days',
                  tone: Tone.neutral,
                ),
              if (event.eventType != null)
                StatusPill(label: event.eventType!, tone: Tone.neutral),
            ],
          ),

          if (event.teachers.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                for (final t in event.teachers)
                  Chip(
                    label: Text(t.name),
                    visualDensity: VisualDensity.compact,
                    labelStyle: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ],
          if (event.notes != null && event.notes!.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(event.notes!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
