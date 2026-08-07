enum UserRole {
  admin,
  teacher;

  static UserRole parse(String? v) =>
      v == 'admin' ? UserRole.admin : UserRole.teacher;
}

class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.isApprover,
    this.employeeCode,
    this.departmentId,
    this.departmentName,
  });

  final String id;
  final String fullName;
  final UserRole role;
  final bool isApprover;
  final String? employeeCode;
  final String? departmentId;
  final String? departmentName;

  bool get isAdmin => role == UserRole.admin;

  /// Expects the `departments(name)` join to be selected alongside.
  factory Profile.fromMap(Map<String, dynamic> m) {
    final dept = m['departments'];
    return Profile(
      id: m['id'] as String,
      fullName: (m['full_name'] ?? '') as String,
      role: UserRole.parse(m['role'] as String?),
      isApprover: (m['is_approver'] ?? false) as bool,
      employeeCode: m['employee_code'] as String?,
      departmentId: m['department_id'] as String?,
      departmentName: dept is Map ? dept['name'] as String? : null,
    );
  }
}
