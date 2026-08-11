import 'package:flutter/material.dart';

import '../core/seating_repository.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

/// One room's seating chart.
///
/// Public and self-contained rather than private to the seating screen, so it
/// can be rendered in the layout tests without standing up the whole app
/// shell. The seat grid is a Row inside a horizontal scroll view, which is the
/// exact shape that once rendered a blank timetable in release, so it is worth
/// being able to test cheaply.
class SeatingRoomGrid extends StatelessWidget {
  const SeatingRoomGrid({super.key, required this.room});

  final RoomPlan room;

  /// Stable colour per class within this room, so 1A is the same shade in
  /// every seat. Colour is an identifier here, not a judgement — hence
  /// AppColors.accents rather than the semantic palette.
  Color _colourFor(String? className) {
    if (className == null) return AppColors.textTertiary;
    final i = room.classes.indexOf(className);
    if (i < 0) return AppColors.textTertiary;
    return AppColors.accents[i % AppColors.accents.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grid = room.grid;

    return SectionCard(
      title: room.roomName,
      subtitle: [
        if (room.block != null) 'Block ${room.block}',
        if (room.floorLabel.isNotEmpty) room.floorLabel,
        '${room.seats.length} students',
      ].join(' · '),
      icon: Icons.meeting_room_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            children: [
              for (final c in room.classes)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _colourFor(c),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(c, style: theme.textTheme.bodySmall),
                ]),
            ],
          ),
          const SizedBox(height: AppSpace.md),

          // Ten columns do not fit a phone. Scrolling sideways is correct;
          // squeezing the seats until the roll numbers vanish is not.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var r = 1; r <= room.rows; r++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var c = 1; c <= room.cols; c++)
                          _SeatCell(
                            seat: grid[(r, c)],
                            colour: _colourFor(grid[(r, c)]?.className),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpace.xs),
                Text('Front of room',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatCell extends StatelessWidget {
  const _SeatCell({required this.seat, required this.colour});

  final SeatEntry? seat;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    if (seat == null) {
      return Container(
        width: 62,
        height: 44,
        margin: const EdgeInsets.only(right: AppSpace.xs),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
      );
    }

    return Tooltip(
      message: '${seat!.studentName ?? '?'}\n'
          '${seat!.className ?? ''} · Roll ${seat!.rollNo ?? '—'}',
      child: Container(
        width: 62,
        height: 44,
        margin: const EdgeInsets.only(right: AppSpace.xs),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: colour.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seat!.className ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: colour),
            ),
            Text(
              '${seat!.rollNo ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
