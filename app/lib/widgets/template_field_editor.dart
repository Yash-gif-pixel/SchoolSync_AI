import 'package:flutter/material.dart';

import '../models/document_template.dart';
import '../theme/app_theme.dart';

/// One row of the template editor: what to extract, how to read it, and where
/// it lands. The type is the important control — it decides which validation
/// rules apply once forms start coming in.
class TemplateFieldEditor extends StatefulWidget {
  const TemplateFieldEditor({
    super.key,
    required this.field,
    required this.index,
    required this.target,
    required this.onChanged,
    this.readOnly = false,
    this.onRemove,
    this.onMoveUp,
    this.onMoveDown,
  });

  final TemplateField field;
  final int index;
  final TemplateTarget target;
  final bool readOnly;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  State<TemplateFieldEditor> createState() => _TemplateFieldEditorState();
}

class _TemplateFieldEditorState extends State<TemplateFieldEditor> {
  late final TextEditingController _label;
  late final TextEditingController _key;
  late final TextEditingController _options;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.field.label);
    _key = TextEditingController(text: widget.field.key);
    _options = TextEditingController(text: widget.field.options?.join(', ') ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _options.dispose();
    super.dispose();
  }

  /// A label typed by hand should suggest a key, but never overwrite one the
  /// user has deliberately edited.
  void _onLabelChanged(String v) {
    widget.field.label = v;
    final auto = v
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9]+"), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final keyLooksAuto = _key.text.isEmpty ||
        _key.text.startsWith('field_') ||
        _key.text == _autoKeyOf(widget.field.label);
    if (keyLooksAuto && auto.isNotEmpty) {
      _key.text = auto;
      widget.field.key = auto;
    }
    widget.onChanged();
  }

  String _autoKeyOf(String label) => label
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9]+"), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  List<String> get _columns => switch (widget.target) {
        TemplateTarget.student => studentColumns,
        TemplateTarget.leaveRequest => leaveColumns,
        TemplateTarget.dataOnly => const [],
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = widget.field;
    final ro = widget.readOnly;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.md, AppSpace.md, AppSpace.sm, AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
          // Label and type side by side is only readable above ~520; below
          // that they stack, rather than each being squeezed to nothing.
          LayoutBuilder(builder: (context, constraints) {
            final label = TextField(
              controller: _label,
              enabled: !ro,
              onChanged: _onLabelChanged,
              decoration: const InputDecoration(
                labelText: 'Label on the form',
              ),
            );
            final type = DropdownButtonFormField<FieldType>(
              initialValue: f.type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final t in FieldType.values)
                  DropdownMenuItem(value: t, child: Text(t.label)),
              ],
              onChanged: ro
                  ? null
                  : (v) {
                      setState(() {
                        f.type = v!;
                        if (v == FieldType.choice) _expanded = true;
                      });
                      widget.onChanged();
                    },
            );
            final more = IconButton(
              tooltip: _expanded ? 'Fewer options' : 'More options',
              icon: Icon(_expanded ? Icons.expand_less : Icons.tune, size: 18),
              onPressed: () => setState(() => _expanded = !_expanded),
            );

            if (constraints.maxWidth < 520) {
              return Column(children: [
                Row(children: [
                  Expanded(child: label),
                  more,
                ]),
                const SizedBox(height: AppSpace.sm),
                type,
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 16, right: AppSpace.sm),
                child: Text('${widget.index + 1}',
                    style: theme.textTheme.labelSmall),
              ),
              Expanded(flex: 3, child: label),
              const SizedBox(width: AppSpace.sm),
              Expanded(flex: 2, child: type),
              more,
            ]);
          }),
          const SizedBox(height: 6),
          Row(children: [
            const SizedBox(width: 22),
            Icon(Icons.rule, size: 13, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Expanded(
              child: Text(f.type.rule,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            FilterChip(
              label: const Text('Required'),
              selected: f.required,
              visualDensity: VisualDensity.compact,
              onSelected: ro
                  ? null
                  : (v) {
                      setState(() => f.required = v);
                      widget.onChanged();
                    },
            ),
            if (widget.onRemove != null && !ro)
              IconButton(
                tooltip: 'Remove field',
                icon: Icon(Icons.close, size: 18, color: theme.colorScheme.error),
                onPressed: widget.onRemove,
              ),
          ]),
          if (_expanded) ...[
            const Divider(height: 22),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _key,
                  enabled: !ro,
                  onChanged: (v) {
                    f.key = v.trim();
                    widget.onChanged();
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Key',
                    helperText: 'Identifier used in the extracted data',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (_columns.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: _columns.contains(f.mapsTo) ? f.mapsTo : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Fills',
                      helperText: 'Where this value is stored',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('— nothing —'),
                      ),
                      for (final c in _columns)
                        DropdownMenuItem<String?>(
                          value: c,
                          child: Text(columnLabel(c), overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: ro
                        ? null
                        : (v) {
                            setState(() => f.mapsTo = v);
                            widget.onChanged();
                          },
                  ),
                ),
              ],
            ]),
            if (f.type == FieldType.choice) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _options,
                enabled: !ro,
                onChanged: (v) {
                  f.options = v
                      .split(',')
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toList();
                  widget.onChanged();
                },
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Allowed answers',
                  hintText: 'M, F',
                  helperText: 'Comma separated',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(children: [
              IconButton(
                tooltip: 'Move up',
                icon: const Icon(Icons.arrow_upward, size: 18),
                onPressed: ro ? null : widget.onMoveUp,
              ),
              IconButton(
                tooltip: 'Move down',
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: ro ? null : widget.onMoveDown,
              ),
            ]),
          ],
      ]),
    );
  }
}
