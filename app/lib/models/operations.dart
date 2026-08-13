/// Attendance, leave and cover — the day-to-day running of the school.
library;

// Grapheme-aware, so an initial is never half an emoji or a split Devanagari
// cluster — Indian names routinely use combining marks.
import 'package:characters/characters.dart';

enum AttendanceStatus {
  present,
  absent,
  late;

  static AttendanceStatus parse(String? v) => switch (v) {
        'absent' => AttendanceStatus.absent,
        'late' => AttendanceStatus.late,
        _ => AttendanceStatus.present,
      };

  String get label => switch (this) {
        AttendanceStatus.present => 'Present',
        AttendanceStatus.absent => 'Absent',
        AttendanceStatus.late => 'Late',
      };
}

class RosterStudent {
  RosterStudent({
    required this.id,
    required this.fullName,
    required this.rollNo,
    required this.status,
  });

  final String id;
  final String fullName;
  final int rollNo;
  AttendanceStatus status;

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  factory RosterStudent.fromMap(Map<String, dynamic> m) => RosterStudent(
        id: m['id'] as String,
        fullName: (m['full_name'] ?? '') as String,
        rollNo: (m['roll_no'] ?? 0) as int,
        status: AttendanceStatus.parse(m['status'] as String?),
      );
}

class Roster {
  const Roster({
    required this.classId,
    required this.className,
    required this.slotId,
    required this.date,
    required this.students,
    required this.alreadyMarked,
  });

  final String classId;
  final String className;
  final String slotId;
  final String date;
  final List<RosterStudent> students;
  final bool alreadyMarked;

  factory Roster.fromMap(Map<String, dynamic> m) => Roster(
        classId: (m['class_id'] ?? '') as String,
        className: (m['class_name'] ?? '?') as String,
        slotId: (m['slot_id'] ?? '') as String,
        date: (m['date'] ?? '') as String,
        alreadyMarked: (m['already_marked'] ?? false) as bool,
        students: ((m['students'] ?? const []) as List)
            .map((s) => RosterStudent.fromMap(s as Map<String, dynamic>))
            .toList(),
      );
}

class TodayPeriod {
  const TodayPeriod({
    required this.slotId,
    required this.slotIndex,
    required this.classId,
    required this.className,
    required this.subjectName,
    required this.marked,
    this.startTime,
    this.room,
    this.coveringFor,
  });

  final String slotId;
  final int slotIndex;
  final String classId;
  final String className;
  final String subjectName;
  final bool marked;
  final String? startTime;
  final String? room;

  /// The colleague this period belongs to, when the teacher is standing in
  /// for them. Null for their own classes.
  final String? coveringFor;

  bool get isCover => coveringFor != null;

  String get time => startTime == null ? '' : startTime!.substring(0, 5);

  factory TodayPeriod.fromMap(Map<String, dynamic> m) => TodayPeriod(
        slotId: (m['slot_id'] ?? '') as String,
        slotIndex: (m['slot_index'] ?? 0) as int,
        classId: (m['class_id'] ?? '') as String,
        className: (m['class_name'] ?? '?') as String,
        subjectName: (m['subject_name'] ?? '?') as String,
        marked: (m['marked'] ?? false) as bool,
        startTime: m['start_time'] as String?,
        room: m['room'] as String?,
        coveringFor: m['covering_for'] as String?,
      );
}

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.fromDate,
    required this.toDate,
    required this.status,
    this.reason,
    this.teacherName,
    this.teacherId,
    this.departmentName,
    this.reviewerName,
  });

  final String id;
  final String fromDate;
  final String toDate;
  final String status;
  final String? reason;
  final String? teacherName;
  final String? teacherId;
  final String? departmentName;
  final String? reviewerName;

  bool get isPending => status == 'pending_incharge';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  String get statusLabel => switch (status) {
        'pending_incharge' => 'Awaiting approval',
        'approved' => 'Approved',
        'rejected' => 'Rejected',
        _ => status,
      };

  String get dateRange => fromDate == toDate ? fromDate : '$fromDate → $toDate';

  factory LeaveRequest.fromMap(Map<String, dynamic> m) {
    final t = m['teacher'] as Map<String, dynamic>?;
    final r = m['reviewer'] as Map<String, dynamic>?;
    return LeaveRequest(
      id: (m['id'] ?? '') as String,
      fromDate: (m['from_date'] ?? '') as String,
      toDate: (m['to_date'] ?? '') as String,
      status: (m['status'] ?? '') as String,
      reason: m['reason'] as String?,
      teacherId: t?['id'] as String?,
      teacherName: t?['full_name'] as String?,
      departmentName: (t?['departments'] as Map?)?['name'] as String?,
      reviewerName: r?['full_name'] as String?,
    );
  }
}

class CoverCandidate {
  const CoverCandidate({
    required this.substitutionId,
    required this.teacherName,
    required this.rank,
    required this.rationale,
    required this.status,
    this.teacherId,
    this.department,
  });

  final String substitutionId;
  final String teacherName;
  final int rank;
  final String rationale;
  final String status;
  final String? teacherId;
  final String? department;

  factory CoverCandidate.fromMap(Map<String, dynamic> m) => CoverCandidate(
        substitutionId: (m['substitution_id'] ?? '') as String,
        teacherId: m['teacher_id'] as String?,
        teacherName: (m['teacher_name'] ?? '?') as String,
        department: m['department'] as String?,
        rank: (m['rank'] ?? 99) as int,
        rationale: (m['rationale'] ?? '') as String,
        status: (m['status'] ?? 'suggested') as String,
      );
}

class CoverPeriod {
  const CoverPeriod({
    required this.date,
    required this.className,
    required this.subjectName,
    required this.slotIndex,
    required this.status,
    required this.candidates,
    this.startTime,
    this.room,
    this.confirmedTeacher,
  });

  final String date;
  final String className;
  final String subjectName;
  final int slotIndex;
  final String status;
  final List<CoverCandidate> candidates;
  final String? startTime;
  final String? room;
  final String? confirmedTeacher;

  bool get isConfirmed => status == 'confirmed';

  factory CoverPeriod.fromMap(Map<String, dynamic> m) => CoverPeriod(
        date: (m['date'] ?? '') as String,
        className: (m['class_name'] ?? '?') as String,
        subjectName: (m['subject_name'] ?? '?') as String,
        slotIndex: (m['slot_index'] ?? 0) as int,
        startTime: m['start_time'] as String?,
        room: m['room'] as String?,
        status: (m['status'] ?? 'suggested') as String,
        confirmedTeacher: m['confirmed_teacher'] as String?,
        candidates: ((m['candidates'] ?? const []) as List)
            .map((c) => CoverCandidate.fromMap(c as Map<String, dynamic>))
            .toList(),
      );
}

class CoverGroup {
  const CoverGroup({
    required this.leaveId,
    required this.absentTeacher,
    required this.fromDate,
    required this.toDate,
    required this.periods,
    required this.unconfirmed,
    this.absentDepartment,
    this.reason,
  });

  final String leaveId;
  final String absentTeacher;
  final String fromDate;
  final String toDate;
  final List<CoverPeriod> periods;
  final int unconfirmed;
  final String? absentDepartment;
  final String? reason;

  bool get allCovered => unconfirmed == 0;
  String get dateRange => fromDate == toDate ? fromDate : '$fromDate → $toDate';

  factory CoverGroup.fromMap(Map<String, dynamic> m) => CoverGroup(
        leaveId: (m['leave_id'] ?? '') as String,
        absentTeacher: (m['absent_teacher'] ?? '?') as String,
        absentDepartment: m['absent_department'] as String?,
        fromDate: (m['from_date'] ?? '') as String,
        toDate: (m['to_date'] ?? '') as String,
        reason: m['reason'] as String?,
        unconfirmed: (m['unconfirmed'] ?? 0) as int,
        periods: ((m['periods'] ?? const []) as List)
            .map((p) => CoverPeriod.fromMap(p as Map<String, dynamic>))
            .toList(),
      );
}

class ActionBoard {
  const ActionBoard({
    required this.groups,
    required this.totalPeriods,
    required this.needsAction,
  });

  final List<CoverGroup> groups;
  final int totalPeriods;
  final int needsAction;

  factory ActionBoard.fromMap(Map<String, dynamic> m) => ActionBoard(
        totalPeriods: (m['total_periods'] ?? 0) as int,
        needsAction: (m['needs_action'] ?? 0) as int,
        groups: ((m['groups'] ?? const []) as List)
            .map((g) => CoverGroup.fromMap(g as Map<String, dynamic>))
            .toList(),
      );
}
