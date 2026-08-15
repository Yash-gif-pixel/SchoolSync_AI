import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/forecast_repository.dart';
import '../models/forecast.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart' show PageBody, SlowLoader;

/// Predictive staffing: where the school is likely to run short, and why.
///
/// Every number on this page decomposes into arithmetic that can be said out
/// loud. That is the point of not using a black-box forecaster — an
/// administrator is being asked to act on this, and "the model said so" is
/// not a reason to call someone in.
class ForecastScreen extends ConsumerWidget {
  const ForecastScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forecast = ref.watch(staffingForecastProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Staffing forecast',
      subtitle: 'Where the school is likely to run short, and why',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(staffingForecastProvider),
        ),
      ],
      child: forecast.when(
        loading: () => const SlowLoader(),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('$e'.replaceFirst('Exception: ', ''),
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        ),
        data: (f) => PageBody(
          maxWidth: 1000,
          children: [
            if (!f.hasTimetable && f.note != null) ...[
              _Banner(
                colour: theme.colorScheme.error,
                icon: Icons.warning_amber_rounded,
                child: Text(f.note!),
              ),
              const SizedBox(height: 16),
            ],
            if (f.cards.isEmpty)
              _Banner(
                colour: Colors.green.shade700,
                icon: Icons.check_circle_outline,
                child: const Text(
                    'No staffing risk in the next three weeks on current rates.'),
              )
            else
              for (final c in f.cards) ...[
                _Card(card: c),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 10),
            _Chart(forecast: f),
            const SizedBox(height: 16),
            _Method(forecast: f),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.card});
  final ForecastCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour =
        card.isCritical ? theme.colorScheme.error : const Color(0xFFB26A00);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: colour, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(card.isCritical ? Icons.error : Icons.warning_amber_rounded,
              size: 18, color: colour),
          const SizedBox(width: 8),
          Text(card.isCritical ? 'CRITICAL' : 'WATCH',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colour, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (card.recurring)
            Text('every week',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          else
            Text(card.date,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 8),
        Text(card.headline,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        // The reasoning, always. This is the difference between a forecast an
        // administrator acts on and one they ignore.
        Text(card.because, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

/// Expected absences per day. Hand-drawn bars rather than a charting package —
/// it is a dozen rectangles, and the dependency would cost more than it saves.
class _Chart extends StatelessWidget {
  const _Chart({required this.forecast});
  final StaffingForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = forecast.days.take(18).toList();
    if (days.isEmpty) return const SizedBox.shrink();
    final peak = forecast.peakExpected <= 0 ? 1.0 : forecast.peakExpected;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Expected teachers away', style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text('Taller bars are higher-risk days. Amber marks a calendar event.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 18),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(d.expectedAbsences.toStringAsFixed(1),
                              style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 9,
                                  color: theme.colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 3),
                          Container(
                            height: (d.expectedAbsences / peak * 96).clamp(3.0, 96.0),
                            decoration: BoxDecoration(
                              color: d.eventTeachers > 0
                                  ? const Color(0xFFB26A00)
                                  : theme.colorScheme.primary
                                      .withValues(alpha: 0.65),
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(d.dayInitial,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(fontSize: 9)),
                          Text(d.shortDate.split(' ').first,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 8,
                                  color: theme.colorScheme.outline)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _Method extends StatelessWidget {
  const _Method({required this.forecast});
  final StaffingForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = forecast;
    final effects = f.weekdayEffects.entries.toList();

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.functions, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text('How this is worked out', style: theme.textTheme.titleMedium),
          ]),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'expected absences  =  base rate  ×  weekday effect  '
              '×  seasonal effect  ×  headcount',
              style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace', fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Measured from this school\'s own leave history — '
            '${f.observedAbsences} absences over ${f.observedDays} school days, '
            'a ${(f.overallRate * 100).toStringAsFixed(1)}% daily rate. '
            'Capacity comes from the free periods the live timetable actually '
            'leaves, and the chance of a shortage is Poisson against it.',
            style: theme.textTheme.bodySmall,
          ),
          if (effects.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Weekday effect, measured',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in effects)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: e.value > 1.1
                        ? const Color(0xFFB26A00).withValues(alpha: 0.12)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${e.key.substring(0, 3)} ×${e.value.toStringAsFixed(2)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight:
                            e.value > 1.1 ? FontWeight.w700 : FontWeight.normal,
                        color: e.value > 1.1 ? const Color(0xFF7A4A00) : null),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 14),
          Text(
            'No black-box forecaster: with 90 days of history one would be '
            'fitting noise, and an administrator cannot act on a number they '
            'cannot question.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.colour, required this.icon, required this.child});
  final Color colour;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 10),
        Expanded(child: child),
      ]),
    );
  }
}
