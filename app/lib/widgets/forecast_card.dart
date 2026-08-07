import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/forecast_repository.dart';

/// Admin dashboard summary of predicted staffing risk.
class ForecastSummaryCard extends ConsumerWidget {
  const ForecastSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forecast = ref.watch(staffingForecastProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/forecast'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.insights_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('Staffing forecast', style: theme.textTheme.titleMedium),
                const Spacer(),
                const Icon(Icons.chevron_right),
              ]),
              const SizedBox(height: 6),
              Text(
                'Where the school is likely to run short over the next three '
                'weeks, and why.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              forecast.when(
                loading: () => const SizedBox(
                  height: 22, width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Text('Forecast unavailable',
                    style: TextStyle(color: theme.colorScheme.error)),
                data: (f) {
                  if (f.cards.isEmpty) {
                    return Row(children: [
                      Icon(Icons.check_circle_outline,
                          size: 16, color: Colors.green.shade600),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('No staffing risk on current rates.'),
                      ),
                    ]);
                  }
                  final top = f.cards.first;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        _Pill(
                          value: '${f.criticalCount}',
                          label: 'critical',
                          colour: f.criticalCount > 0
                              ? theme.colorScheme.error
                              : theme.colorScheme.outline,
                        ),
                        _Pill(
                          value: '${f.warningCount}',
                          label: 'to watch',
                          colour: const Color(0xFFB26A00),
                        ),
                        _Pill(
                          value: '${(f.overallRate * 100).toStringAsFixed(1)}%',
                          label: 'daily absence rate',
                          colour: theme.colorScheme.primary,
                        ),
                      ]),
                      const SizedBox(height: 14),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(
                          top.isCritical
                              ? Icons.error
                              : Icons.warning_amber_rounded,
                          size: 16,
                          color: top.isCritical
                              ? theme.colorScheme.error
                              : const Color(0xFFB26A00),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(top.headline,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.value, required this.label, required this.colour});
  final String value;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour.withValues(alpha: 0.30)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600, color: colour)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
