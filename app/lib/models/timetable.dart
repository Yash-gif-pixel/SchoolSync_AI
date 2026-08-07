/// The generated timetable, as the client sees it.
library;

const dayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const dayNamesLong = [
  '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
];

class TimetableEntry {
  const TimetableEntry({
    required this.id,
    required this.dayOfWeek,
    required this.slotIndex,
    required this.className,
    required this.subjectName,
    required this.subjectCode,
    required this.teacherName,
    required this.teacherId,
    required this.classId,
    this.roomName,
    this.roomType,
    this.startTime,
    this.endTime,
    this.requiresLab = false,
  });

  final String id;
  final int dayOfWeek;
  final int slotIndex;
  final String className;
  final String subjectName;
  final String subjectCode;
  final String teacherName;
  final String teacherId;
  final String classId;
  final String? roomName;
  final String? roomType;
  final String? startTime;
  final String? endTime;
  final bool requiresLab;

  String get timeRange {
    if (startTime == null || endTime == null) return '';
    return '${startTime!.substring(0, 5)}–${endTime!.substring(0, 5)}';
  }

  factory TimetableEntry.fromMap(Map<String, dynamic> m) {
    final a = (m['teaching_assignments'] ?? const {}) as Map<String, dynamic>;
    final slot = (m['time_slots'] ?? const {}) as Map<String, dynamic>;
    final cls = (a['classes'] ?? const {}) as Map<String, dynamic>;
    final sub = (a['subjects'] ?? const {}) as Map<String, dynamic>;
    final tch = (a['profiles'] ?? const {}) as Map<String, dynamic>;
    final room = (m['rooms'] ?? const {}) as Map<String, dynamic>;

    return TimetableEntry(
      id: (m['id'] ?? '') as String,
      dayOfWeek: (slot['day_of_week'] ?? 1) as int,
      slotIndex: (slot['slot_index'] ?? 1) as int,
      startTime: slot['start_time'] as String?,
      endTime: slot['end_time'] as String?,
      className: (cls['name'] ?? '?') as String,
      classId: (cls['id'] ?? '') as String,
      subjectName: (sub['name'] ?? '?') as String,
      subjectCode: (sub['code'] ?? '') as String,
      teacherName: (tch['full_name'] ?? '?') as String,
      teacherId: (tch['id'] ?? '') as String,
      roomName: room['name'] as String?,
      roomType: room['type'] as String?,
      requiresLab: (a['requires_lab'] ?? false) as bool,
    );
  }
}

class SolverDiagnostic {
  const SolverDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.detail,
  });

  final String severity;
  final String code;
  final String message;
  final String? detail;

  bool get isError => severity == 'error';

  factory SolverDiagnostic.fromMap(Map<String, dynamic> m) => SolverDiagnostic(
        severity: (m['severity'] ?? 'warning') as String,
        code: (m['code'] ?? '') as String,
        message: (m['message'] ?? '') as String,
        detail: m['detail'] as String?,
      );
}

class TimetableVersion {
  const TimetableVersion({
    required this.id,
    required this.status,
    required this.isActive,
    required this.stats,
    required this.diagnostics,
    this.label,
    this.createdAt,
  });

  final String id;
  final String status;
  final bool isActive;
  final Map<String, dynamic> stats;
  final List<SolverDiagnostic> diagnostics;
  final String? label;
  final String? createdAt;

  int get errorCount => diagnostics.where((d) => d.isError).length;
  int get warningCount => diagnostics.where((d) => !d.isError).length;

  num? stat(String key) => stats[key] as num?;

  factory TimetableVersion.fromMap(Map<String, dynamic> m) => TimetableVersion(
        id: (m['id'] ?? '') as String,
        status: (m['status'] ?? 'draft') as String,
        isActive: (m['is_active'] ?? false) as bool,
        label: m['label'] as String?,
        createdAt: m['created_at'] as String?,
        stats: ((m['solver_stats'] ?? const {}) as Map).cast<String, dynamic>(),
        diagnostics: ((m['diagnostics'] ?? const []) as List)
            .map((d) => SolverDiagnostic.fromMap(d as Map<String, dynamic>))
            .toList(),
      );
}

/// What /timetable/generate returns.
class SolveOutcome {
  const SolveOutcome({
    required this.versionId,
    required this.status,
    required this.activated,
    required this.placedEverything,
    required this.stats,
    required this.diagnostics,
  });

  final String versionId;
  final String status;
  final bool activated;
  final bool placedEverything;
  final Map<String, dynamic> stats;
  final List<SolverDiagnostic> diagnostics;

  int get errorCount => diagnostics.where((d) => d.isError).length;
  int get warningCount => diagnostics.where((d) => !d.isError).length;

  factory SolveOutcome.fromMap(Map<String, dynamic> m) => SolveOutcome(
        versionId: (m['version_id'] ?? '') as String,
        status: (m['status'] ?? '') as String,
        activated: (m['activated'] ?? false) as bool,
        placedEverything: (m['placed_everything'] ?? false) as bool,
        stats: ((m['stats'] ?? const {}) as Map).cast<String, dynamic>(),
        diagnostics: ((m['diagnostics'] ?? const []) as List)
            .map((d) => SolverDiagnostic.fromMap(d as Map<String, dynamic>))
            .toList(),
      );
}

class Timetable {
  Timetable({required this.version, required this.entries});

  final TimetableVersion? version;
  final List<TimetableEntry> entries;

  // A whole-school timetable is ~1,440 entries and the grid asks for 36 cells
  // per rebuild. Scanning the list for each one is 50k comparisons a frame,
  // which is felt on every scroll. Everything below is computed once.
  Map<String, TimetableEntry>? _index;
  Map<int, String>? _startTimes;
  List<String>? _classNames;
  List<int>? _days;
  List<int>? _periods;

  Map<String, TimetableEntry> get _lookup {
    if (_index != null) return _index!;
    final m = <String, TimetableEntry>{};
    for (final e in entries) {
      // Three keys per entry so a lookup is O(1) whether the caller filters by
      // class, by teacher, or not at all.
      m.putIfAbsent('${e.dayOfWeek}|${e.slotIndex}', () => e);
      m['${e.dayOfWeek}|${e.slotIndex}|c:${e.className}'] = e;
      m['${e.dayOfWeek}|${e.slotIndex}|t:${e.teacherId}'] = e;
    }
    return _index = m;
  }

  /// Start time of each period, for the grid's row labels.
  Map<int, String> get startTimes {
    if (_startTimes != null) return _startTimes!;
    final m = <int, String>{};
    for (final e in entries) {
      if (e.startTime != null) {
        m.putIfAbsent(e.slotIndex, () => e.startTime!.substring(0, 5));
      }
    }
    return _startTimes = m;
  }

  List<String> get classNames => _classNames ??=
      (entries.map((e) => e.className).toSet().toList()..sort(_byGradeThenSection));

  List<int> get days =>
      _days ??= (entries.map((e) => e.dayOfWeek).toSet().toList()..sort());

  List<int> get periods =>
      _periods ??= (entries.map((e) => e.slotIndex).toSet().toList()..sort());

  TimetableEntry? at(int day, int period, {String? className, String? teacherId}) {
    final suffix = className != null
        ? '|c:$className'
        : teacherId != null
            ? '|t:$teacherId'
            : '';
    return _lookup['$day|$period$suffix'];
  }

  static int _byGradeThenSection(String a, String b) {
    final ga = int.tryParse(a.replaceAll(RegExp(r'\D'), '')) ?? 0;
    final gb = int.tryParse(b.replaceAll(RegExp(r'\D'), '')) ?? 0;
    return ga != gb ? ga.compareTo(gb) : a.compareTo(b);
  }
}
