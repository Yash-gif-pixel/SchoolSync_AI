import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/documents_repository.dart';

/// Admin dashboard entry point into the document reader. Proactive by design:
/// it surfaces the count needing attention rather than waiting to be searched.
class DocumentQueueCard extends ConsumerWidget {
  const DocumentQueueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(documentQueueProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/documents'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.document_scanner_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('AI Document Reader', style: theme.textTheme.titleMedium),
                const Spacer(),
                const Icon(Icons.chevron_right),
              ]),
              const SizedBox(height: 6),
              Text(
                'Photograph handwritten admission forms; the AI turns them into '
                'student records.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              queue.when(
                loading: () => const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Text('Queue unavailable',
                    style: TextStyle(color: theme.colorScheme.error)),
                data: (docs) {
                  final pending = docs.where((d) =>
                      d.status == 'needs_review' || d.status == 'extracted').toList();
                  final blocked = pending.where((d) => d.errorCount > 0).length;
                  final admitted = docs.where((d) => d.isCommitted).length;

                  if (docs.isEmpty) {
                    return Text('No forms scanned yet — tap to add some.',
                        style: theme.textTheme.bodyMedium);
                  }
                  return Wrap(spacing: 10, runSpacing: 10, children: [
                    _Pill(
                      value: '${pending.length}',
                      label: 'awaiting review',
                      colour: pending.isEmpty
                          ? theme.colorScheme.outline
                          : const Color(0xFFB26A00),
                    ),
                    if (blocked > 0)
                      _Pill(
                        value: '$blocked',
                        label: 'need a fix',
                        colour: theme.colorScheme.error,
                      ),
                    _Pill(
                      value: '$admitted',
                      label: 'admitted',
                      colour: Colors.green.shade600,
                    ),
                  ]);
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600, color: colour)),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
