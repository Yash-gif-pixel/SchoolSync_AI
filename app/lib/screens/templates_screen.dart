import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/templates_repository.dart';
import '../models/document_template.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/primitives.dart';
import 'template_editor_screen.dart';

/// Manage the forms this school uses. Every school prints its own paperwork,
/// so the field list is data, not code.
class TemplatesScreen extends ConsumerStatefulWidget {
  const TemplatesScreen({super.key});

  @override
  ConsumerState<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends ConsumerState<TemplatesScreen> {
  bool _reading = false;

  Future<void> _discoverFromForm() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    if (f.bytes == null) return;

    setState(() => _reading = true);
    try {
      final proposal = await ref.read(templatesRepositoryProvider).discover(
            filename: f.name,
            bytes: f.bytes!,
            mimeType: switch (f.extension?.toLowerCase()) {
              'png' => 'image/png',
              'webp' => 'image/webp',
              _ => 'image/jpeg',
            },
          );
      if (!mounted) return;
      await _openEditor(proposal: proposal);
    } catch (e) {
      if (mounted) _snack('$e'.replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _openEditor({
    DocumentTemplate? template,
    TemplateProposal? proposal,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(template: template, proposal: proposal),
      ),
    );
    if (saved == true) ref.invalidate(templatesProvider);
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<void> _duplicate(DocumentTemplate t) async {
    try {
      final copy = await ref.read(templatesRepositoryProvider).duplicate(t.id);
      ref.invalidate(templatesProvider);
      if (mounted) await _openEditor(template: copy);
    } catch (e) {
      if (mounted) _snack('$e'.replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _delete(DocumentTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${t.name}"?'),
        content: const Text(
          'Documents already read with this template keep their records; the '
          'template is retired rather than removed if it has been used.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(templatesRepositoryProvider).delete(t.id);
      ref.invalidate(templatesProvider);
      if (mounted) _snack('Deleted "${t.name}".');
    } catch (e) {
      if (mounted) _snack('$e'.replaceFirst('Exception: ', ''), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(templatesProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Form templates',
      subtitle: 'Teach the reader your school’s own paperwork',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(templatesProvider),
        ),
      ],
      child: PageBody(
        maxWidth: 900,
        children: [
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Icon(Icons.auto_awesome_outlined,
                    size: 40, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('Teach it your own form',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  'Photograph a blank copy of any school form. The AI reads the '
                  'labels off it and drafts the field list for you to check.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                  FilledButton.icon(
                    onPressed: _reading ? null : _discoverFromForm,
                    icon: _reading
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.document_scanner_outlined),
                    label: Text(_reading ? 'Reading the form…' : 'Scan a blank form'),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
                  ),
                  OutlinedButton.icon(
                    onPressed: _reading ? null : () => _openEditor(),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Build by hand'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 22),
          Text('Your forms', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          templates.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: SlowLoader(),
            ),
            error: (e, _) => Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load templates: $e'),
              ),
            ),
            data: (list) => Column(
              children: [
                for (final t in list)
                  _TemplateTile(
                    template: t,
                    onEdit: () => _openEditor(template: t),
                    onDuplicate: () => _duplicate(t),
                    onDelete: () => _delete(t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.template,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  final DocumentTemplate template;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = template;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(t.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                if (t.isBuiltin)
                  _Tag(label: 'built-in', colour: theme.colorScheme.outline),
                if (!t.isActive)
                  _Tag(label: 'retired', colour: theme.colorScheme.error),
              ]),
              if (t.description != null && t.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(t.description!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                _Tag(label: t.target.shortLabel, colour: theme.colorScheme.primary),
                _Tag(
                  label: '${t.fields.length} fields',
                  colour: theme.colorScheme.onSurfaceVariant,
                ),
                if (t.requiredCount > 0)
                  _Tag(
                    label: '${t.requiredCount} required',
                    colour: theme.colorScheme.onSurfaceVariant,
                  ),
              ]),
            ]),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'edit' => onEdit(),
              'duplicate' => onDuplicate(),
              'delete' => onDelete(),
              _ => null,
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(t.isBuiltin ? Icons.visibility : Icons.edit, size: 18),
                  title: Text(t.isBuiltin ? 'View' : 'Edit'),
                ),
              ),
              const PopupMenuItem(
                value: 'duplicate',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.copy, size: 18),
                  title: Text('Duplicate'),
                ),
              ),
              if (!t.isBuiltin)
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline, size: 18),
                    title: Text('Delete'),
                  ),
                ),
            ],
          ),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.colour});
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colour)),
    );
  }
}
