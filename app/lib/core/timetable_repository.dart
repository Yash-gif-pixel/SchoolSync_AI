import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/timetable.dart';
import 'auth_controller.dart';
import 'config.dart';

class TimetableRepository {
  const TimetableRepository();

  Map<String, String> get _auth {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';
    return {'Authorization': ?bearer, 'Content-Type': 'application/json'};
  }

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}/timetable$path');

  /// Generation runs a constraint solver, so it is slow by design.
  Future<SolveOutcome> generate({
    double timeLimit = 20,
    bool optimiseGaps = true,
    String? label,
  }) async {
    final res = await http
        .post(
          _uri('/generate'),
          headers: _auth,
          body: jsonEncode({
            'time_limit': timeLimit,
            'optimise_gaps': optimiseGaps,
            'label': label,
            'activate': true,
          }),
        )
        .timeout(Duration(seconds: timeLimit.ceil() + 60));
    _check(res);
    return SolveOutcome.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// The arithmetic checks alone — instant, no search.
  Future<List<SolverDiagnostic>> preflight() async {
    final res = await http.get(_uri('/preflight'), headers: _auth);
    _check(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return ((body['diagnostics'] ?? const []) as List)
        .map((d) => SolverDiagnostic.fromMap(d as Map<String, dynamic>))
        .toList();
  }

  Future<Timetable> active() async {
    final res = await http.get(_uri('/active'), headers: _auth);
    if (res.statusCode == 404) {
      return Timetable(version: null, entries: []);
    }
    _check(res);
    return _parse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Timetable> mine() async {
    final res = await http.get(_uri('/me'), headers: _auth);
    if (res.statusCode == 404) {
      return Timetable(version: null, entries: []);
    }
    _check(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return Timetable(
      version: null,
      entries: ((body['entries'] ?? const []) as List)
          .map((e) => TimetableEntry.fromMap(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<TimetableVersion>> versions() async {
    final res = await http.get(_uri('/versions'), headers: _auth);
    _check(res);
    return (jsonDecode(res.body) as List)
        .map((m) => TimetableVersion.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  Future<Timetable> version(String id) async {
    final res = await http.get(_uri('/versions/$id'), headers: _auth);
    _check(res);
    return _parse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> activate(String id) async {
    final res = await http.post(_uri('/versions/$id/activate'), headers: _auth);
    _check(res);
  }

  Timetable _parse(Map<String, dynamic> body) => Timetable(
        version: body['version'] == null
            ? null
            : TimetableVersion.fromMap(body['version'] as Map<String, dynamic>),
        entries: ((body['entries'] ?? const []) as List)
            .map((e) => TimetableEntry.fromMap(e as Map<String, dynamic>))
            .toList(),
      );

  void _check(http.Response res) {
    if (res.statusCode < 400) return;
    String detail;
    try {
      final d = (jsonDecode(res.body) as Map<String, dynamic>)['detail'];
      detail = d is String ? d : res.body;
    } catch (_) {
      detail = switch (res.statusCode) {
        401 => 'Please sign in again.',
        403 => 'Only an admin can generate a timetable.',
        404 => 'No timetable has been published yet.',
        _ => 'Request failed (${res.statusCode}).',
      };
    }
    throw Exception(detail);
  }
}

final timetableRepositoryProvider =
    Provider<TimetableRepository>((_) => const TimetableRepository());

final activeTimetableProvider = FutureProvider<Timetable>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(timetableRepositoryProvider).active();
});

/// Strictly user-scoped — the whole point is "my" week.
final myTimetableProvider = FutureProvider<Timetable>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(timetableRepositoryProvider).mine();
});

final timetableVersionsProvider =
    FutureProvider<List<TimetableVersion>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(timetableRepositoryProvider).versions();
});
