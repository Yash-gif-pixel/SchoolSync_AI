import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/dates.dart';
import '../core/documents_repository.dart';
import '../core/navigation.dart';
import '../core/school.dart';
import '../models/document_template.dart';
import '../models/extracted_document.dart';
import '../theme/app_theme.dart';
import '../widgets/review_field_row.dart';
import '../widgets/ui/primitives.dart';

/// `/documents/<id>` — the review screen, addressable by URL.
///
/// The screen itself needs a whole document; a URL carries only an id. This
/// resolves one to the other so a reviewer can bookmark a form, send a
/// colleague the link, or refresh the page mid-review without being thrown
/// back to the queue.
class DocumentReviewRoute extends ConsumerWidget {
  const DocumentReviewRoute({super.key, required this.documentId});

  final String documentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(documentProvider(documentId)).when(
          loading: () => const Scaffold(
            body: Center(child: Padding(
              padding: EdgeInsets.all(AppSpace.xl),
              child: SlowLoader(),
            )),
          ),
          error: (e, _) => Scaffold(
            appBar: AppBar(title: const Text('Review')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: EmptyState(
                  icon: Icons.description_outlined,
                  title: 'That form could not be opened',
                  message: '$e'.replaceFirst('Exception: ', ''),
                  action: FilledButton(
                    onPressed: () => context.go('/documents'),
                    child: const Text('Back to the queue'),
                  ),
                ),
              ),
            ),
          ),
          data: (doc) => DocumentReviewScreen(document: doc),
        );
  }
}

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
      ref.invalidate(documentProvider(widget.document.id));
      if (mounted) {
        closeScreen(context, fallback: '/documents', result: message);
      }
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
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          // Wrap so the status text and the buttons stack on a narrow window
          // instead of the message being crushed to nothing.
          //
          // The width cap must come from LayoutBuilder, not a bare constant: a
          // Wrap hands its children UNBOUNDED width, so a fixed maxWidth of
          // 620 is happily taken even on a 380px screen, and overflows.
          child: LayoutBuilder(builder: (context, bar) => Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: bar.maxWidth.clamp(0, 620)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    (_error ?? blocker) != null
                        ? Icons.block
                        : Icons.info_outline,
                    size: 17,
                    color: (_error ?? blocker) != null
                        ? AppColors.danger
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Text(
                      _error ??
                          blocker ??
                          switch (doc.template?.target) {
                            TemplateTarget.student =>
                              'These values will be saved as a new student record.',
                            TemplateTarget.leaveRequest =>
                              'These values will be saved as a leave request.',
                            _ =>
                              'These values will be saved against this document.',
                          },
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: (_error ?? blocker) != null
                            ? AppColors.danger
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ]),
              ),
              // Also constrained: a Wrap only breaks BETWEEN children, so a
              // single child wider than the line overflows regardless.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: bar.maxWidth),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(
                    onPressed: _committing
                        ? null
                        : () => closeScreen(context, fallback: '/documents'),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: FilledButton.icon(
                      onPressed:
                          (_committing || blocker != null) ? null : _commit,
                      icon: _committing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      // "Accept & create student" does not fit beside Cancel
                      // on a phone, so it degrades to the verb alone.
                      label: Text(
                        _committing
                            ? 'Saving…'
                            : (bar.maxWidth < 460 ? 'Accept' : _commitLabel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ]),
              ),
            ],
          )),
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
    // A Wrap, not a Row: the pills plus the model name are more than a narrow
    // window can hold on one line, and they should reflow rather than clip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, 0, AppSpace.xl, AppSpace.md),
      color: AppColors.surface,
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (doc.errorCount > 0)
            StatusPill(
                label: '${doc.errorCount} must be fixed',
                tone: Tone.danger,
                icon: Icons.error_outline),
          if (doc.warningCount > 0)
            StatusPill(
                label: '${doc.warningCount} to check',
                tone: Tone.warning,
                icon: Icons.warning_amber_rounded),
          if (doc.errorCount == 0 && doc.warningCount == 0)
            const StatusPill(
                label: 'clean extraction',
                tone: Tone.success,
                icon: Icons.check_circle_outline),
          if (doc.confidence != null)
            Text('avg confidence ${(doc.confidence! * 100).round()}%',
                style: theme.textTheme.labelSmall),
          if (doc.model != null)
            Text(doc.model!, style: theme.textTheme.labelSmall),
        ],
      ),
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
      color: AppColors.surfaceMuted,
      child: Column(children: [
        if (doc.documentQuality != 'good')
          Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Callout(
              tone: Tone.warning,
              icon: Icons.photo_camera_back_outlined,
              message: 'Image quality: ${doc.documentQuality}',
              detail: doc.qualityNote,
            ),
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
  Widget build(BuildContext context) => Callout(
        tone: issue.isError ? Tone.danger : Tone.warning,
        message: issue.message,
        detail: issue.suggestion,
      );
}
