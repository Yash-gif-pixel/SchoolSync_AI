import 'package:flutter/material.dart';

import '../core/seating_repository.dart';
import '../theme/app_theme.dart';

/// A month grid for picking exam days.
///
/// Two months at a time on a wide screen, because an exam season routinely
/// straddles the turn of a month and paging back and forth to see both halves
/// is how a date gets missed.
///
/// Days already booked show the grades sitting that day. Tapping any day hands
/// it back so the caller can add or edit a sitting.
class ExamCalendar extends StatefulWidget {
  const ExamCalendar({
    super.key,
    required this.sittings,
    required this.onPickDay,
    this.initialMonth,
  });

  final List<Sitting> sittings;
  final void Function(DateTime day) onPickDay;
  final DateTime? initialMonth;

  @override
  State<ExamCalendar> createState() => _ExamCalendarState();
}

class _ExamCalendarState extends State<ExamCalendar> {
  late DateTime _anchor;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialMonth ??
        (widget.sittings.isEmpty
            ? DateTime.now()
            : widget.sittings.first.sitsOn);
    _anchor = DateTime(seed.year, seed.month);
  }

  void _shift(int months) => setState(
      () => _anchor = DateTime(_anchor.year, _anchor.month + months));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final months = wide
        ? [_anchor, DateTime(_anchor.year, _anchor.month + 1)]
        : [_anchor];

    // Sittings keyed by day, so a cell does one lookup instead of scanning.
    final byDay = <DateTime, List<Sitting>>{};
    for (final s in widget.sittings) {
      final key = DateTime(s.sitsOn.year, s.sitsOn.month, s.sitsOn.day);
      byDay.putIfAbsent(key, () => []).add(s);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous month',
            onPressed: () => _shift(-1),
          ),
          Expanded(
            child: Text(
              months.map(_monthLabel).join('   ·   '),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next month',
            onPressed: () => _shift(1),
          ),
        ]),
        const SizedBox(height: AppSpace.sm),

        // Months side by side on a wide screen. Wrap rather than Row so the
        // second month drops below instead of overflowing at awkward widths.
        Wrap(
          spacing: AppSpace.xl,
          runSpacing: AppSpace.lg,
          children: [
            for (final m in months)
              SizedBox(
                width: 320,
                child: _MonthGrid(
                  month: m,
                  byDay: byDay,
                  onPickDay: widget.onPickDay,
                ),
              ),
          ],
        ),
      ],
    );
  }

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static String _monthLabel(DateTime d) =>
      '${_monthNames[d.month - 1]} ${d.year}';
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.byDay,
    required this.onPickDay,
  });

  final DateTime month;
  final Map<DateTime, List<Sitting>> byDay;
  final void Function(DateTime) onPickDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final first = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Monday-first, matching the school week the timetable already uses.
    final leading = first.weekday - 1;
    final today = DateTime.now();

    final cells = <Widget>[
      for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
        Center(
          child: Text(d,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.textTertiary)),
        ),
      for (var i = 0; i < leading; i++) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day++)
        _DayCell(
          date: DateTime(month.year, month.month, day),
          sittings: byDay[DateTime(month.year, month.month, day)] ?? const [],
          isToday: today.year == month.year &&
              today.month == month.month &&
              today.day == day,
          onTap: onPickDay,
        ),
    ];

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 2,
      crossAxisSpacing: 2,
      childAspectRatio: 0.92,
      children: cells,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.sittings,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final List<Sitting> sittings;
  final bool isToday;
  final void Function(DateTime) onTap;

  @override
  Widget build(BuildContext context) {
    final booked = sittings.isNotEmpty;
    final sunday = date.weekday == DateTime.sunday;
    final grades = <int>{for (final s in sittings) ...s.grades}.toList()
      ..sort();
    final allPlanned = booked && sittings.every((s) => s.hasPlan);

    return Tooltip(
      message: booked
          ? sittings
              .map((s) => [
                    if (s.paper != null) s.paper,
                    s.gradeLabel,
                    if (s.hasPlan) 'seated' else 'no plan yet',
                  ].join(' · '))
              .join('\n')
          : 'Add a sitting on ${date.day}/${date.month}',
      child: Material(
        color: booked
            ? (allPlanned ? AppColors.successTint : AppColors.brandTint)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          onTap: () => onTap(date),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: booked
                    ? (allPlanned ? AppColors.success : AppColors.brand)
                    : (isToday ? AppColors.borderStrong : Colors.transparent),
                width: booked ? 1 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        booked || isToday ? FontWeight.w700 : FontWeight.w400,
                    color: booked
                        ? (allPlanned
                            ? AppColors.success
                            : AppColors.brandDark)
                        : sunday
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                  ),
                ),
                if (grades.isNotEmpty)
                  Text(
                    grades.length > 2
                        ? '${grades.length} grades'
                        : grades.join(','),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 8.5,
                      color: allPlanned
                          ? AppColors.success
                          : AppColors.brandDark,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
