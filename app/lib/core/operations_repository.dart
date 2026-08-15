import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/operations.dart';
import 'auth_controller.dart';
import 'config.dart';

class OperationsRepository {
  const OperationsRepository();

  /// Matches ApiClient. Long enough to outlast a free-tier container waking
  /// up — these calls previously had no timeout at all, so a genuine outage
  /// left the UI spinning indefinitely with nothing to report.
  static const _timeout = Duration(seconds: 90);

  Map<String, String> get _auth {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';
    return {'Authorization': ?bearer, 'Content-Type': 'application/json'};
  }

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('${AppConfig.apiBaseUrl}$path')
          .replace(queryParameters: q?.isEmpty ?? true ? null : q);

  // ------------------------------------------------------- attendance
  Future<List<TodayPeriod>> periodsToday() async {
    final res = await http.get(_uri('/attendance/today'), headers: _auth).timeout(_timeout);
    _check(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return ((body['periods'] ?? const []) as List)
        .map((p) => TodayPeriod.fromMap(p as Map<String, dynamic>))
        .toList();
  }

  Future<Roster> roster({required String classId, required String slotId}) async {
    final res = await http.get(
      _uri('/attendance/roster', {'class_id': classId, 'slot_id': slotId}),
      headers: _auth,
    ).timeout(_timeout);
    _check(res);
    return Roster.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<String> markAttendance({
    required String classId,
    required String slotId,
    required String date,
    required List<RosterStudent> students,
  }) async {
    final res = await http.post(
      _uri('/attendance/mark'),
      headers: _auth,
      body: jsonEncode({
        'class_id': classId,
        'slot_id': slotId,
        'date': date,
        'marks': [
          for (final s in students) {'student_id': s.id, 'status': s.status.name},
        ],
      }),
    ).timeout(_timeout);
    _check(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['message'] as String;
  }

  // ------------------------------------------------------------ leave
  Future<LeaveRequest> fileLeave({
    required DateTime from,
    required DateTime to,
    String? reason,
  }) async {
    final res = await http.post(
      _uri('/leave'),
      headers: _auth,
      body: jsonEncode({
        'from_date': _iso(from),
        'to_date': _iso(to),
        'reason': reason,
      }),
    ).timeout(_timeout);
    _check(res);
    return LeaveRequest.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<LeaveRequest>> myLeave() async {
    final res = await http.get(_uri('/leave/mine'), headers: _auth).timeout(_timeout);
    _check(res);
    return (jsonDecode(res.body) as List)
        .map((m) => LeaveRequest.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  Future<List<LeaveRequest>> pendingApprovals() async {
    final res = await http.get(_uri('/leave/pending'), headers: _auth).timeout(_timeout);
    _check(res);
    return (jsonDecode(res.body) as List)
        .map((m) => LeaveRequest.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  /// Approving fires the substitution matcher server-side; the returned
  /// counts say how much cover it found.
  Future<Map<String, dynamic>> reviewLeave(String id, {required bool approve}) async {
    final res = await http.post(
      _uri('/leave/$id/review'),
      headers: _auth,
      body: jsonEncode({'approve': approve}),
    ).timeout(_timeout);
    _check(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ------------------------------------------------------------ cover
  Future<ActionBoard> actionBoard() async {
    final res = await http.get(_uri('/substitutions/board'), headers: _auth).timeout(_timeout);
    _check(res);
    return ActionBoard.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<String> confirmCover(String substitutionId) async {
    final res = await http.post(
      _uri('/substitutions/$substitutionId/confirm'),
      headers: _auth,
      body: jsonEncode({}),
    ).timeout(_timeout);
    _check(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['message'] as String;
  }

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _check(http.Response res) {
    if (res.statusCode < 400) return;
    String detail;
    try {
      final d = (jsonDecode(res.body) as Map<String, dynamic>)['detail'];
      detail = d is String ? d : res.body;
    } catch (_) {
      detail = switch (res.statusCode) {
        401 => 'Please sign in again.',
        403 => 'You are not allowed to do that.',
        409 => 'This has already been dealt with.',
        _ => 'Request failed (${res.statusCode}).',
      };
    }
    throw Exception(detail);
  }
}

final operationsRepositoryProvider =
    Provider<OperationsRepository>((_) => const OperationsRepository());

// ---------------------------------------------------------------- realtime
/// Emits whenever leave or cover changes anywhere in the school.
///
/// This is what makes the Action Board update without a refresh: Postgres
/// pushes the change over a websocket, Riverpod invalidates the board, and the
/// admin sees a new absence appear while the teacher is still on the
/// confirmation screen.
final coverChangesProvider = StreamProvider<int>((ref) {
  final controller = StreamController<int>();
  var ticks = 0;

  final channel = Supabase.instance.client.channel('cover-changes');
  for (final table in ['substitutions', 'leave_requests']) {
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: table,
      callback: (_) => controller.add(++ticks),
    );
  }
  channel.subscribe();

  ref.onDispose(() {
    Supabase.instance.client.removeChannel(channel);
    controller.close();
  });

  return controller.stream;
});

// ---------------------------------------------------------------- providers
//
// Anything user-scoped watches currentUserIdProvider. These providers are not
// autoDispose, so without it they keep serving the previous account's data
// after a sign-out and sign-in in the same tab.

final periodsTodayProvider = FutureProvider<List<TodayPeriod>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(operationsRepositoryProvider).periodsToday();
});

final myLeaveProvider = FutureProvider<List<LeaveRequest>>((ref) async {
  ref.watch(currentUserIdProvider);
  ref.watch(coverChangesProvider);
  return ref.read(operationsRepositoryProvider).myLeave();
});

final pendingApprovalsProvider = FutureProvider<List<LeaveRequest>>((ref) async {
  ref.watch(currentUserIdProvider);
  final profile = ref.watch(authControllerProvider).profile;
  if (!(profile?.isApprover ?? false) && !(profile?.isAdmin ?? false)) {
    return const [];
  }
  ref.watch(coverChangesProvider);
  return ref.read(operationsRepositoryProvider).pendingApprovals();
});

/// Watches the realtime stream, so the board refetches the moment anything
/// changes rather than waiting for the user to pull to refresh.
final actionBoardProvider = FutureProvider<ActionBoard>((ref) async {
  ref.watch(currentUserIdProvider);
  ref.watch(coverChangesProvider);
  return ref.read(operationsRepositoryProvider).actionBoard();
});
