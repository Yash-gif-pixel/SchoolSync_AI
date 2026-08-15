import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_controller.dart';
import 'config.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Talks to the FastAPI backend, attaching the caller's Supabase JWT so the
/// API can verify who they are.
class ApiClient {
  const ApiClient();

  /// Long enough to outlast a sleeping server.
  ///
  /// Free-tier hosting spins the container down after a quiet spell, and the
  /// request that wakes it can take the better part of a minute. A 30-second
  /// timeout — which is what this used to be — meant the first request after
  /// any idle period failed every single time, while the loading indicator
  /// was still telling the user to expect about a minute.
  ///
  /// A real outage now takes 90 seconds to report instead of 30. That is the
  /// right trade: a slow success beats a fast, wrong "failed to fetch".
  static const _timeout = Duration(seconds: 90);

  /// Solving a timetable is CPU-bound work on the server, so it gets its own
  /// budget on top of any cold start.
  static const _longTimeout = Duration(seconds: 120);

  Map<String, String> get _headers {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> get(String path) async {
    final res = await http
        .get(Uri.parse('${AppConfig.apiBaseUrl}$path'), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// For endpoints that return a JSON array rather than an object.
  Future<List<dynamic>> getList(String path) async {
    final res = await http
        .get(Uri.parse('${AppConfig.apiBaseUrl}$path'), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<void> delete(String path) async {
    final res = await http
        .delete(Uri.parse('${AppConfig.apiBaseUrl}$path'), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.apiBaseUrl}$path'),
          headers: _headers,
          body: jsonEncode(body ?? const {}),
        )
        .timeout(_longTimeout);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

final apiClientProvider = Provider<ApiClient>((_) => const ApiClient());

/// Phase 0 proof-of-life: Flutter -> FastAPI -> Supabase.
final backendHealthProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(apiClientProvider).get('/health/db');
});

/// Round-trips the caller's JWT through the API to confirm it verifies.
final apiMeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(apiClientProvider).get('/me');
});
