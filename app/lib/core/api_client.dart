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
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.apiBaseUrl}$path'),
          headers: _headers,
          body: jsonEncode(body ?? const {}),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

final apiClientProvider = Provider<ApiClient>((_) => const ApiClient());

/// Phase 0 proof-of-life: Flutter -> FastAPI -> Supabase.
final backendHealthProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.read(apiClientProvider).get('/health/db');
});

/// Round-trips the caller's JWT through the API to confirm it verifies.
/// Watches auth so it refetches whenever the signed-in user changes.
final apiMeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(authControllerProvider.select((s) => s.session?.accessToken));
  return ref.read(apiClientProvider).get('/me');
});
