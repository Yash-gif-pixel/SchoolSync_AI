import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';
import 'auth_controller.dart';
import 'config.dart';

class Student {
  const Student({
    required this.id,
    required this.name,
    this.rollNo,
    this.className,
    this.grade,
    this.section,
    this.guardianName,
    this.guardianPhone,
    this.photoUrl,
  });

  final String id;
  final String name;
  final int? rollNo;
  final String? className;
  final int? grade;
  final String? section;
  final String? guardianName;
  final String? guardianPhone;

  /// A signed, short-lived URL, or null when no photo has been uploaded.
  final String? photoUrl;

  /// Grapheme-aware, so an initial is never half a Devanagari cluster.
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  factory Student.fromJson(Map<String, dynamic> j) => Student(
        id: j['id'] as String,
        name: (j['full_name'] as String?) ?? 'Unnamed',
        rollNo: (j['roll_no'] as num?)?.toInt(),
        className: j['class_name'] as String?,
        grade: (j['grade'] as num?)?.toInt(),
        section: j['section'] as String?,
        guardianName: j['guardian_name'] as String?,
        guardianPhone: j['guardian_phone'] as String?,
        photoUrl: j['photo_url'] as String?,
      );
}

class SchoolClass {
  const SchoolClass({
    required this.id,
    required this.name,
    required this.grade,
    required this.section,
  });

  final String id;
  final String name;
  final int grade;
  final String section;

  factory SchoolClass.fromJson(Map<String, dynamic> j) => SchoolClass(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '?',
        grade: (j['grade'] as num?)?.toInt() ?? 0,
        section: (j['section'] as String?) ?? '',
      );
}

class Roll {
  const Roll({required this.classes, required this.students});
  final List<SchoolClass> classes;
  final List<Student> students;

  /// Students grouped by class name, in roll order — how a register reads.
  Map<String, List<Student>> get byClass {
    final out = <String, List<Student>>{};
    for (final s in students) {
      out.putIfAbsent(s.className ?? 'Unassigned', () => []).add(s);
    }
    return out;
  }

  factory Roll.fromJson(Map<String, dynamic> j) => Roll(
        classes: ((j['classes'] as List?) ?? const [])
            .map((e) => SchoolClass.fromJson(e as Map<String, dynamic>))
            .toList(),
        students: ((j['students'] as List?) ?? const [])
            .map((e) => Student.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class StaffMember {
  const StaffMember({
    required this.id,
    required this.name,
    required this.role,
    required this.isApprover,
    required this.isVicePrincipal,
    required this.isPrincipal,
    this.department,
    this.departmentId,
    this.employeeCode,
  });

  final String id;
  final String name;
  final String role;
  final bool isApprover;
  final bool isVicePrincipal;
  final bool isPrincipal;
  final String? department;
  final String? departmentId;
  final String? employeeCode;

  bool get isAdmin => role == 'admin';

  /// The most senior title they hold, for a one-line label.
  String? get title {
    if (isPrincipal) return 'Principal';
    if (isVicePrincipal) return 'Vice Principal';
    if (isAdmin) return 'Administrator';
    if (isApprover) return 'Head of Department';
    return null;
  }

  /// Administration is not a teaching department, but everyone has to appear
  /// somewhere or the totals stop adding up.
  String get group => department ?? (isAdmin ? 'Administration' : 'Unassigned');

  String get subtitle => department ?? (isAdmin ? 'Administration' : '—');

  factory StaffMember.fromJson(Map<String, dynamic> j) => StaffMember(
        id: j['id'] as String,
        name: (j['full_name'] as String?) ?? 'Unknown',
        role: (j['role'] as String?) ?? 'teacher',
        department: j['department'] as String?,
        departmentId: j['department_id'] as String?,
        employeeCode: j['employee_code'] as String?,
        isApprover: (j['is_approver'] ?? false) as bool,
        isVicePrincipal: (j['is_vice_principal'] ?? false) as bool,
        isPrincipal: (j['is_principal'] ?? false) as bool,
      );
}

class DirectoryRepository {
  const DirectoryRepository(this._api);
  final ApiClient _api;

  Future<Roll> students() async =>
      Roll.fromJson(await _api.get('/directory/students'));

  /// Appoint or stand down. `role` is principal, vice_principal or hod.
  /// Returns whoever was replaced, so the UI can say so.
  Future<List<String>> appoint({
    required String profileId,
    required String role,
    required bool appointed,
  }) async {
    final res = await _api.post('/directory/staff/$profileId/appoint', {
      'role': role,
      'appointed': appointed,
    });
    return ((res['replaced'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  Future<List<StaffMember>> staff() async {
    final rows = await _api.getList('/directory/staff');
    return rows
        .map((e) => StaffMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------- photographs
  /// Upload a portrait. The server squares it, turns it upright and strips
  /// the EXIF — including, on a phone photo, where it was taken.
  ///
  /// Multipart, so it does not go through ApiClient, which speaks JSON.
  Future<String?> setStudentPhoto({
    required String studentId,
    required String filename,
    required List<int> bytes,
    required String mimeType,
  }) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final parts = mimeType.split('/');

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConfig.apiBaseUrl}/directory/students/$studentId/photo'),
    )
      ..headers.addAll({if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: parts.length == 2 ? MediaType(parts[0], parts[1]) : null,
      ));

    final res = await http.Response.fromStream(
      await req.send().timeout(const Duration(seconds: 90)),
    );
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['photo_url']
        as String?;
  }

  Future<void> clearStudentPhoto(String studentId) =>
      _api.delete('/directory/students/$studentId/photo');
}

final directoryRepositoryProvider = Provider<DirectoryRepository>(
  (ref) => DirectoryRepository(ref.read(apiClientProvider)),
);

final rollProvider = FutureProvider<Roll>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(directoryRepositoryProvider).students();
});

final staffProvider = FutureProvider<List<StaffMember>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(directoryRepositoryProvider).staff();
});
