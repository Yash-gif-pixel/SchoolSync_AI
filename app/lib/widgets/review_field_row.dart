import 'package:flutter/material.dart';

import '../core/dates.dart';
import '../models/document_template.dart';
import '../models/extracted_document.dart';

/// One field in the review panel, described by the template and filled by the
/// extractor.
///
/// The colour carries meaning and the four states are deliberately distinct:
///   green  — read confidently, nothing tripped
///   amber  — low confidence, or a rule flagged it: look at this
///   red    — the label is on the form but the value is unreadable
///   grey   — the form has no such field; the AI did not guess one
///
/// Conflating "absent" with "unreadable" is what makes a review screen lie, so
/// they never share a colour.
class ReviewFieldRow extends StatelessWidget {
  const ReviewFieldRow({
    super.key,
    required this.spec,
    required this.extracted,
    required this.controller,
    required this.issues,
    required this.onChanged,
  });

  final TemplateField spec;
  final ExtractedField extracted;
  final TextEditingController controller;
  final List<ValidationIssue> issues;
  final VoidCallback onChanged;

  static const _amber = Color(0xFFB26A00);
  static const _amberBg = Color(0xFFFFF8E1);
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  bool get _isDate => spec.type == FieldType.date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = issues.any((i) => i.isError);
    final hasWarning = issues.any((i) => !i.isError);
    final state = extracted.state(hasIssue: hasError || hasWarning);

    final (Color accent, Color? bg, String badge) = switch (state) {
      FieldState.ok => (Colors.green.shade600, null, ''),
      FieldState.review => (
          hasError ? theme.colorScheme.error : _amber,
          hasError ? theme.colorScheme.errorContainer.withValues(alpha: 0.35) : _amberBg,
          hasError ? 'must fix' : 'check this',
        ),
      FieldState.illegible => (
          theme.colorScheme.error,
          theme.colorScheme.errorContainer.withValues(alpha: 0.35),
          'unreadable',
        ),
      FieldState.absent => (theme.colorScheme.outline, null, 'not on form'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(
              child: Text(spec.label,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (spec.required)
              Text(' *', style: TextStyle(color: theme.colorScheme.error)),
            const Spacer(),
            if (badge.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(badge,
                    style: theme.textTheme.labelSmall?.copyWith(color: accent)),
              ),
            if (state == FieldState.ok) ...[
              Icon(Icons.check_circle, size: 15, color: accent),
              const SizedBox(width: 4),
              Text('${(extracted.confidence * 100).round()}%',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
          const SizedBox(height: 8),
          if (spec.type == FieldType.choice && (spec.options?.isNotEmpty ?? false))
            _ChoiceInput(
              options: spec.options!,
              controller: controller,
              onChanged: onChanged,
            )
          else
            TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              maxLines: spec.type == FieldType.longtext ? 2 : 1,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: const OutlineInputBorder(),
                suffixText: _isDate ? 'dd/mm/yyyy' : null,
                suffixStyle: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                hintText: switch (state) {
                  FieldState.absent => _isDate
                      ? 'Not on the form — dd/mm/yyyy'
                      : 'Not on the form — type it in if you have it',
                  FieldState.illegible => _isDate
                      ? 'Could not be read — dd/mm/yyyy'
                      : 'Could not be read — type it in',
                  _ => null,
                },
              ),
            ),
          // Spell the date out. "10/03/2014" and "03/10/2014" look almost
          // identical at a glance; "10 March 2014" cannot be misread.
          if (_isDate) _DateEcho(controller: controller),
          // What the paper actually says, when it differs from the value.
          if (extracted.rawText != null &&
              extracted.rawText!.trim().isNotEmpty &&
              extracted.rawText != extracted.value) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.edit_note, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Expanded(
                child: Text('on the form: "${extracted.rawText}"',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic)),
              ),
            ]),
          ],
          for (final issue in issues) ...[
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                issue.isError ? Icons.error_outline : Icons.warning_amber_rounded,
                size: 14,
                color: issue.isError ? theme.colorScheme.error : _amber,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(issue.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                issue.isError ? theme.colorScheme.error : _amber)),
                    if (issue.suggestion != null)
                      Text(issue.suggestion!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// Choice fields get buttons rather than free text, so a reviewer can't
/// reintroduce the very mismatch the template exists to prevent.
class _ChoiceInput extends StatelessWidget {
  const _ChoiceInput({
    required this.options,
    required this.controller,
    required this.onChanged,
  });

  final List<String> options;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final current = controller.text.trim();
    final known = options.contains(current);

    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final o in options)
        ChoiceChip(
          label: Text(o),
          selected: current == o,
          onSelected: (_) {
            controller.text = o;
            onChanged();
          },
        ),
      if (current.isNotEmpty && !known)
        InputChip(
          avatar: Icon(Icons.warning_amber_rounded,
              size: 16, color: Theme.of(context).colorScheme.error),
          label: Text('"$current"'),
          onDeleted: () {
            controller.text = '';
            onChanged();
          },
        ),
    ]);
  }
}

class _DateEcho extends StatelessWidget {
  const _DateEcho({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = controller.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final iso = Dates.displayToIso(text);
    if (iso == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 5),
          Text('Not a valid date',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ]),
      );
    }
    final d = DateTime.parse(iso);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(Icons.event_available, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text('${d.day} ${ReviewFieldRow._months[d.month - 1]} ${d.year}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
