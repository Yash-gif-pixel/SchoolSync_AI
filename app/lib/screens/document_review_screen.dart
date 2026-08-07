import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dates.dart';
import '../core/documents_repository.dart';
import '../core/school.dart';
import '../models/document_template.dart';
import '../models/extracted_document.dart';
import '../widgets/review_field_row.dart';

/// Side-by-side review: the photograph on the left, what the AI read on the
/// right. Field order, labels and types all come from the template, so a
/// school's own form reviews exactly like the built-in one.
///
/// Every value stays editable — the reviewer commits what is on screen, not
/// what the model returned.
class DocumentReviewScreen extends ConsumerStatefulWidget {
  const DocumentReviewScreen({super.key, required this.document});

  final ExtractedDocument document;

  @override
  ConsumerState<DocumentReviewScreen> createState() => _DocumentReviewScreenState();
}

class _DocumentReviewScreenState extends ConsumerState<DocumentReviewScreen> {
  late final Map<String, TextEditingController> _controllers;
  bool _committing = false;
  String? _error;

  List<TemplateField> get _specs => widget.document.orderedSpecs;

  @override
  void initState() {
    super.initState();
    // Dates are shown day-month-year, the way they were written on the form.
    // ISO is a storage detail and is converted back on commit.
    _controllers = {
      for (final s in _specs)
        s.key: TextEditingController(
          text: s.type == FieldType.date
              ? Dates.isoToDisplay(widget.document.fieldFor(s.key).value)
              : widget.document.fieldFor(s.key).value ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _val(String key) {
    final v = _controllers[key]?.text.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// The values as they will be sent: dates normalised to ISO.
  Map<String, dynamic> get _payload => {
        for (final s in _specs)
          s.key: s.type == FieldType.date ? Dates.displayToIso(_val(s.key)) : _val(s.key),
      };

  /// Live check of what the server will reject outright, derived from the
  /// template's own field types — so it works for any school's form.
  String? get _blocker {
    for (final s in _specs) {
      final raw = _val(s.key);

      if (s.required && raw == null) return '${s.label} is required.';
      if (raw == null) continue;

      switch (s.type) {
        case FieldType.date:
          if (Dates.displayToIso(raw) == null) {
            return '${s.label} must be a real date in dd/mm/yyyy form.';
          }
        case FieldType.grade:
          final g = int.tryParse(raw);
          if (g == null) return '${s.label} must be a number.';
          if (!School.isValidGrade(g)) {
            return 'Class $g does not exist at this school '
                '(grades ${School.gradeRangeLabel}).';
          }
        case FieldType.number:
          if (double.tryParse(raw) == null) {
            return '${s.label} must be a number.';
          }
        case FieldType.phone:
          final d = raw.replaceAll(RegExp(r'\D'), '');
          if (d.length != 10 || !'6789'.contains(d[0])) {
            return '${s.label} must be a 10-digit Indian mobile number.';
          }
        case FieldType.email:
          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(raw)) {
            return '${s.label} must be a valid email address.';
          }
        case FieldType.text:
        case FieldType.longtext:
        case FieldType.choice:
          break;
      }
    }
    return null;
  }

  Future<void> _commit() async {
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      final message = await ref
          .read(documentsRepositoryProvider)
          .commit(widget.document.id, _payload);
      ref.invalidate(documentQueueProvider);
      if (mounted) Navigator.of(context).pop(message);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  String get _commitLabel => switch (widget.document.template?.target) {
        TemplateTarget.student => 'Accept & create student',
        TemplateTarget.leaveRequest => 'Accept & create leave request',
        _ => 'Accept & save',
      };

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final blocker = _blocker;

    final image = _SourceImage(doc: doc);
    final form = ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        for (final issue in doc.documentIssues)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Banner(issue: issue),
          ),
        for (final s in _specs)
          ReviewFieldRow(
            spec: s,
            extracted: doc.fieldFor(s.key),
            controller: _controllers[s.key]!,
            issues: doc.issuesFor(s.key),
            onChanged: () => setState(() {}),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(doc.template?.name ?? 'Review extracted form'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(38),
          child: _SummaryBar(doc: doc),
        ),
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: image),
                const VerticalDivider(width: 1),
                Expanded(flex: 6, child: form),
              ],
            )
          // Column, not ListView: `form` is already a ListView, and nesting
          // one vertical viewport inside another gives it unbounded height,
          // which throws. The scan gets a fixed pane and the fields scroll.
          : Column(
              children: [
                SizedBox(height: 320, child: image),
                const Divider(height: 1),
                Expanded(child: form),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(children: [
            if (_error != null)
              Expanded(
                child: Row(children: [
                  Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ]),
              )
            else if (blocker != null)
              Expanded(
                child: Row(children: [
                  Icon(Icons.block, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(blocker)),
                ]),
              )
            else
              Expanded(
                child: Text(switch (doc.template?.target) {
                  TemplateTarget.student =>
                    'These values will be saved as a new student record.',
                  TemplateTarget.leaveRequest =>
                    'These values will be saved as a leave request.',
                  _ => 'These values will be saved against this document.',
                }),
              ),
            const SizedBox(width: 16),
            TextButton(
              onPressed: _committing ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: (_committing || blocker != null) ? null : _commit,
              icon: _committing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check, size: 18),
              label: Text(_committing ? 'Saving…' : _commitLabel),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.doc});
  final ExtractedDocument doc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      child: Row(children: [
        if (doc.errorCount > 0) ...[
          Icon(Icons.error, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Text('${doc.errorCount} must be fixed',
              style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(width: 18),
        ],
        if (doc.warningCount > 0) ...[
          const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFB26A00)),
          const SizedBox(width: 6),
          Text('${doc.warningCount} to check',
              style: const TextStyle(color: Color(0xFFB26A00))),
          const SizedBox(width: 18),
        ],
        if (doc.errorCount == 0 && doc.warningCount == 0) ...[
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
          const SizedBox(width: 6),
          const Text('Clean extraction'),
          const SizedBox(width: 18),
        ],
        const Spacer(),
        if (doc.confidence != null)
          Text('avg confidence ${(doc.confidence! * 100).round()}%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (doc.model != null) ...[
          const SizedBox(width: 14),
          Text(doc.model!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

class _SourceImage extends StatelessWidget {
  const _SourceImage({required this.doc});
  final ExtractedDocument doc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(children: [
        if (doc.documentQuality != 'good')
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFFFFF3E0),
            child: Row(children: [
              const Icon(Icons.photo_camera_back_outlined,
                  size: 16, color: Color(0xFFB26A00)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Image quality: ${doc.documentQuality}'
                  '${doc.qualityNote != null ? ' — ${doc.qualityNote}' : ''}',
                  style: const TextStyle(color: Color(0xFF7A4A00), fontSize: 12),
                ),
              ),
            ]),
          ),
        Expanded(
          child: doc.imageUrl == null
              ? const Center(child: Text('No image available'))
              : InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      doc.imageUrl!,
                      fit: BoxFit.contain,
                      loadingBuilder: (c, child, progress) => progress == null
                          ? child
                          : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      errorBuilder: (c, e, s) =>
                          const Center(child: Text('Could not load the scan')),
                    ),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Scroll to zoom · drag to pan',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.issue});
  final ValidationIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final err = issue.isError;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: err ? theme.colorScheme.errorContainer : const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: err ? theme.colorScheme.error : const Color(0xFFFFCC80)),
      ),
      child: Row(children: [
        Icon(err ? Icons.error_outline : Icons.info_outline,
            size: 18, color: err ? theme.colorScheme.error : const Color(0xFFB26A00)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(issue.message),
            if (issue.suggestion != null)
              Text(issue.suggestion!, style: theme.textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}
