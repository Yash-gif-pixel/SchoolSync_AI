import 'package:flutter_test/flutter_test.dart';
import 'package:smart_school/models/profile.dart';

void main() {
  group('UserRole.parse', () {
    test('maps admin', () => expect(UserRole.parse('admin'), UserRole.admin));
    test('maps teacher', () => expect(UserRole.parse('teacher'), UserRole.teacher));
    test('defaults unknown values to teacher — never silently to admin', () {
      expect(UserRole.parse(null), UserRole.teacher);
      expect(UserRole.parse('superuser'), UserRole.teacher);
      expect(UserRole.parse(''), UserRole.teacher);
    });
  });

  group('Profile.fromMap', () {
    test('reads a full row including the departments join', () {
      final p = Profile.fromMap({
        'id': 'uuid-1',
        'full_name': 'Isha Reddy',
        'role': 'teacher',
        'is_approver': true,
        'employee_code': 'TCH017',
        'department_id': 'dept-1',
        'departments': {'name': 'Science'},
      });

      expect(p.id, 'uuid-1');
      expect(p.fullName, 'Isha Reddy');
      expect(p.role, UserRole.teacher);
      expect(p.isApprover, isTrue);
      expect(p.employeeCode, 'TCH017');
      expect(p.departmentName, 'Science');
      expect(p.isAdmin, isFalse);
    });

    test('tolerates a missing departments join (admins have no department)', () {
      final p = Profile.fromMap({
        'id': 'uuid-2',
        'full_name': 'Principal Sharma',
        'role': 'admin',
        'is_approver': true,
        'department_id': null,
        'departments': null,
      });

      expect(p.isAdmin, isTrue);
      expect(p.departmentName, isNull);
      expect(p.departmentId, isNull);
    });

    test('defaults is_approver to false when absent', () {
      final p = Profile.fromMap({
        'id': 'uuid-3',
        'full_name': 'Rahul Nair',
        'role': 'teacher',
      });
      expect(p.isApprover, isFalse);
    });
  });
}
