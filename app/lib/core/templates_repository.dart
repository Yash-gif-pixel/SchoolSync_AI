import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/document_template.dart';
import 'auth_controller.dart';
import 'config.dart';

/// What the AI proposes after looking at a blank form. A suggestion for a
/// human to edit — never saved as-is.
class TemplateProposal {
  const TemplateProposal({
    required this.documentKind,
    required this.suggestedName,
    required this.target,
    required this.fields,
    required this.definitionErrors,
    this.samplePath,
    this.sampleUrl,
  });

  final String documentKind;
  final String suggestedName;
  final TemplateTarget target;
  final List<TemplateField> fields;
  final List<String> definitionErrors;
  final String? samplePath;
  final String? sampleUrl;

  factory TemplateProposal.fromMap(Map<String, dynamic> m) => TemplateProposal(
        documentKind: (m['document_kind'] ?? '') as String,
        suggestedName: (m['suggested_name'] ?? 'Untitled form') as String,
        target: TemplateTarget.parse(m['suggested_target'] as String?),
        samplePath: m['sample_path'] as String?,
        sampleUrl: m['sample_url'] as String?,
        definitionErrors:
            ((m['definition_errors'] ?? const []) as List).cast<String>(),
        fields: ((m['fields'] ?? const []) as List)
            .map((f) => TemplateField.fromMap(f as Map<String, dynamic>))
            .toList(),
      );
}

class TemplatesRepository {
  const TemplatesRepository();

  Map<String, String> get _auth {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {if (token != null) 'Authorization': 'Bearer $token'};
  }

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}/templates$path');

  Future<List<DocumentTemplate>> list() async {
    final res = await http.get(_uri(''), headers: _auth);
    _check(res);
    return (jsonDecode(res.body) as List)
        .map((m) => DocumentTemplate.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  /// Read a form and propose a schema for it. Saves nothing.
  Future<TemplateProposal> discover({
    required String filename,
    required List<int> bytes,
    required String mimeType,
  }) async {
    final parts = mimeType.split('/');
    final req = http.MultipartRequest('POST', _uri('/discover'))
      ..headers.addAll(_auth)
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: parts.length == 2 ? MediaType(parts[0], parts[1]) : null,
      ));

    final res = await http.Response.fromStream(
      await req.send().timeout(const Duration(seconds: 120)),
    );
    _check(res);
    return TemplateProposal.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<DocumentTemplate> get(String id) async {
    final res = await http.get(_uri('/$id'), headers: _auth);
    _check(res);
    return DocumentTemplate.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<DocumentTemplate> create(DocumentTemplate t) async {
    final res = await http.post(
      _uri(''),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode(t.toPayload()),
    );
    _check(res);
    return DocumentTemplate.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<DocumentTemplate> update(DocumentTemplate t) async {
    final res = await http.put(
      _uri('/${t.id}'),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode(t.toPayload()),
    );
    _check(res);
    return DocumentTemplate.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<DocumentTemplate> duplicate(String id) async {
    final res = await http.post(_uri('/$id/duplicate'), headers: _auth);
    _check(res);
    return DocumentTemplate.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> delete(String id) async {
    final res = await http.delete(_uri('/$id'), headers: _auth);
    if (res.statusCode != 404) _check(res);
  }

  void _check(http.Response res) {
    if (res.statusCode < 400) return;
    throw Exception(_readableError(res.statusCode, res.body));
  }

  static String _readableError(int code, String body) {
    try {
      final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      if (detail is String) return detail;
      // Validation failures come back as {message, errors[]}.
      if (detail is Map && detail['errors'] is List) {
        final errors = (detail['errors'] as List).join('\n• ');
        return '${detail['message']}:\n• $errors';
      }
    } catch (_) {}
    return switch (code) {
      401 => 'Please sign in again.',
      403 => 'Only an admin can manage templates.',
      409 => 'A template with that name already exists.',
      413 => 'That image is too large (12 MB limit).',
      415 => 'Unsupported image type. Use JPEG, PNG or WebP.',
      422 => 'No fields could be identified on that image.',
      502 => 'The AI could not read that form. Try again.',
      _ => 'Request failed ($code).',
    };
  }
}

final templatesRepositoryProvider =
    Provider<TemplatesRepository>((_) => const TemplatesRepository());

final templatesProvider = FutureProvider<List<DocumentTemplate>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref.read(templatesRepositoryProvider).list();
});

/// One template by id, so `/templates/<id>/edit` can be opened cold.
///
/// Fetched rather than picked out of [templatesProvider]: that list only
/// carries active templates, and a retired one is still a legitimate thing to
/// follow a link to and look at.
final templateProvider =
    FutureProvider.family<DocumentTemplate, String>((ref, id) async {
  ref.watch(currentUserIdProvider);
  return ref.read(templatesRepositoryProvider).get(id);
});
