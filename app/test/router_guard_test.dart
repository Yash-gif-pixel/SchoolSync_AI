import 'package:flutter_test/flutter_test.dart';
import 'package:smart_school/router.dart';

/// Which door each URL leads to.
///
/// Worth testing on its own because every screen in this app is now reachable
/// by typing its address, including the detail screens that used to be pushed
/// imperatively and had no address at all. The rule that covers them —
/// "a section's guard covers everything beneath it" — is exactly the sort of
/// thing that silently stops being true.

String? forTeacher(String location) => resolveRedirect(
      location: location, resolved: true, signedIn: true, isAdmin: false);

String? forAdmin(String location) => resolveRedirect(
      location: location, resolved: true, signedIn: true, isAdmin: true);

void main() {
  group('before anyone is signed in', () {
    test('an unresolved session waits on the splash screen', () {
      expect(
        resolveRedirect(
            location: '/documents',
            resolved: false,
            signedIn: false,
            isAdmin: false),
        '/',
      );
    });

    test('the splash screen itself is allowed to stay there', () {
      expect(
        resolveRedirect(
            location: '/', resolved: false, signedIn: false, isAdmin: false),
        isNull,
      );
    });

    test('a signed-out visitor is sent to sign in', () {
      expect(
        resolveRedirect(
            location: '/admin-dashboard',
            resolved: true,
            signedIn: false,
            isAdmin: false),
        '/login',
      );
    });

    test('the setup preview is reachable without an account', () {
      // It exists for people who have none, so bouncing it to /login would
      // defeat the point of it.
      expect(
        resolveRedirect(
            location: '/demo-setup',
            resolved: true,
            signedIn: false,
            isAdmin: false),
        isNull,
      );
    });
  });

  group('landing', () {
    test('an admin lands on the admin dashboard', () {
      expect(forAdmin('/'), '/admin-dashboard');
      expect(forAdmin('/login'), '/admin-dashboard');
    });

    test('a teacher lands on the teacher portal', () {
      expect(forTeacher('/'), '/teacher-portal');
      expect(forTeacher('/login'), '/teacher-portal');
    });
  });

  group('section roots', () {
    for (final path in [
      '/admin-dashboard', '/documents', '/templates', '/timetable',
      '/action-board', '/forecast', '/seating', '/events', '/students',
      '/staff',
    ]) {
      test('$path is admin only', () {
        expect(forAdmin(path), isNull);
        expect(forTeacher(path), '/teacher-portal');
      });
    }

    for (final path in ['/teacher-portal', '/my-timetable', '/my-leave']) {
      test('$path is for teachers', () {
        expect(forTeacher(path), isNull);
        expect(forAdmin(path), '/admin-dashboard');
      });
    }
  });

  group('a guard covers everything beneath it', () {
    // The bug this pins down: matching the guard list exactly meant only the
    // section roots were checked, so a detail URL typed into the address bar
    // walked straight past it.
    for (final path in [
      '/documents/abc-123',
      '/templates/abc-123/edit',
      '/templates/new',
    ]) {
      test('$path is refused to a teacher', () {
        expect(forTeacher(path), '/teacher-portal');
        expect(forAdmin(path), isNull);
      });
    }
  });

  group('a longer path is not a different section', () {
    test('a section name is matched on the segment, not the prefix', () {
      // '/staffroom' is not inside '/staff', and must not inherit its guard.
      expect(forTeacher('/staffroom'), isNull);
      expect(forTeacher('/documents-archive'), isNull);
    });
  });

  group('attendance belongs to both', () {
    // A teacher opens it for their own classes and for cover they are
    // confirmed on; an admin can open any register. Which of those applies is
    // the API's decision, not the router's.
    const register = '/attendance/class-1/slot-3';

    test('a teacher may open a register', () {
      expect(forTeacher(register), isNull);
    });

    test('so may an admin', () {
      expect(forAdmin(register), isNull);
    });
  });

  test('an unknown path is left to the error page, not redirected', () {
    expect(forTeacher('/nowhere'), isNull);
    expect(forAdmin('/nowhere'), isNull);
  });
}
