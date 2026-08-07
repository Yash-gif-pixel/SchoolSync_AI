/// Client-side view of a scanned document and what the AI made of it.
library;

import 'document_template.dart';

/// How a single field should be presented in review.
enum FieldState {
  ok, // read confidently, no rule tripped
  review, // low confidence, or a validation rule flagged it
  illegible, // the label is on the form but the value can't be read
  absent, // the form has no such field at all
}

class ExtractedField {
  const ExtractedField({
    required this.field,
    required this.value,
    required this.rawText,
    required this.presentOnForm,
    required this.confidence,
    this.note,
  });

  final String field;
  final String? value;
  final String? rawText;
  final bool presentOnForm;
  final double confidence;
  final String? note;

  /// Placeholder for a field the extractor never mentioned.
  factory ExtractedField.missing(String key) => ExtractedField(
        field: key,
        value: null,
        rawText: null,
        presentOnForm: false,
        confidence: 0,
      );

  FieldState state({bool hasIssue = false}) {
    if (!presentOnForm) return FieldState.absent;
    if (value == null || value!.isEmpty) return FieldState.illegible;
    if (hasIssue || confidence < 0.85) return FieldState.review;
    return FieldState.ok;
  }

  factory ExtractedField.fromMap(Map<String, dynamic> m) => ExtractedField(
        field: m['field'] as String,
        value: m['value'] as String?,
        rawText: m['raw_text'] as String?,
        presentOnForm: (m['present_on_form'] ?? false) as bool,
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String?,
      );
}

class ValidationIssue {
  const ValidationIssue({
    required this.field,
    required this.severity,
    required this.code,
    required this.message,
    this.suggestion,
  });

  final String field;
  final String severity; // 'error' | 'warning'
  final String code;
  final String message;
  final String? suggestion;

  bool get isError => severity == 'error';

  factory ValidationIssue.fromMap(Map<String, dynamic> m) => ValidationIssue(
        field: (m['field'] ?? '') as String,
        severity: (m['severity'] ?? 'warning') as String,
        code: (m['code'] ?? '') as String,
        message: (m['message'] ?? '') as String,
        suggestion: m['suggestion'] as String?,
      );
}

class ExtractedDocument {
  const ExtractedDocument({
    required this.id,
    required this.status,
    required this.storagePath,
    required this.fields,
    required this.issues,
    required this.errorCount,
    required this.warningCount,
    required this.documentQuality,
    this.template,
    this.qualityNote,
    this.imageUrl,
    this.confidence,
    this.model,
    this.createdAt,
  });

  final String id;
  final String status;
  final String storagePath;
  final List<ExtractedField> fields;
  final List<ValidationIssue> issues;
  final int errorCount;
  final int warningCount;
  final String documentQuality;
  final DocumentTemplate? template;
  final String? qualityNote;
  final String? imageUrl;
  final double? confidence;
  final String? model;
  final String? createdAt;

  bool get blocked => errorCount > 0;
  bool get isCommitted => status == 'committed';

  /// Template order is the reading order of the paper form, so review follows
  /// the same sequence as the page.
  List<TemplateField> get orderedSpecs => template?.fields ?? const [];

  ExtractedField fieldFor(String key) => fields.firstWhere(
        (f) => f.field == key,
        orElse: () => ExtractedField.missing(key),
      );

  /// Best-effort display name, used in queue listings.
  String get subjectLabel {
    final nameKey = template?.fields
        .firstWhere(
          (f) => f.mapsTo == 'full_name',
          orElse: () => TemplateField(
              key: '', label: '', type: FieldType.text),
        )
        .key;
    if (nameKey != null && nameKey.isNotEmpty) {
      final v = fieldFor(nameKey).value;
      if (v != null && v.isNotEmpty) return v;
    }
    // No mapped name: fall back to the first non-empty text field.
    for (final s in orderedSpecs) {
      if (s.type == FieldType.text || s.type == FieldType.longtext) {
        final v = fieldFor(s.key).value;
        if (v != null && v.isNotEmpty) return v;
      }
    }
    return template?.name ?? 'Scanned document';
  }

  List<ValidationIssue> issuesFor(String key) =>
      issues.where((i) => i.field == key).toList();

  List<ValidationIssue> get documentIssues =>
      issues.where((i) => i.field == '_document').toList();

  factory ExtractedDocument.fromMap(Map<String, dynamic> m) {
    final ex = (m['extracted_json'] ?? const {}) as Map<String, dynamic>;
    // The API returns the template either inline or via the join alias.
    final tplMap = (m['template'] ?? m['document_templates']) as Map<String, dynamic>?;

    return ExtractedDocument(
      id: m['id'] as String,
      status: (m['status'] ?? 'uploaded') as String,
      storagePath: (m['storage_path'] ?? '') as String,
      imageUrl: m['image_url'] as String?,
      confidence: (m['confidence'] as num?)?.toDouble(),
      model: ex['_model'] as String?,
      createdAt: m['created_at'] as String?,
      template: tplMap == null ? null : DocumentTemplate.fromMap(tplMap),
      documentQuality: (ex['document_quality'] ?? 'good') as String,
      qualityNote: ex['quality_note'] as String?,
      errorCount: (ex['error_count'] ?? 0) as int,
      warningCount: (ex['warning_count'] ?? 0) as int,
      fields: ((ex['fields'] ?? const []) as List)
          .map((f) => ExtractedField.fromMap(f as Map<String, dynamic>))
          .toList(),
      issues: ((ex['issues'] ?? const []) as List)
          .map((i) => ValidationIssue.fromMap(i as Map<String, dynamic>))
          .toList(),
    );
  }
}
