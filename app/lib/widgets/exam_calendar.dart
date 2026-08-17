import 'package:flutter/material.dart';

import '../core/seating_repository.dart';
import '../theme/app_theme.dart';

/// A month grid for picking exam days.
///
/// **One month at a time**, paged with the arrows either side of its name.
///
/// It used to show two side by side on a wide screen, on the reasoning that an
/// exam season often straddles the turn of a month and paging back and forth
/// is how a date gets missed. One column is clearer, so the risk that argued
/// for two is handled directly instead: if the season has days in a month you
/// are not looking at, the calendar says so underneath and offers to take you
/// there. That is better than the second grid ever was, because it also points
/// at months that are further away than next.
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

  /// The nearest month either side of the one on screen that has exam days on
  /// it, so the calendar can offer to go there.
  (DateTime?, DateTime?) get _neighbouringMonths {
    DateTime? before, after;
    for (final s in widget.sittings) {
      final m = DateTime(s.sitsOn.year, s.sitsOn.month);
      if (m.isBefore(_anchor)) {
        if (before == null || m.isAfter(before)) before = m;
      } else if (m.isAfter(_anchor)) {
        if (after == null || m.isBefore(after)) after = m;
      }
    }
    return (before, after);
  }

  int _daysIn(DateTime month) => widget.sittings
      .where((s) =>
          s.sitsOn.year == month.year && s.sitsOn.month == month.month)
      .length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Sittings keyed by day, so a cell does one lookup instead of scanning.
    final byDay = <DateTime, List<Sitting>>{};
    for (final s in widget.sittings) {
      final key = DateTime(s.sitsOn.year, s.sitsOn.month, s.sitsOn.day);
      byDay.putIfAbsent(key, () => []).add(s);
    }

    final (before, after) = _neighbouringMonths;

    // Centred rather than left-aligned: one grid in a full-width card looks
    // stranded against the left edge, and the heading is centred on the grid
    // either way, which is the thing that was wrong before.
    return Center(
      child: SizedBox(
        width: _monthWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MonthHeader(
              label: _monthLabel(_anchor),
              style: theme.textTheme.titleSmall,
              onPrevious: () => _shift(-1),
              onNext: () => _shift(1),
            ),
            const SizedBox(height: AppSpace.xs),
            _MonthGrid(
              month: _anchor,
              byDay: byDay,
              onPickDay: widget.onPickDay,
            ),
            if (before != null || after != null) ...[
              const SizedBox(height: AppSpace.sm),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpace.sm,
                children: [
                  if (before != null)
                    _JumpChip(
                      label: _elsewhereLabel(before),
                      icon: Icons.chevron_left_rounded,
                      iconFirst: true,
                      onTap: () => setState(() => _anchor = before),
                    ),
                  if (after != null)
                    _JumpChip(
                      label: _elsewhereLabel(after),
                      icon: Icons.chevron_right_rounded,
                      iconFirst: false,
                      onTap: () => setState(() => _anchor = after),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Seven columns of day cell, and the width the heading is centred over.
  static const _monthWidth = 320.0;

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// "2 days in Nov". Short on purpose: two of these have to sit side by side
  /// under a 320px grid, and the year is nearly always the one on screen.
  String _elsewhereLabel(DateTime month) {
    final n = _daysIn(month);
    final name = _monthNames[month.month - 1].substring(0, 3);
    final year = month.year == _anchor.year ? '' : ' ${month.year}';
    return '$n ${n == 1 ? 'day' : 'days'} in $name$year';
  }

  static String _monthLabel(DateTime d) =>
      '${_monthNames[d.month - 1]} ${d.year}';
}

/// "Go to the month that has the rest of this exam on it."
class _JumpChip extends StatelessWidget {
  const _JumpChip({
    required this.label,
    required this.icon,
    required this.iconFirst,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool iconFirst;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: AppColors.brandDark),
    );

    return ConstrainedBox(
      // Half the grid, less the gap, so two of these fit on one line and
      // neither can overflow whatever the month is called.
      constraints: const BoxConstraints(maxWidth: 150),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconFirst) Icon(icon, size: 14, color: AppColors.brandDark),
              Flexible(child: text),
              if (!iconFirst) Icon(icon, size: 14, color: AppColors.brandDark),
            ],
          ),
        ),
      ),
    );
  }
}

/// The month's name, with the paging arrows either side of it.
///
/// Both arrow slots are always the same width, occupied or not, so the name
/// lands in the middle of the grid underneath it.
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.label,
    required this.style,
    this.onPrevious,
    this.onNext,
  });

  final String label;
  final TextStyle? style;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  static const _arrowSlot = 40.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: _arrowSlot,
          child: onPrevious == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  tooltip: 'Previous month',
                  visualDensity: VisualDensity.compact,
                  onPressed: onPrevious,
                ),
        ),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        SizedBox(
          width: _arrowSlot,
          child: onNext == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  tooltip: 'Next month',
                  visualDensity: VisualDensity.compact,
                  onPressed: onNext,
                ),
        ),
      ],
    );
  }
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
