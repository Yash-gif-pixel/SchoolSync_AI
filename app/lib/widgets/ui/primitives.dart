/// The small set of pieces every screen is built from.
///
/// Having these in one place is what keeps eleven screens looking like one
/// product. Adapted from the MIT-licensed Flutter Dashboard Template
/// (© 2023 Hany Sameh) — see THIRD_PARTY_NOTICES.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Severity, used anywhere the UI makes a judgement.
enum Tone { neutral, brand, success, warning, danger }

extension ToneColors on Tone {
  Color get fg => switch (this) {
        Tone.neutral => AppColors.textSecondary,
        Tone.brand => AppColors.brand,
        Tone.success => AppColors.success,
        Tone.warning => AppColors.warning,
        Tone.danger => AppColors.danger,
      };

  Color get bg => switch (this) {
        Tone.neutral => AppColors.surfaceMuted,
        Tone.brand => AppColors.brandTint,
        Tone.success => AppColors.successTint,
        Tone.warning => AppColors.warningTint,
        Tone.danger => AppColors.dangerTint,
      };
}

/// The standard white panel: optional icon, title, subtitle and trailing
/// action, then whatever the screen puts inside.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.tone = Tone.brand,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpace.xl),
    this.accentBorder,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Tone tone;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  /// A left edge in this colour, for cards that carry a status.
  final Color? accentBorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final body = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[
                IconTile(icon: icon!, tone: tone, size: 36),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title!, style: theme.textTheme.titleMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              ?trailing,
              if (onTap != null && trailing == null)
                const Icon(Icons.chevron_right,
                    size: 20, color: AppColors.textTertiary),
            ]),
            const SizedBox(height: AppSpace.lg),
          ],
          child,
        ],
      ),
    );

    final interactive = onTap == null
        ? body
        : Material(
            color: Colors.transparent,
            child: InkWell(onTap: onTap, child: body),
          );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        // Uniform, always. Flutter rejects a borderRadius on a Border whose
        // sides differ in colour, so a status accent is painted as a strip
        // inside the clip rather than as a coloured left side.
        border: Border.all(color: AppColors.border),
        boxShadow: kCardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: accentBorder == null
          ? interactive
          : Stack(children: [
              interactive,
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: accentBorder!),
              ),
            ]),
    );
  }
}

/// A rounded square holding an icon on a tint of its own colour. The
/// template's signature element, and what stops a page of white cards
/// reading as a spreadsheet.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.tone = Tone.brand,
    this.size = 40,
    this.color,
  });

  final IconData icon;
  final Tone tone;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? tone.fg;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color == null ? tone.bg : c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(icon, size: size * 0.5, color: c),
    );
  }
}

/// A headline number with its label. The unit of every dashboard summary.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.tone = Tone.neutral,
    this.icon,
    this.hint,
    this.width = 168,
    this.onTap,
  });

  final String value;
  final String label;
  final Tone tone;
  final IconData? icon;
  final String? hint;
  final double width;

  /// Optional. A tile that leads somewhere gets a chevron and an ink ripple,
  /// so the ones that do not are not silently unresponsive to a click.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emphasised = tone != Tone.neutral;

    final tile = Container(
      width: width,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg, vertical: AppSpace.md),
      decoration: BoxDecoration(
        color: emphasised ? tone.bg : AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: onTap != null
              ? AppColors.borderStrong
              : emphasised
                  ? tone.fg.withValues(alpha: 0.22)
                  : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null || onTap != null) ...[
            Row(children: [
              if (icon != null)
                Icon(icon,
                    size: 16,
                    color: emphasised ? tone.fg : AppColors.textTertiary),
              const Spacer(),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    size: 16, color: AppColors.textSecondary),
            ]),
            const SizedBox(height: AppSpace.sm),
          ],
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: emphasised ? tone.fg : AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.bodySmall, maxLines: 2),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(hint!,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.textTertiary)),
          ],
        ],
      ),
    );

    if (onTap == null) return tile;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: tile,
      ),
    );
  }
}

/// A spinner that explains itself when the wait gets long.
///
/// Free-tier hosting sleeps after a period of inactivity, so the first request
/// after a quiet spell can take the best part of a minute while the container
/// boots. A bare spinner for that long reads as broken rather than slow, and
/// somebody evaluating this would reasonably conclude it had hung.
///
/// So: a plain spinner for the first few seconds, since almost every load
/// finishes inside that and a message would only flicker. After that, say what
/// is actually happening.
class SlowLoader extends StatefulWidget {
  const SlowLoader({
    super.key,
    this.padding = const EdgeInsets.symmetric(vertical: AppSpace.xl),
  });

  final EdgeInsets padding;

  /// How long a load may take before it stops being unremarkable.
  static const explainAfter = Duration(seconds: 4);

  @override
  State<SlowLoader> createState() => _SlowLoaderState();
}

class _SlowLoaderState extends State<SlowLoader> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(SlowLoader.explainAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: widget.padding,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            if (_slow) ...[
              const SizedBox(height: AppSpace.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Column(
                  children: [
                    Text(
                      'Waking the server — this can take up to a minute',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Free hosting sleeps when nobody is using it. It stays '
                      'quick once awake.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small coloured label. Says what state something is in.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.tone = Tone.neutral,
    this.icon,
  });

  final String label;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.fg.withValues(alpha: 0.22)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: tone.fg),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w600, color: tone.fg),
        ),
      ]),
    );
  }
}

/// An inline message with a reason. Used for validation and diagnostics.
class Callout extends StatelessWidget {
  const Callout({
    super.key,
    required this.message,
    this.detail,
    this.tone = Tone.warning,
    this.icon,
  });

  final String message;
  final String? detail;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: tone.fg.withValues(alpha: 0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
          icon ??
              switch (tone) {
                Tone.danger => Icons.error_outline,
                Tone.warning => Icons.warning_amber_rounded,
                Tone.success => Icons.check_circle_outline,
                _ => Icons.info_outline,
              },
          size: 17,
          color: tone.fg,
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: tone.fg, fontWeight: FontWeight.w500)),
            if (detail != null) ...[
              const SizedBox(height: 2),
              Text(detail!, style: theme.textTheme.bodySmall),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Consistent empty state, so a screen with nothing in it still looks
/// designed rather than broken.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconTile(icon: icon, tone: Tone.neutral, size: 48),
          const SizedBox(height: AppSpace.lg),
          Text(title, style: theme.textTheme.titleMedium),
          if (message != null) ...[
            const SizedBox(height: AppSpace.xs),
            SizedBox(
              width: 380,
              child: Text(message!,
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpace.lg),
            action!,
          ],
        ]),
      ),
    );
  }
}

/// Standard page padding, capped so content does not stretch to absurd widths
/// on an ultrawide monitor.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1180});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, AppSpace.xl, AppSpace.xl, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Vertical rhythm between cards.
const gap8 = SizedBox(height: AppSpace.sm);
const gap12 = SizedBox(height: AppSpace.md);
const gap16 = SizedBox(height: AppSpace.lg);
const gap24 = SizedBox(height: AppSpace.xl);
