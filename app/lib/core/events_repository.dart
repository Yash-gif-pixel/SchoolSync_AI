import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth_controller.dart';

class EventTeacher {
  const EventTeacher({required this.id, required this.name});
  final String id;
  final String name;

  factory EventTeacher.fromJson(Map<String, dynamic> j) => EventTeacher(
        id: j['teacher_id'] as String,
        name: (j['full_name'] as String?) ?? 'Unknown',
      );
}

/// Annual Day, Sports Day, an inspection — anything that takes staff off the
/// timetable without being leave.
class SchoolEvent {
  const SchoolEvent({
    required this.id,
    required this.name,
    required this.startsOn,
    required this.endsOn,
    required this.days,
    required this.teachers,
    this.eventType,
    this.notes,
  });

  final String id;
  final String name;
  final DateTime startsOn;
  final DateTime endsOn;
  final int days;
  final List<EventTeacher> teachers;
  final String? eventType;
  final String? notes;

  bool get isMultiDay => days > 1;

  bool get isOver => endsOn.isBefore(
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));

  bool get isRunning {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return !startsOn.isAfter(today) && !endsOn.isBefore(today);
  }

  /// Teacher-days lost. A three-day event with twelve staff costs thirty six,
  /// which is the number that actually matters for cover.
  int get teacherDays => teachers.length * days;

  factory SchoolEvent.fromJson(Map<String, dynamic> j) => SchoolEvent(
        id: j['id'] as String,
        name: j['name'] as String,
        startsOn: DateTime.parse(j['date'] as String),
        endsOn: DateTime.parse((j['ends_on'] ?? j['date']) as String),
        days: (j['days'] as num?)?.toInt() ?? 1,
        eventType: j['event_type'] as String?,
        notes: j['notes'] as String?,
        teachers: ((j['teachers'] as List?) ?? const [])
            .map((e) => EventTeacher.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class EventsRepository {
  const EventsRepository(this._api);
  final ApiClient _api;

  static String _day(DateTime d) => d.toIso8601String().split('T').first;

  Future<List<SchoolEvent>> list() async {
    final rows = await _api.getList('/events');
    return rows
        .map((e) => SchoolEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> create({
    required String name,
    required DateTime startsOn,
    required DateTime endsOn,
    required List<String> teacherIds,
    String? eventType,
    String? notes,
  }) =>
      _api.post('/events', {
        'name': name,
        'starts_on': _day(startsOn),
        'ends_on': _day(endsOn),
        'teacher_ids': teacherIds,
        if (eventType != null && eventType.isNotEmpty) 'event_type': eventType,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      });

  Future<void> delete(String id) => _api.delete('/events/$id');
}

final eventsRepositoryProvider = Provider<EventsRepository>(
  (ref) => EventsRepository(ref.read(apiClientProvider)),
);

final eventsProvider = FutureProvider<List<SchoolEvent>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(eventsRepositoryProvider).list();
});
