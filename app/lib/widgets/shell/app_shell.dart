/// The frame every signed-in screen sits inside: a navigation rail on the
/// left, a header across the top, and the page below it.
///
/// Adapted from the MIT-licensed Flutter Dashboard Template (© 2023 Hany
/// Sameh). Its rail is decorative — a fixed list of icons that do nothing.
/// This one is the actual router, and its items depend on who is signed in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_controller.dart';
import '../../core/operations_repository.dart';
import '../../models/profile.dart';
import '../../theme/app_theme.dart';

class NavItem {
  const NavItem(this.route, this.label, this.icon, {this.badge});
  final String route;
  final String label;
  final IconData icon;

  /// Reads a live count so the rail itself can say something needs doing.
  final int Function(WidgetRef ref)? badge;
}

final _adminNav = <NavItem>[
  const NavItem('/admin-dashboard', 'Dashboard', Icons.space_dashboard_outlined),
  NavItem(
    '/action-board', 'Action Board', Icons.notifications_none_rounded,
    badge: (ref) =>
        ref.watch(actionBoardProvider).whenOrNull(data: (b) => b.needsAction) ?? 0,
  ),
  const NavItem('/documents', 'Documents', Icons.document_scanner_outlined),
  const NavItem('/timetable', 'Timetable', Icons.grid_view_rounded),
  const NavItem('/seating', 'Exam seating', Icons.event_seat_outlined),
  const NavItem('/events', 'Events', Icons.celebration_outlined),
  const NavItem('/forecast', 'Forecast', Icons.insights_outlined),
  const NavItem('/templates', 'Form templates', Icons.description_outlined),
];

final _teacherNav = <NavItem>[
  const NavItem('/teacher-portal', 'Today', Icons.how_to_reg_outlined),
  const NavItem('/my-timetable', 'My timetable', Icons.calendar_month_outlined),
  const NavItem('/my-leave', 'Leave', Icons.event_busy_outlined),
];

/// Rail collapses to icons below this, and disappears entirely on mobile.
const _kWideBreakpoint = 1100.0;
const _kRailBreakpoint = 760.0;

class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final Widget child;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider).profile;
    final items = (profile?.role == UserRole.admin) ? _adminNav : _teacherNav;
    final width = MediaQuery.sizeOf(context).width;
    final expanded = width >= _kWideBreakpoint;
    final showRail = width >= _kRailBreakpoint;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      drawer: showRail
          ? null
          : Drawer(
              backgroundColor: AppColors.surface,
              child: SafeArea(
                child: _NavList(items: items, expanded: true, onTap: (r) {
                  Navigator.of(context).pop();
                  context.go(r);
                }),
              ),
            ),
      body: Row(children: [
        if (showRail) _Rail(items: items, expanded: expanded),
        Expanded(
          child: Column(children: [
            _Header(
              title: title,
              subtitle: subtitle,
              actions: actions,
              showMenu: !showRail,
            ),
            const Divider(height: 1),
            Expanded(child: child),
          ]),
        ),
      ]),
    );
  }
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.items, required this.expanded});
  final List<NavItem> items;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: expanded ? 232 : 76,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(children: [
          _Brand(expanded: expanded),
          const SizedBox(height: AppSpace.sm),
          Expanded(
            child: _NavList(
              items: items,
              expanded: expanded,
              onTap: (r) => context.go(r),
            ),
          ),
          const Divider(height: 1),
          _SignOut(expanded: expanded),
          const SizedBox(height: AppSpace.sm),
        ]),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.lg, AppSpace.xl, AppSpace.lg, AppSpace.lg),
      child: Row(
        mainAxisAlignment:
            expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.brand, AppColors.brandDark],
              ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.school_rounded, color: Colors.white, size: 19),
          ),
          if (expanded) ...[
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SchoolSync',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2)),
                  Text('AI operations',
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NavList extends ConsumerWidget {
  const _NavList({
    required this.items,
    required this.expanded,
    required this.onTap,
  });

  final List<NavItem> items;
  final bool expanded;
  final void Function(String route) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      children: [
        for (final item in items)
          _NavTile(
            item: item,
            selected: location == item.route,
            expanded: expanded,
            badge: item.badge?.call(ref) ?? 0,
            onTap: () => onTap(item.route),
          ),
      ],
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.expanded,
    required this.badge,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final bool expanded;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.brand : AppColors.textSecondary;

    final content = Row(
      mainAxisAlignment:
          expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
      children: [
        Icon(item.icon, size: 20, color: fg),
        if (expanded) ...[
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? AppColors.brand : AppColors.textPrimary,
              ),
            ),
          ),
        ],
        if (badge > 0)
          Container(
            margin: EdgeInsets.only(left: expanded ? AppSpace.sm : 0),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('$badge',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700)),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? AppColors.brandTint : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Tooltip(
            message: expanded ? '' : item.label,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: expanded ? AppSpace.md : AppSpace.sm,
                  vertical: 11),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _SignOut extends ConsumerWidget {
  const _SignOut({required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.md, AppSpace.md, AppSpace.md, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          onTap: () => ref.read(authControllerProvider.notifier).signOut(),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: expanded ? AppSpace.md : AppSpace.sm, vertical: 11),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                const Icon(Icons.logout_rounded,
                    size: 19, color: AppColors.textSecondary),
                if (expanded) ...[
                  const SizedBox(width: AppSpace.md),
                  const Text('Sign out',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.showMenu,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool showMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(authControllerProvider).profile;

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, AppSpace.lg, AppSpace.xl, AppSpace.lg),
      child: Row(children: [
        if (showMenu)
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        ...actions,
        if (profile != null) ...[
          const SizedBox(width: AppSpace.md),
          _UserMenu(profile: profile, role: _roleLabel(profile)),
        ],
      ]),
    );
  }

  static String _roleLabel(Profile p) {
    if (p.isAdmin) return 'Administrator';
    // Vice Principal first: it outranks the department they also teach in.
    return [
      if (p.isPrincipal) 'Principal',
      if (p.isVicePrincipal) 'Vice Principal',
      ?p.departmentName,
      if (p.isApprover) 'HOD',
    ].join(' · ');
  }
}

/// Who is signed in, shown in the header.
///
/// Identity only — signing out lives at the foot of the rail, and having it in
/// two places invited the question of whether they did the same thing. There is
/// nothing else to put in a menu here, so this is a label rather than a button.
class _UserMenu extends ConsumerWidget {
  const _UserMenu({required this.profile, required this.role});

  final Profile profile;
  final String role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = profile.fullName;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final email = ref.watch(authControllerProvider).session?.user.email;
    final showName = MediaQuery.sizeOf(context).width >= 900;

    // The name is elided at narrow widths and hidden below 900px, so the full
    // identity has to stay reachable somehow.
    return Tooltip(
      message: [name, ?email, if (role.isNotEmpty) role].join('\n'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.brandTint,
              shape: BoxShape.circle,
            ),
            child: Text(initial,
                style: const TextStyle(
                    color: AppColors.brandDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ),
          if (showName) ...[
            const SizedBox(width: AppSpace.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  if (role.isNotEmpty)
                    Text(role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.xs),
          ],
        ]),
      ),
    );
  }
}
