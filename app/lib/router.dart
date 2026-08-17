import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth_controller.dart';
import 'core/templates_repository.dart';
import 'models/profile.dart';
import 'screens/action_board_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/attendance_screen.dart';
import 'screens/demo_setup_screen.dart';
import 'screens/document_review_screen.dart';
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
import 'screens/template_editor_screen.dart';
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

// Section roots. Everything beneath one inherits its guard — `/documents/<id>`
// is as much an admin screen as `/documents` is, and listing only the roots
// (as this used to) let a detail URL be typed in past the check.
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

/// Is this location inside one of these sections?
bool _within(Set<String> sections, String location) =>
    sections.any((s) => location == s || location.startsWith('$s/'));

/// Where a request for [location] should actually go, or null to allow it.
///
/// Pulled out of the router as a plain function so the rules can be tested
/// without a widget tree, a Supabase session or a network stack. Every screen
/// in this app is reachable by typing its URL, which makes these rules the
/// thing most worth having tests for.
///
/// NOTE: this is navigation, not security. RLS in `db/002_rls.sql` and the
/// `Depends(require_admin)` on each route are what actually stop a teacher
/// reading admin data; this only stops them landing on a page built for
/// somebody else.
String? resolveRedirect({
  required String location,
  required bool resolved,
  required bool signedIn,
  required bool isAdmin,
}) {
  // The setup preview is shown to people who have no account yet — that is
  // the whole point of it — so it must not be bounced to /login.
  if (location == '/demo-setup' && !signedIn) return null;

  // Still resolving the session or fetching the profile — hold on splash.
  if (!resolved) return location == '/' ? null : '/';

  if (!signedIn) return location == '/login' ? null : '/login';

  final home = isAdmin ? '/admin-dashboard' : '/teacher-portal';
  if (location == '/' || location == '/login') return home;

  final wrongDoor = (_within(_adminOnly, location) && !isAdmin) ||
      (_within(_teacherOnly, location) && isAdmin);
  return wrongDoor ? home : null;
}

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

      // Detail screens get real URLs of their own. Pushed imperatively they
      // used to have none, so on the web a refresh or a browser Back landed
      // the reviewer on the parent list and lost the form they were halfway
      // through checking.
      GoRoute(
        path: '/documents/:id',
        builder: (_, state) =>
            DocumentReviewRoute(documentId: state.pathParameters['id']!),
      ),

      GoRoute(path: '/templates', builder: (_, _) => const TemplatesScreen()),
      GoRoute(
        path: '/templates/new',
        // A freshly discovered draft only exists in memory, so it travels in
        // `extra` and does not survive a refresh — nothing in a URL could
        // rebuild it. Refreshing therefore opens an empty editor rather than
        // throwing, and the scan can be repeated.
        builder: (_, state) =>
            TemplateEditorScreen(proposal: state.extra as TemplateProposal?),
      ),
      GoRoute(
        path: '/templates/:id/edit',
        builder: (_, state) =>
            TemplateEditorRoute(templateId: state.pathParameters['id']!),
      ),

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

      // Deliberately in neither guard list. A teacher opens it for their own
      // classes and for cover they are confirmed on; an admin can open any
      // register. Which of those applies is decided by the API — see
      // `_may_mark` in api/app/routers/attendance.py — and it returns 403
      // rather than trusting the client. The names in the query string are
      // decoration for the title bar; the two path segments are what load it.
      GoRoute(
        path: '/attendance/:classId/:slotId',
        builder: (_, state) => AttendanceScreen(
          classId: state.pathParameters['classId']!,
          slotId: state.pathParameters['slotId']!,
          className: state.uri.queryParameters['class'],
          subjectName: state.uri.queryParameters['subject'],
        ),
      ),
    ],
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      return resolveRedirect(
        location: state.matchedLocation,
        resolved: auth.resolved,
        signedIn: auth.signedIn,
        isAdmin: auth.profile?.role == UserRole.admin,
      );
    },
  );
});
