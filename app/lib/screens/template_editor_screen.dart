import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/templates_repository.dart';
import '../models/document_template.dart';
import '../widgets/template_field_editor.dart';

/// Curate a template — either one the AI drafted from a scanned blank form, or
/// one built by hand. The AI's proposal is always a starting point, never
/// something that reaches the database unreviewed.
class TemplateEditorScreen extends ConsumerStatefulWidget {
  const TemplateEditorScreen({super.key, this.template, this.proposal});

  final DocumentTemplate? template;
  final TemplateProposal? proposal;

  @override
  ConsumerState<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends ConsumerState<TemplateEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late TemplateTarget _target;
  late List<TemplateField> _fields;
  String? _samplePath;
  String? _sampleUrl;

  bool _saving = false;
  String? _error;

  bool get _isNew => widget.template == null;
  bool get _readOnly => widget.template?.isBuiltin ?? false;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    final p = widget.proposal;

    _name = TextEditingController(text: t?.name ?? p?.suggestedName ?? '');
    _description = TextEditingController(text: t?.description ?? '');
    _target = t?.target ?? p?.target ?? TemplateTarget.dataOnly;
    _fields = (t?.fields ?? p?.fields ?? []).map((f) => f.copy()).toList();
    _samplePath = t?.samplePath ?? p?.samplePath;
    _sampleUrl = p?.sampleUrl;

    if (_fields.isEmpty) _fields.add(_blankField());
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  TemplateField _blankField() => TemplateField(
        key: 'field_${_fields.length + 1}',
        label: '',
        type: FieldType.text,
      );

  /// Mirrors the server's checks so problems surface before saving.
  List<String> get _problems {
    final out = <String>[];
    if (_name.text.trim().isEmpty) out.add('The template needs a name.');
    if (_fields.isEmpty) out.add('Add at least one field.');

    final seen = <String>{};
    for (var i = 0; i < _fields.length; i++) {
      final f = _fields[i];
      final where = 'Field ${i + 1}';
      if (f.key.trim().isEmpty) {
        out.add('$where has no key.');
      } else if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(f.key)) {
        out.add('$where: key "${f.key}" may only use letters, digits and underscores.');
      } else if (!seen.add(f.key)) {
        out.add('Two fields share the key "${f.key}".');
      }
      if (f.label.trim().isEmpty) out.add('$where has no label.');
      if (f.type == FieldType.choice && (f.options?.isEmpty ?? true)) {
        out.add('$where is a choice field but has no options.');
      }
    }

    if (_target == TemplateTarget.student) {
      final mapped = _fields.map((f) => f.mapsTo).toSet();
      if (!mapped.contains('full_name')) {
        out.add('One field must be set to fill "Student name".');
      }
      if (!mapped.contains('__class')) {
        out.add('One field must be set to fill "Class to place them in".');
      }
    }
    return out;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(templatesRepositoryProvider);
      final t = DocumentTemplate(
        id: widget.template?.id ?? '',
        name: _name.text.trim(),
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        target: _target,
        fields: _fields,
        samplePath: _samplePath,
      );
      if (_isNew) {
        await repo.create(t);
      } else {
        await repo.update(t);
      }
      ref.invalidate(templatesProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problems = _problems;
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    final editor = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (widget.proposal != null) _DiscoveryBanner(proposal: widget.proposal!),
        if (_readOnly)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('This is the built-in template. Duplicate it to make '
                    'a version you can edit.'),
              ),
            ]),
          ),
        TextField(
          controller: _name,
          enabled: !_readOnly,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Template name',
            hintText: "e.g. St Mary's Admission Form 2026",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _description,
          enabled: !_readOnly,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Description (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        Text('What happens when a form is approved',
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        RadioGroup<TemplateTarget>(
          groupValue: _target,
          onChanged: (v) {
            if (_readOnly || v == null) return;
            setState(() => _target = v);
          },
          child: Column(
            children: [
              for (final t in TemplateTarget.values)
                RadioListTile<TemplateTarget>(
                  value: t,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.label),
                  subtitle: Text(
                    switch (t) {
                      TemplateTarget.student =>
                        'Admission and enrolment forms. Needs a name and a class.',
                      TemplateTarget.leaveRequest =>
                        'Leave applications and medical notes.',
                      TemplateTarget.dataOnly =>
                        'Mark sheets, fee receipts, transfer certificates — '
                            'anything you want captured without creating a record.',
                    },
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 32),
        Row(children: [
          Text('Fields', style: theme.textTheme.titleMedium),
          const SizedBox(width: 10),
          Text('${_fields.length}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const Spacer(),
          if (!_readOnly)
            TextButton.icon(
              onPressed: () => setState(() => _fields.add(_blankField())),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add field'),
            ),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < _fields.length; i++)
          TemplateFieldEditor(
            key: ValueKey('${_fields[i].hashCode}_$i'),
            field: _fields[i],
            index: i,
            target: _target,
            readOnly: _readOnly,
            onChanged: () => setState(() {}),
            onRemove: _fields.length == 1
                ? null
                : () => setState(() => _fields.removeAt(i)),
            onMoveUp: i == 0 ? null : () => setState(() {
                  final f = _fields.removeAt(i);
                  _fields.insert(i - 1, f);
                }),
            onMoveDown: i == _fields.length - 1 ? null : () => setState(() {
                  final f = _fields.removeAt(i);
                  _fields.insert(i + 1, f);
                }),
          ),
        const SizedBox(height: 40),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New template' : (_readOnly ? 'Template' : 'Edit template')),
      ),
      body: wide && _sampleUrl != null
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 4, child: _SamplePane(url: _sampleUrl!)),
              const VerticalDivider(width: 1),
              Expanded(flex: 6, child: editor),
            ])
          : editor,
      bottomNavigationBar: _readOnly
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(children: [
                  Expanded(
                    child: _error != null
                        ? Text(_error!, style: TextStyle(color: theme.colorScheme.error))
                        : problems.isEmpty
                            ? const Text('Ready to save.')
                            : Text(problems.first,
                                style: TextStyle(color: theme.colorScheme.error)),
                  ),
                  if (problems.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('+${problems.length - 1} more',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                    ),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: (_saving || problems.isNotEmpty) ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_outlined, size: 18),
                    label: Text(_saving ? 'Saving…' : 'Save template'),
                  ),
                ]),
              ),
            ),
    );
  }
}

class _DiscoveryBanner extends StatelessWidget {
  const _DiscoveryBanner({required this.proposal});
  final TemplateProposal proposal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Drafted from your form',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
              'Read as a ${proposal.documentKind.replaceAll('_', ' ')} with '
              '${proposal.fields.length} fields. Check every row before saving — '
              'labels and types are a first guess.',
              style: theme.textTheme.bodySmall,
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SamplePane extends StatelessWidget {
  const _SamplePane({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Center(child: Text('Could not load the form')),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('The form this was read from',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
