import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/documents_repository.dart';
import '../core/templates_repository.dart';
import '../models/document_template.dart';
import '../models/extracted_document.dart';
import 'document_review_screen.dart';

/// Upload admission forms and work through the review queue.
class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  /// filename -> progress state, for the batch upload strip.
  final Map<String, _UploadState> _uploads = {};
  bool _busy = false;
  String? _templateId;

  Future<void> _pickAndUpload() async {
    // file_picker 11 made pickFiles static; there is no .platform accessor.
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    setState(() {
      _busy = true;
      for (final f in picked.files) {
        _uploads[f.name] = _UploadState.waiting;
      }
    });

    final repo = ref.read(documentsRepositoryProvider);

    // Deliberately serial. Gemini's free tier is rate-limited per minute, and
    // firing ten parallel uploads is the reliable way to get throttled.
    for (final f in picked.files) {
      if (f.bytes == null) {
        setState(() => _uploads[f.name] = _UploadState.failed);
        continue;
      }
      setState(() => _uploads[f.name] = _UploadState.extracting);
      try {
        await repo.extract(
          filename: f.name,
          bytes: f.bytes!,
          mimeType: _mimeFor(f.extension),
          templateId: _templateId,
        );
        setState(() => _uploads[f.name] = _UploadState.done);
      } catch (e) {
        setState(() {
          _uploads[f.name] = _UploadState.failed;
          _uploads['${f.name}::error'] = _UploadState.failed;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${f.name}: ${'$e'.replaceFirst('Exception: ', '')}')),
          );
        }
      }
      ref.invalidate(documentQueueProvider);
    }

    setState(() => _busy = false);
  }

  static String _mimeFor(String? ext) => switch (ext?.toLowerCase()) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };

  Future<void> _openReview(ExtractedDocument summary) async {
    final repo = ref.read(documentsRepositoryProvider);
    // The queue listing has no signed image URL; fetch the full record.
    final full = await repo.get(summary.id);
    if (!mounted) return;

    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => DocumentReviewScreen(document: full)),
    );
    if (message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ]),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
    ref.invalidate(documentQueueProvider);
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(documentQueueProvider);
    final templates = ref.watch(templatesProvider);
    final theme = Theme.of(context);

    // Default to the first template once they load.
    templates.whenData((list) {
      if (_templateId == null && list.isNotEmpty) {
        _templateId = list.first.id;
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Document Reader'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/templates'),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('Templates'),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(documentQueueProvider);
              ref.invalidate(templatesProvider);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _UploadCard(
            busy: _busy,
            onPick: _pickAndUpload,
            templates: templates,
            selectedId: _templateId,
            onTemplateChanged: (id) => setState(() => _templateId = id),
            onManageTemplates: () => context.push('/templates'),
          ),
          if (_uploads.isNotEmpty) ...[
            const SizedBox(height: 14),
            _BatchProgress(uploads: _uploads),
          ],
          const SizedBox(height: 22),
          Text('Review queue', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Nothing becomes a student record until you approve it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          queue.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load the queue: $e'),
              ),
            ),
            data: (docs) => docs.isEmpty
                ? _EmptyQueue()
                : Column(
                    children: [
                      for (final d in docs)
                        _QueueTile(doc: d, onTap: () => _openReview(d)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

enum _UploadState { waiting, extracting, done, failed }

class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.busy,
    required this.onPick,
    required this.templates,
    required this.selectedId,
    required this.onTemplateChanged,
    required this.onManageTemplates,
  });

  final bool busy;
  final VoidCallback onPick;
  final AsyncValue<List<DocumentTemplate>> templates;
  final String? selectedId;
  final ValueChanged<String?> onTemplateChanged;
  final VoidCallback onManageTemplates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = templates
        .whenOrNull(data: (list) => list)
        ?.where((t) => t.id == selectedId)
        .cast<DocumentTemplate?>()
        .firstOrNull;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(children: [
          Icon(Icons.document_scanner_outlined,
              size: 44, color: theme.colorScheme.primary),
          const SizedBox(height: 14),
          Text('Scan filled-in forms',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Photograph a handwritten form and the AI reads it against the '
            'template you pick. Select several at once for a batch.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 22),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: templates.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Could not load templates: $e',
                  style: TextStyle(color: theme.colorScheme.error)),
              data: (list) => list.isEmpty
                  ? Column(children: [
                      const Text('No templates yet.'),
                      TextButton(
                        onPressed: onManageTemplates,
                        child: const Text('Create one'),
                      ),
                    ])
                  : DropdownButtonFormField<String>(
                      initialValue: selectedId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Which form is this?',
                        border: const OutlineInputBorder(),
                        helperText: selected == null
                            ? null
                            : '${selected.fields.length} fields · '
                                '${selected.target.label.toLowerCase()}',
                        suffixIcon: IconButton(
                          tooltip: 'Manage templates',
                          icon: const Icon(Icons.settings_outlined, size: 18),
                          onPressed: onManageTemplates,
                        ),
                      ),
                      items: [
                        for (final t in list)
                          DropdownMenuItem(
                            value: t.id,
                            child: Text(t.name, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: busy ? null : onTemplateChanged,
                    ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: (busy || selectedId == null) ? null : onPick,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_file),
            label: Text(busy ? 'Reading…' : 'Choose forms'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
          ),
          const SizedBox(height: 10),
          Text('JPEG, PNG or WebP · up to 12 MB each',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _BatchProgress extends StatelessWidget {
  const _BatchProgress({required this.uploads});
  final Map<String, _UploadState> uploads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = uploads.entries.where((e) => !e.key.contains('::')).toList();

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                    width: 20,
                    child: switch (e.value) {
                      _UploadState.waiting =>
                        Icon(Icons.schedule, size: 16, color: theme.colorScheme.outline),
                      _UploadState.extracting => const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      _UploadState.done =>
                        Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
                      _UploadState.failed =>
                        Icon(Icons.error, size: 16, color: theme.colorScheme.error),
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(e.key,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                  ),
                  Text(
                    switch (e.value) {
                      _UploadState.waiting => 'queued',
                      _UploadState.extracting => 'reading…',
                      _UploadState.done => 'ready to review',
                      _UploadState.failed => 'failed',
                    },
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.doc, required this.onTap});
  final ExtractedDocument doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = doc.subjectLabel;

    final (Color colour, IconData icon, String label) = switch (doc.status) {
      'committed' => (Colors.green.shade600, Icons.how_to_reg, 'admitted'),
      'failed' => (theme.colorScheme.error, Icons.error_outline, 'failed'),
      _ when doc.errorCount > 0 =>
        (theme.colorScheme.error, Icons.error_outline, '${doc.errorCount} to fix'),
      _ when doc.warningCount > 0 =>
        (const Color(0xFFB26A00), Icons.warning_amber_rounded,
            '${doc.warningCount} to check'),
      _ => (Colors.green.shade600, Icons.check_circle, 'clean'),
    };

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: ListTile(
        onTap: doc.status == 'failed' ? null : onTap,
        leading: CircleAvatar(
          backgroundColor: colour.withValues(alpha: 0.15),
          child: Icon(icon, color: colour, size: 20),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          if (doc.template != null) doc.template!.name,
          label,
          if (doc.confidence != null) '${(doc.confidence! * 100).round()}% avg confidence',
        ].join('  ·  ')),
        trailing: doc.isCommitted
            ? Chip(
                label: const Text('admitted'),
                backgroundColor: Colors.green.shade50,
                labelStyle: TextStyle(color: Colors.green.shade800, fontSize: 12),
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 44),
      alignment: Alignment.center,
      child: Column(children: [
        Icon(Icons.inbox_outlined, size: 40, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Text('Nothing waiting for review',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
