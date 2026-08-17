import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/timetable.dart';
import 'auth_controller.dart';
import 'config.dart';

class TimetableRepository {
  const TimetableRepository();

  /// Must match DEFAULT_TIME_LIMIT in api/app/services/timetable.py.
  ///
  /// Not a knob to be tuned down. The solver splits this budget, and feasible
  /// packing of this school takes about 14.5s on its own; below roughly 35s
  /// phase one times out, the relaxed fallback runs instead, and the school
  /// gets a timetable with lessons missing from it. This used to default to
  /// 20 and did exactly that.
  static const defaultTimeLimit = 45.0;

  /// How often to ask whether the solve has finished.
  static const _pollEvery = Duration(seconds: 2);

  Map<String, String> get _auth {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';
    return {'Authorization': ?bearer, 'Content-Type': 'application/json'};
  }

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}/timetable$path');

  /// Generation runs a constraint solver, so it is slow by design — and slow
  /// in a way that a single HTTP request is a bad container for.
  ///
  /// Held open for 45 seconds, the request is at the mercy of every proxy
  /// between the browser and the server, several of which cut at 30. The
  /// solve completes and the user still sees a gateway error. So the solve is
  /// started as a job and polled: each request is short, and the answer is
  /// collected once the work is done.
  Future<SolveOutcome> generate({
    double timeLimit = defaultTimeLimit,
    bool optimiseGaps = true,
    String? label,
  }) async {
    final body = jsonEncode({
      'time_limit': timeLimit,
      'optimise_gaps': optimiseGaps,
      'label': label,
      'activate': true,
    });

    final started = await http
        .post(_uri('/jobs'), headers: _auth, body: body)
        .timeout(const Duration(seconds: 90));

    // A backend deployed before the job endpoints existed. The two halves of
    // this app deploy separately, so the older path is kept as a fallback
    // rather than assumed away.
    if (started.statusCode == 404 || started.statusCode == 405) {
      return _generateSynchronously(body, timeLimit);
    }
    _check(started);

    final jobId =
        (jsonDecode(started.body) as Map<String, dynamic>)['job_id'] as String;

    // Generous: the budget itself, plus a cold start, plus the database
    // writes that follow the solve.
    final deadline =
        DateTime.now().add(Duration(seconds: timeLimit.ceil() + 120));

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollEvery);

      final poll = await http
          .get(_uri('/jobs/$jobId'), headers: _auth)
          .timeout(const Duration(seconds: 90));
      _check(poll);

      final job = jsonDecode(poll.body) as Map<String, dynamic>;
      switch (job['status'] as String?) {
        case 'done':
          return SolveOutcome.fromMap(job['result'] as Map<String, dynamic>);
        case 'failed':
          throw Exception(job['error'] ?? 'The solver failed.');
      }
    }

    throw Exception(
      'The solver is still running after ${timeLimit.ceil() + 120} seconds. '
      'It has not been cancelled — check the version history in a moment.',
    );
  }

  Future<SolveOutcome> _generateSynchronously(
      String body, double timeLimit) async {
    final res = await http
        .post(_uri('/generate'), headers: _auth, body: body)
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
        409 => 'A timetable is already being generated. Wait for it to finish.',
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
