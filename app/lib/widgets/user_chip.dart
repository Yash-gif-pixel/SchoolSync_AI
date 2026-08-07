import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_controller.dart';

class UserChip extends ConsumerWidget {
  const UserChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    if (profile == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PopupMenuButton<String>(
        tooltip: profile.fullName,
        onSelected: (v) {
          if (v == 'signout') {
            ref.read(authControllerProvider.notifier).signOut();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            enabled: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  [
                    profile.role.name,
                    if (profile.employeeCode != null) profile.employeeCode!,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'signout',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout, size: 20),
              title: Text('Sign out'),
            ),
          ),
        ],
        child: Row(children: [
          CircleAvatar(
            radius: 15,
            child: Text(
              profile.fullName.isEmpty ? '?' : profile.fullName[0],
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Text(profile.fullName),
          const Icon(Icons.arrow_drop_down),
        ]),
      ),
    );
  }
}
