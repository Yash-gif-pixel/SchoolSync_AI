import 'package:flutter/material.dart';

import '../core/dates.dart';
import '../models/document_template.dart';
import '../models/extracted_document.dart';
import '../theme/app_theme.dart';
import 'ui/primitives.dart';

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

    final (Tone tone, String badge) = switch (state) {
      FieldState.ok => (Tone.success, ''),
      FieldState.review =>
        (hasError ? Tone.danger : Tone.warning, hasError ? 'must fix' : 'check this'),
      FieldState.illegible => (Tone.danger, 'unreadable'),
      FieldState.absent => (Tone.neutral, 'not on form'),
    };

    // Only tint the row when it needs a human. A page where every field is
    // coloured tells the reviewer nothing about where to look.
    final needsAttention =
        state == FieldState.review || state == FieldState.illegible;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: needsAttention ? tone.bg : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: needsAttention
              ? tone.fg.withValues(alpha: 0.3)
              : AppColors.border,
        ),
      ),
      child: Stack(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpace.lg, AppSpace.md, AppSpace.md, AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(spec.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge),
                ),
                if (spec.required)
                  const Text(' *', style: TextStyle(color: AppColors.danger)),
                const Spacer(),
                if (badge.isNotEmpty)
                  StatusPill(label: badge, tone: tone)
                else
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle, size: 14, color: tone.fg),
                    const SizedBox(width: 4),
                    Text('${(extracted.confidence * 100).round()}%',
                        style: theme.textTheme.labelSmall),
                  ]),
              ]),
              const SizedBox(height: AppSpace.sm),

              if (spec.type == FieldType.choice &&
                  (spec.options?.isNotEmpty ?? false))
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
                    suffixText: _isDate ? 'dd/mm/yyyy' : null,
                    suffixStyle: theme.textTheme.labelSmall,
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
                  const Icon(Icons.edit_note,
                      size: 14, color: AppColors.textTertiary),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text('on the form: "${extracted.rawText}"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                  ),
                ]),
              ],

              for (final issue in issues) ...[
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    issue.isError
                        ? Icons.error_outline
                        : Icons.warning_amber_rounded,
                    size: 14,
                    color: issue.isError ? AppColors.danger : AppColors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(issue.message,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: issue.isError
                                    ? AppColors.danger
                                    : AppColors.warning)),
                        if (issue.suggestion != null)
                          Text(issue.suggestion!,
                              style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 3,
          child: ColoredBox(color: tone.fg),
        ),
      ]),
    );
  }
}

/// Choice fields get buttons rather than free text, so a reviewer cannot
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

    return Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: [
      for (final o in options)
        ChoiceChip(
          label: Text(o),
          selected: current == o,
          showCheckmark: false,
          selectedColor: AppColors.brandTint,
          onSelected: (_) {
            controller.text = o;
            onChanged();
          },
        ),
      if (current.isNotEmpty && !known)
        InputChip(
          avatar: const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColors.danger),
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
          const Icon(Icons.error_outline, size: 14, color: AppColors.danger),
          const SizedBox(width: 5),
          Text('Not a valid date',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.danger)),
        ]),
      );
    }
    final d = DateTime.parse(iso);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        const Icon(Icons.event_available,
            size: 14, color: AppColors.textTertiary),
        const SizedBox(width: 5),
        Text('${d.day} ${ReviewFieldRow._months[d.month - 1]} ${d.year}',
            style: theme.textTheme.labelSmall),
      ]),
    );
  }
}
