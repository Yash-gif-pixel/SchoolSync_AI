import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth_controller.dart';
import 'models/profile.dart';
import 'screens/action_board_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/demo_setup_screen.dart';
import 'screens/documents_screen.dart';
import 'screens/events_screen.dart';
import 'screens/forecast_screen.dart';
import 'screens/login_screen.dart';
import 'screens/my_leave_screen.dart';
import 'screens/my_timetable_screen.dart';
import 'screens/seating_screen.dart';
import 'screens/staff_screen.dart';
import 'screens/students_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/teacher_portal.dart';
import 'theme/app_theme.dart';
import 'widgets/ui/primitives.dart';
import 'screens/templates_screen.dart';
import 'screens/timetable_screen.dart';

/// Bridges Riverpod state changes into something GoRouter will listen to.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, _) => notifyListeners());
  }
}

const _adminOnly = {
  '/admin-dashboard',
  '/documents',
  '/templates',
  '/timetable',
  '/action-board',
  '/forecast',
  '/seating',
  '/events',
  '/students',
  '/staff',
};

const _teacherOnly = {
  '/teacher-portal',
  '/my-timetable',
  '/my-leave',
};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    // Without this an unknown URL renders GoRouter's raw exception text. The
    // setup preview hands out example invite links that intentionally lead
    // nowhere, so somebody pasting one is an expected path, not a crash.
    errorBuilder: (context, state) => Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: EmptyState(
              icon: Icons.link_off_rounded,
              title: 'That link does not go anywhere',
              message: 'It may have expired, or it was an example link from '
                  'the setup preview.',
              action: FilledButton(
                onPressed: () => context.go('/login'),
                child: const Text('Go to sign in'),
              ),
            ),
          ),
        ),
      ),
    ),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),

      // Reachable without an account: a preview of first-run setup that
      // writes nothing.
      GoRoute(path: '/demo-setup', builder: (_, _) => const DemoSetupScreen()),

      // Admin
      GoRoute(path: '/admin-dashboard', builder: (_, _) => const AdminDashboard()),
      GoRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
      GoRoute(path: '/templates', builder: (_, _) => const TemplatesScreen()),
      GoRoute(path: '/timetable', builder: (_, _) => const TimetableScreen()),
      GoRoute(path: '/action-board', builder: (_, _) => const ActionBoardScreen()),
      GoRoute(path: '/forecast', builder: (_, _) => const ForecastScreen()),
      GoRoute(path: '/seating', builder: (_, _) => const SeatingScreen()),
      GoRoute(path: '/events', builder: (_, _) => const EventsScreen()),
      GoRoute(path: '/students', builder: (_, _) => const StudentsScreen()),
      GoRoute(path: '/staff', builder: (_, _) => const StaffScreen()),

      // Teacher
      GoRoute(path: '/teacher-portal', builder: (_, _) => const TeacherPortal()),
      GoRoute(path: '/my-timetable', builder: (_, _) => const MyTimetableScreen()),
      GoRoute(path: '/my-leave', builder: (_, _) => const MyLeaveScreen()),
    ],
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;

      // The setup preview is shown to people who have no account yet — that
      // is the whole point of it — so it must not be bounced to /login.
      if (loc == '/demo-setup' && !auth.signedIn) return null;

      // Still resolving the session or fetching the profile — hold on splash.
      if (!auth.resolved) return loc == '/' ? null : '/';

      if (!auth.signedIn) {
        return loc == '/login' ? null : '/login';
      }

      // NOTE: this is navigation, not security. RLS in db/002_rls.sql is what
      // actually stops a teacher reading admin data.
      final isAdmin = auth.profile!.role == UserRole.admin;
      final home = isAdmin ? '/admin-dashboard' : '/teacher-portal';

      if (loc == '/' || loc == '/login') return home;

      final wrongDoor = (_adminOnly.contains(loc) && !isAdmin) ||
          (_teacherOnly.contains(loc) && isAdmin);
      return wrongDoor ? home : null;
    },
  );
});
