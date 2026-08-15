import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/operations_repository.dart';
import '../models/operations.dart';
import 'ui/primitives.dart';

/// File leave, and see what happened to earlier requests.
class LeaveCard extends ConsumerStatefulWidget {
  const LeaveCard({super.key});

  @override
  ConsumerState<LeaveCard> createState() => _LeaveCardState();
}

class _LeaveCardState extends ConsumerState<LeaveCard> {
  DateTimeRange? _range;
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _range ??
          DateTimeRange(
            start: now.add(const Duration(days: 1)),
            end: now.add(const Duration(days: 1)),
          ),
      helpText: 'Dates you will be away',
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _submit() async {
    final r = _range;
    if (r == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(operationsRepositoryProvider).fileLeave(
            from: r.start,
            to: r.end,
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
          );
      ref.invalidate(myLeaveProvider);
      setState(() {
        _range = null;
        _reason.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Leave request sent to your head of department.'),
        ));
      }
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(myLeaveProvider);
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.event_busy_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text('Leave', style: theme.textTheme.titleMedium),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _pickDates,
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(_range == null
                    ? 'Choose dates'
                    : _range!.start == _range!.end
                        ? _fmt(_range!.start)
                        : '${_fmt(_range!.start)} → ${_fmt(_range!.end)}'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _reason,
            enabled: !_saving,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Reason (optional)',
              hintText: 'Medical appointment',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: (_saving || _range == null) ? null : _submit,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send, size: 18),
              label: Text(_saving ? 'Sending…' : 'Request leave'),
            ),
          ),
          const Divider(height: 28),
          Text('Your requests', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          mine.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: SlowLoader(),
            ),
            error: (e, _) => Text('Could not load: $e',
                style: TextStyle(color: theme.colorScheme.error)),
            data: (list) => list.isEmpty
                ? Text('Nothing yet.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                : Column(children: [
                    for (final l in list.take(5)) _LeaveRow(leave: l),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _LeaveRow extends StatelessWidget {
  const _LeaveRow({required this.leave});
  final LeaveRequest leave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color colour, IconData icon) = leave.isApproved
        ? (Colors.green.shade600, Icons.check_circle)
        : leave.isRejected
            ? (theme.colorScheme.error, Icons.cancel)
            : (const Color(0xFFB26A00), Icons.hourglass_top);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, size: 16, color: colour),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(leave.dateRange,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            if (leave.reason != null)
              Text(leave.reason!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        Text(leave.statusLabel,
            style: theme.textTheme.labelSmall?.copyWith(color: colour)),
      ]),
    );
  }
}
