import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/extracted_document.dart';
import 'auth_controller.dart';
import 'config.dart';

class DocumentsRepository {
  const DocumentsRepository();

  Map<String, String> get _auth {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';
    return {'Authorization': ?bearer};
  }

  /// Upload one form and get back the extraction. Slow by nature — the request
  /// is waiting on Gemini, typically 8–15 seconds.
  Future<ExtractedDocument> extract({
    required String filename,
    required List<int> bytes,
    required String mimeType,
    String? templateId,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConfig.apiBaseUrl}/documents/extract'),
    )
      ..headers.addAll(_auth)
      ..fields.addAll({'template_id': ?templateId})
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: _mediaType(mimeType),
      ));

    final res = await http.Response.fromStream(
      await req.send().timeout(const Duration(seconds: 120)),
    );

    if (res.statusCode >= 400) {
      throw Exception(_readableError(res.statusCode, res.body));
    }
    return ExtractedDocument.fromMap(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  Future<List<ExtractedDocument>> list({String? status}) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/documents')
        .replace(queryParameters: {'status_filter': ?status});
    final res = await http.get(uri, headers: _auth);
    if (res.statusCode >= 400) {
      throw Exception(_readableError(res.statusCode, res.body));
    }
    return (jsonDecode(res.body) as List)
        .map((m) => ExtractedDocument.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  Future<ExtractedDocument> get(String id) async {
    final res = await http.get(
      Uri.parse('${AppConfig.apiBaseUrl}/documents/$id'),
      headers: _auth,
    );
    if (res.statusCode >= 400) {
      throw Exception(_readableError(res.statusCode, res.body));
    }
    return ExtractedDocument.fromMap(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  /// Commit the values currently on screen — not whatever the model returned.
  /// Keys are template field keys; the server routes by the template's target.
  Future<String> commit(String id, Map<String, dynamic> values) async {
    final res = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/documents/$id/commit'),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode({'values': values}),
    );
    if (res.statusCode >= 400) {
      throw Exception(_readableError(res.statusCode, res.body));
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['message'] as String;
  }

  Future<void> discard(String id) async {
    final res = await http.delete(
      Uri.parse('${AppConfig.apiBaseUrl}/documents/$id'),
      headers: _auth,
    );
    if (res.statusCode >= 400 && res.statusCode != 404) {
      throw Exception(_readableError(res.statusCode, res.body));
    }
  }

  static MediaType? _mediaType(String mime) {
    final parts = mime.split('/');
    return parts.length == 2 ? MediaType(parts[0], parts[1]) : null;
  }

  static String _readableError(int code, String body) {
    try {
      final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      if (detail is String) return detail;
    } catch (_) {}
    return switch (code) {
      401 => 'Please sign in again.',
      403 => 'Only an admin can do that.',
      409 => 'This form has already been committed.',
      413 => 'That image is too large (12 MB limit).',
      415 => 'Unsupported image type. Use JPEG, PNG or WebP.',
      422 => 'That image does not look like an admission form.',
      502 => 'The AI extraction service failed. Try again.',
      _ => 'Request failed ($code).',
    };
  }
}

final documentsRepositoryProvider =
    Provider<DocumentsRepository>((_) => const DocumentsRepository());

/// The review queue on the admin dashboard.
final documentQueueProvider =
    FutureProvider<List<ExtractedDocument>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(documentsRepositoryProvider).list();
});

/// One document with its signed image URL, by id.
///
/// The queue listing carries no signed URL, so the review screen needs the
/// full record. Fetching it by id here — rather than handing the object to a
/// pushed route — is what lets `/documents/<id>` be opened cold: from a
/// bookmark, a shared link, or a browser refresh.
final documentProvider =
    FutureProvider.family<ExtractedDocument, String>((ref, id) async {
  ref.watch(currentUserIdProvider);
  return ref.read(documentsRepositoryProvider).get(id);
});
