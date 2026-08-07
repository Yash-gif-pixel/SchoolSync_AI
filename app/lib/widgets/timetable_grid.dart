import 'package:flutter/material.dart';

import '../models/timetable.dart';

/// A week grid: periods down, days across.
///
/// Filtered to one class or one teacher — a whole-school grid would be 40
/// classes x 36 slots, which is a spreadsheet, not something you read.
class TimetableGrid extends StatelessWidget {
  const TimetableGrid({
    super.key,
    required this.timetable,
    this.className,
    this.teacherId,
    this.showTeacher = true,
    this.showClass = false,
  });

  final Timetable timetable;
  final String? className;
  final String? teacherId;
  final bool showTeacher;
  final bool showClass;

  static const _subjectColours = <String, Color>{
    'MATH': Color(0xFF1565C0),
    'SCI': Color(0xFF2E7D32),
    'ENG': Color(0xFF6A1B9A),
    'HIN': Color(0xFFC62828),
    'SST': Color(0xFFEF6C00),
    'CS': Color(0xFF00838F),
    'PE': Color(0xFF558B2F),
  };

  Color _colourFor(String code) =>
      _subjectColours[code] ?? const Color(0xFF546E7A);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = timetable.days;
    final periods = timetable.periods;

    if (days.isEmpty || periods.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text('Nothing scheduled',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      const labelWidth = 64.0;
      const minCellWidth = 96.0;
      final available = constraints.maxWidth - labelWidth;

      // Never nest a horizontal scroller inside the page's vertical list.
      // On Flutter web a horizontal scrollable under the cursor swallows the
      // mouse wheel, so the page stops scrolling while the pointer is over
      // the grid. Below the width a readable grid needs, fall back to a
      // day-by-day list — which is the better layout on a narrow screen
      // anyway.
      if (available < minCellWidth * days.length) {
        return _DayList(
          timetable: timetable,
          days: days,
          periods: periods,
          className: className,
          teacherId: teacherId,
          colourFor: _colourFor,
          showTeacher: showTeacher,
          showClass: showClass,
        );
      }

      final cellWidth = (available / days.length).clamp(minCellWidth, 220.0);

      return SizedBox(
        width: labelWidth + cellWidth * days.length,
        child: Column(children: [
          // header
          Row(children: [
            const SizedBox(width: labelWidth),
            for (final d in days)
              SizedBox(
                width: cellWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    dayNames[d],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ]),
          const Divider(height: 1),
          for (final p in periods)
            Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: labelWidth,
                height: 62,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('P$p',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      timetable.startTimes[p] ?? '',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ]),
                ),
              ),
              for (final d in days)
                SizedBox(
                  width: cellWidth,
                  height: 62,
                  child: _Cell(
                    entry: timetable.at(d, p,
                        className: className, teacherId: teacherId),
                    colourFor: _colourFor,
                    showTeacher: showTeacher,
                    showClass: showClass,
                  ),
                ),
            ]),
        ]),
      );
    });
  }
}

/// Narrow-screen layout: one section per day, periods listed down the page.
/// No horizontal scrolling, so nothing competes with the page's own scroll.
class _DayList extends StatelessWidget {
  const _DayList({
    required this.timetable,
    required this.days,
    required this.periods,
    required this.colourFor,
    required this.showTeacher,
    required this.showClass,
    this.className,
    this.teacherId,
  });

  final Timetable timetable;
  final List<int> days;
  final List<int> periods;
  final Color Function(String) colourFor;
  final bool showTeacher;
  final bool showClass;
  final String? className;
  final String? teacherId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in days)
          Builder(builder: (_) {
            final lessons = [
              for (final p in periods)
                (p, timetable.at(d, p, className: className, teacherId: teacherId)),
            ].where((t) => t.$2 != null).toList();

            if (lessons.isEmpty) return const SizedBox.shrink();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(dayNamesLong[d],
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                for (final (p, e) in lessons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      SizedBox(
                        width: 34,
                        child: Text('P$p',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                      Container(
                        width: 3,
                        height: 30,
                        margin: const EdgeInsets.only(right: 10),
                        color: colourFor(e!.subjectCode),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.subjectName,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colourFor(e.subjectCode))),
                            Text(
                              [
                                if (showClass) e.className,
                                if (showTeacher) e.teacherName,
                                if (e.roomName != null) e.roomName!,
                              ].join(' · '),
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      Text(e.timeRange,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline)),
                    ]),
                  ),
              ],
            );
          }),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.entry,
    required this.colourFor,
    required this.showTeacher,
    required this.showClass,
  });

  final TimetableEntry? entry;
  final Color Function(String) colourFor;
  final bool showTeacher;
  final bool showClass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = entry;

    if (e == null) {
      return Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text('free',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
      );
    }

    final colour = colourFor(e.subjectCode);
    final secondary = <String>[
      if (showClass) e.className,
      if (showTeacher) e.teacherName,
    ].join(' · ');

    // Deliberately no Tooltip. One per cell means 36 MouseRegions doing hover
    // hit-testing on every pointer move, which is felt as scroll lag on web —
    // and everything the tooltip said is already visible in the cell.
    return Container(
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: colour, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(children: [
            Flexible(
              child: Text(
                e.subjectName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600, color: colour),
              ),
            ),
            if (e.requiresLab)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.science_outlined, size: 12, color: colour),
              ),
          ]),
          if (secondary.isNotEmpty)
            Text(
              secondary,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (e.roomName != null)
            Text(
              e.roomName!,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline, fontSize: 10),
            ),
        ],
      ),
    );
  }
}
