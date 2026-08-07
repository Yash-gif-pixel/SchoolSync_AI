import 'package:flutter/material.dart';

/// Placeholder that names what each later phase will drop into this screen.
/// Delete once the real features land.
class PhaseRoadmapCard extends StatelessWidget {
  const PhaseRoadmapCard({super.key, required this.isAdmin});

  final bool isAdmin;

  static const _admin = <(String, String)>[];

  static const _teacher = <(String, String)>[];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = isAdmin ? _admin : _teacher;
    if (items.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.construction_outlined,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text('Coming next', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 14),
            ...items.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(e.$1,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color:
                                    theme.colorScheme.onSecondaryContainer)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(e.$2,
                              style: theme.textTheme.bodyMedium)),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
