import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/config.dart';

/// Phase 0 gate, made visible: Flutter -> FastAPI -> Supabase, with live row
/// counts. Gets replaced by real dashboard content in later phases.
class BackendStatusCard extends ConsumerWidget {
  const BackendStatusCard({super.key});

  static const _highlight = {
    'students': 'Students',
    'profiles': 'Staff',
    'classes': 'Classes',
    'teaching_assignments': 'Assignments',
    'leave_requests': 'Leave records',
    'attendance': 'Attendance marks',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(backendHealthProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Text('Backend', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => ref.invalidate(backendHealthProvider),
              ),
            ]),
            const SizedBox(height: 4),
            Text(AppConfig.apiBaseUrl,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            health.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (e, _) => Row(children: [
                Icon(Icons.cloud_off, color: theme.colorScheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cannot reach the API. Is uvicorn running on '
                    '${AppConfig.apiBaseUrl}?\n$e',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ]),
              data: (data) {
                final counts =
                    (data['row_counts'] as Map).cast<String, dynamic>();
                final connected = data['connected'] == true;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                        connected ? Icons.check_circle : Icons.error,
                        size: 18,
                        color: connected
                            ? Colors.green.shade600
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text(connected
                          ? 'Connected — all 15 tables present'
                          : 'Schema incomplete'),
                    ]),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _highlight.entries.map((e) {
                        return Container(
                          width: 150,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${counts[e.key] ?? '—'}',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              Text(e.value,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
