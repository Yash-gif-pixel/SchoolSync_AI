import 'package:flutter/material.dart';

/// A pupil's face, or their initials when there isn't one.
///
/// Both cases are drawn here rather than at each call site, because the
/// fallback is not only "no photo has been uploaded". The URL is signed and
/// expires, so a register left open on a desk all morning will eventually fail
/// to load pictures it loaded fine an hour earlier. That has to degrade to
/// initials in place, not to a broken-image icon in a circle.
class StudentAvatar extends StatelessWidget {
  const StudentAvatar({
    super.key,
    required this.initials,
    this.photoUrl,
    this.radius = 19,
    this.tint,
    this.struckThrough = false,
  });

  final String initials;
  final String? photoUrl;
  final double radius;

  /// Colours the fallback. Ignored when there is a photo — a portrait tinted
  /// red for "absent" reads as something much worse than a missed register.
  final Color? tint;

  /// Absent pupils are struck out so the grid can be read at a glance.
  final bool struckThrough;

  @override
  Widget build(BuildContext context) {
    final colour = tint ?? Theme.of(context).colorScheme.primary;

    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: colour.withValues(alpha: 0.18),
      child: Text(
        initials,
        style: TextStyle(
          color: colour,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.75,
          decoration: struckThrough ? TextDecoration.lineThrough : null,
        ),
      ),
    );

    if (photoUrl == null) return fallback;

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Opacity(
          // Dimmed rather than struck through: a line drawn across a child's
          // face is not a way to say they are off school today.
          opacity: struckThrough ? 0.45 : 1,
          child: Image.network(
            photoUrl!,
            fit: BoxFit.cover,
            // Show the initials while the photo arrives, so a class of 45
            // does not flash 45 empty circles on every page load.
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : fallback,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      ),
    );
  }
}
