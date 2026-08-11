import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth_controller.dart';

/// One day of one exam: a date, a paper, and the grades writing it.
class Sitting {
  const Sitting({
    required this.id,
    required this.sitsOn,
    required this.grades,
    this.paper,
    this.planStats,
  });

  final String id;
  final DateTime sitsOn;
  final List<int> grades;
  final String? paper;
  final Map<String, dynamic>? planStats;

  bool get hasPlan => planStats != null;

  String get gradeLabel => grades.isEmpty
      ? 'No grades'
      : 'Grade${grades.length > 1 ? 's' : ''} ${grades.join(', ')}';

  factory Sitting.fromJson(Map<String, dynamic> j) => Sitting(
        id: j['id'] as String,
        sitsOn: DateTime.parse(j['sits_on'] as String),
        grades: ((j['grades'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        paper: j['paper'] as String?,
        planStats: (j['plan'] as Map<String, dynamic>?)?['stats']
            as Map<String, dynamic>?,
      );
}

/// An exam season: a roster of grades and a calendar of sittings.
class Exam {
  const Exam({
    required this.id,
    required this.name,
    required this.grades,
    required this.sittings,
    this.notes,
  });

  final String id;
  final String name;
  final List<int> grades;
  final List<Sitting> sittings;
  final String? notes;

  String get gradeLabel {
    if (grades.isEmpty) return 'No grades selected';
    if (grades.length == 1) return 'Grade ${grades.first}';
    final all = grades.map((g) => '$g').toList();
    return 'Grades ${all.sublist(0, all.length - 1).join(', ')} '
        'and ${all.last}';
  }

  DateTime? get firstDay =>
      sittings.isEmpty ? null : sittings.map((s) => s.sitsOn).reduce(
          (a, b) => a.isBefore(b) ? a : b);

  DateTime? get lastDay =>
      sittings.isEmpty ? null : sittings.map((s) => s.sitsOn).reduce(
          (a, b) => a.isAfter(b) ? a : b);

  int get plannedDays => sittings.where((s) => s.hasPlan).length;

  factory Exam.fromJson(Map<String, dynamic> j) => Exam(
        id: j['id'] as String,
        name: j['name'] as String,
        notes: j['notes'] as String?,
        grades: ((j['grades'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        sittings: ((j['sittings'] as List?) ?? const [])
            .map((e) => Sitting.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class SeatEntry {
  const SeatEntry({
    required this.row,
    required this.col,
    this.studentName,
    this.rollNo,
    this.className,
  });

  final int row;
  final int col;
  final String? studentName;
  final int? rollNo;
  final String? className;

  factory SeatEntry.fromJson(Map<String, dynamic> j) => SeatEntry(
        row: (j['seat_row'] as num).toInt(),
        col: (j['seat_col'] as num).toInt(),
        studentName: j['student_name'] as String?,
        rollNo: (j['roll_no'] as num?)?.toInt(),
        className: j['class_name'] as String?,
      );
}

class RoomPlan {
  const RoomPlan({
    required this.roomId,
    required this.roomName,
    required this.rows,
    required this.cols,
    required this.classes,
    required this.seats,
    this.block,
    this.floorNo,
  });

  final String roomId;
  final String roomName;
  final int rows;
  final int cols;
  final List<String> classes;
  final List<SeatEntry> seats;
  final String? block;
  final int? floorNo;

  String get floorLabel => switch (floorNo) {
        0 => 'Ground floor',
        1 => 'First floor',
        2 => 'Second floor',
        final n? => 'Floor $n',
        _ => '',
      };

  /// Seats indexed by (row, col) so the grid can look one up directly instead
  /// of scanning the list for every cell it draws.
  Map<(int, int), SeatEntry> get grid =>
      {for (final s in seats) (s.row, s.col): s};

  factory RoomPlan.fromJson(Map<String, dynamic> j) => RoomPlan(
        roomId: j['room_id'] as String,
        roomName: (j['room_name'] as String?) ?? '—',
        rows: (j['seat_rows'] as num?)?.toInt() ?? 0,
        cols: (j['seat_cols'] as num?)?.toInt() ?? 0,
        block: j['block'] as String?,
        floorNo: (j['floor_no'] as num?)?.toInt(),
        classes: ((j['classes'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        seats: ((j['seats'] as List?) ?? const [])
            .map((e) => SeatEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ExamDiagnostic {
  const ExamDiagnostic({
    required this.severity,
    required this.message,
    this.detail,
  });

  final String severity;
  final String message;
  final String? detail;

  factory ExamDiagnostic.fromJson(Map<String, dynamic> j) => ExamDiagnostic(
        severity: (j['severity'] as String?) ?? 'info',
        message: (j['message'] as String?) ?? '',
        detail: j['detail'] as String?,
      );
}

List<ExamDiagnostic> _diags(dynamic v) => ((v as List?) ?? const [])
    .map((e) => ExamDiagnostic.fromJson(e as Map<String, dynamic>))
    .toList();

class Schedule {
  const Schedule({required this.exam, required this.diagnostics});
  final Exam exam;
  final List<ExamDiagnostic> diagnostics;

  factory Schedule.fromJson(Map<String, dynamic> j) {
    final exam = Map<String, dynamic>.from(j['exam'] as Map);
    exam['sittings'] = j['sittings'];
    return Schedule(
      exam: Exam.fromJson(exam),
      diagnostics: _diags(j['diagnostics']),
    );
  }
}

class SeatingPlan {
  const SeatingPlan({
    required this.rooms,
    required this.stats,
    required this.diagnostics,
  });

  final List<RoomPlan> rooms;
  final Map<String, dynamic> stats;
  final List<ExamDiagnostic> diagnostics;

  bool get isEmpty => rooms.isEmpty;

  /// GET returns the stored plan; POST returns the freshly generated one. The
  /// two payloads differ enough to be worth two constructors.
  factory SeatingPlan.stored(Map<String, dynamic> j) {
    final plan = j['plan'] as Map<String, dynamic>?;
    return SeatingPlan(
      rooms: ((j['rooms'] as List?) ?? const [])
          .map((e) => RoomPlan.fromJson(e as Map<String, dynamic>))
          .toList(),
      stats: (plan?['stats'] as Map<String, dynamic>?) ?? const {},
      diagnostics: _diags(plan?['diagnostics']),
    );
  }

  factory SeatingPlan.generated(Map<String, dynamic> j) => SeatingPlan(
        rooms: const [],
        stats: (j['stats'] as Map<String, dynamic>?) ?? const {},
        diagnostics: _diags(j['diagnostics']),
      );
}

class SeatingRepository {
  const SeatingRepository(this._api);
  final ApiClient _api;

  static String _day(DateTime d) => d.toIso8601String().split('T').first;

  Future<List<Exam>> listExams() async {
    final rows = await _api.getList('/exams');
    return rows.map((e) => Exam.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Exam> createExam({
    required String name,
    required List<int> grades,
    String? notes,
  }) async =>
      Exam.fromJson(await _api.post('/exams', {
        'name': name,
        'grades': grades,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }));

  Future<void> deleteExam(String id) => _api.delete('/exams/$id');

  Future<Schedule> schedule(String examId) async =>
      Schedule.fromJson(await _api.get('/exams/$examId/schedule'));

  Future<void> addSitting({
    required String examId,
    required DateTime sitsOn,
    required List<int> grades,
    String? paper,
  }) =>
      _api.post('/exams/$examId/sittings', {
        'sits_on': _day(sitsOn),
        'grades': grades,
        if (paper != null && paper.isNotEmpty) 'paper': paper,
      });

  Future<void> deleteSitting(String id) => _api.delete('/sittings/$id');

  Future<SeatingPlan> generate(String sittingId) async =>
      SeatingPlan.generated(await _api.post('/sittings/$sittingId/seating'));

  Future<SeatingPlan> plan(String sittingId) async =>
      SeatingPlan.stored(await _api.get('/sittings/$sittingId/seating'));
}

final seatingRepositoryProvider = Provider<SeatingRepository>(
  (ref) => SeatingRepository(ref.read(apiClientProvider)),
);

final examsProvider = FutureProvider<List<Exam>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(seatingRepositoryProvider).listExams();
});

final scheduleProvider =
    FutureProvider.family<Schedule, String>((ref, examId) async {
  ref.watch(currentUserIdProvider);
  return ref.read(seatingRepositoryProvider).schedule(examId);
});

final seatingPlanProvider =
    FutureProvider.family<SeatingPlan, String>((ref, sittingId) async {
  ref.watch(currentUserIdProvider);
  return ref.read(seatingRepositoryProvider).plan(sittingId);
});
