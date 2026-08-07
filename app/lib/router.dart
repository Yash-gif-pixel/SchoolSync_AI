import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth_controller.dart';
import 'models/profile.dart';
import 'screens/action_board_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/documents_screen.dart';
import 'screens/forecast_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/teacher_portal.dart';
import 'screens/templates_screen.dart';
import 'screens/timetable_screen.dart';

/// Bridges Riverpod state changes into something GoRouter will listen to.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/admin-dashboard', builder: (_, _) => const AdminDashboard()),
      GoRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
      GoRoute(path: '/templates', builder: (_, _) => const TemplatesScreen()),
      GoRoute(path: '/timetable', builder: (_, _) => const TimetableScreen()),
      GoRoute(path: '/action-board', builder: (_, _) => const ActionBoardScreen()),
      GoRoute(path: '/forecast', builder: (_, _) => const ForecastScreen()),
      GoRoute(path: '/teacher-portal', builder: (_, _) => const TeacherPortal()),
    ],
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;

      // Still resolving the session or fetching the profile — hold on splash.
      if (!auth.resolved) return loc == '/' ? null : '/';

      if (!auth.signedIn) {
        return loc == '/login' ? null : '/login';
      }

      // NOTE: this is navigation, not security. RLS in db/002_rls.sql is what
      // actually stops a teacher reading admin data.
      final home = auth.profile!.role == UserRole.admin
          ? '/admin-dashboard'
          : '/teacher-portal';

      if (loc == '/' || loc == '/login') return home;

      const adminOnly = {
        '/admin-dashboard', '/documents', '/templates', '/timetable',
        '/action-board', '/forecast',
      };
      final wrongDoor = (adminOnly.contains(loc) && !auth.profile!.isAdmin) ||
          (loc == '/teacher-portal' && auth.profile!.isAdmin);
      return wrongDoor ? home : null;
    },
  );
});
