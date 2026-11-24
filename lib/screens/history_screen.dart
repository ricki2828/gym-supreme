import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'view_models.dart';

class HistoryRowView {
  const HistoryRowView({
    required this.uuid,
    required this.startedAt,
    required this.gymName,
    required this.type,
    required this.durationS,
    required this.volumeKg,
    required this.setCount,
  });
  final String uuid;

  /// Local wall time of the start (UTC plus the stored offset).
  final DateTime startedAt;
  final String gymName;
  final WorkoutType? type;
  final int durationS;
  final double volumeKg;
  final int setCount;
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Tue 24 Nov".
String shortDate(DateTime d) =>
    '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

/// Finished workouts, newest first (plan item 6 list).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.rows, this.onOpen});
  final List<HistoryRowView> rows;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: rows.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('HISTORY', style: LitType.display(48)),
                    const SizedBox(height: 12),
                    Text(
                      'Nothing logged yet. Your first session shows up here '
                      'when you finish it.',
                      style: LitType.body(16, Lit.inkSecondary),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                itemCount: rows.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('HISTORY', style: LitType.display(48)),
                    );
                  }
                  return HistoryRowTile(row: rows[i - 1], onOpen: onOpen);
                },
              ),
      ),
    );
  }
}

class HistoryRowTile extends StatelessWidget {
  const HistoryRowTile({super.key, required this.row, this.onOpen});
  final HistoryRowView row;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    final type = row.type;
    final label = type?.label ?? 'Mixed';
    final volume = row.volumeKg.round();
    return Semantics(
      button: onOpen != null,
      label:
          '$label, ${shortDate(row.startedAt)}, ${row.gymName}, '
          '${row.durationS ~/ 60} minutes, ${row.setCount} sets, $volume kilograms',
      excludeSemantics: true,
      onTap: onOpen == null ? null : () => onOpen!(row.uuid),
      child: InkWell(
        onTap: onOpen == null ? null : () => onOpen!(row.uuid),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Lit.hair)),
          ),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 44,
                decoration: BoxDecoration(
                  color: type?.colour ?? Lit.ink,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label.toUpperCase(), style: LitType.display(28)),
                    Text(
                      '${shortDate(row.startedAt)} · ${row.gymName}',
                      style: LitType.body(14, Lit.inkSecondary),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${thousands(volume)} KG', style: LitType.display(24)),
                  Text(
                    '${row.setCount} sets · ${clock(row.durationS)}',
                    style: LitType.body(14, Lit.inkSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "LEGS, LIFT 3 OF 6 · Paused Sunday. Pick it up at set 2." (b-home).
/// Shown when a journal exists on open that is not yet stored (plan 7).
class ResumeCard extends StatelessWidget {
  const ResumeCard({
    super.key,
    required this.type,
    required this.lift,
    required this.lifts,
    required this.set,
    required this.pausedWhen,
    this.finishedUnsaved = false,
    this.onResume,
    this.onDiscard,
  });
  final WorkoutType? type;
  final int lift, lifts, set;

  /// "Sunday", "today", "an hour ago": composed by the caller.
  final String pausedWhen;

  /// Finished (e.g. from the lock screen) but not saved yet: Resume saves it.
  final bool finishedUnsaved;
  final VoidCallback? onResume;

  /// Throws the workout away (the caller confirms first).
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final colour = type?.colour ?? Lit.hair;
    final ink = type?.onColour ?? Lit.ink;
    final name = (type?.label ?? 'Session').toUpperCase();
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 14, 16),
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$name, LIFT $lift OF $lifts',
                    style: LitType.display(36, ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    finishedUnsaved
                        ? 'Finished but not saved yet. Resume to save it.'
                        : 'Paused $pausedWhen. Pick it up at set $set.',
                    style: LitType.body(15, ink, FontWeight.w600),
                  ),
                  if (onDiscard != null)
                    TextButton(
                      onPressed: onDiscard,
                      style: TextButton.styleFrom(
                        foregroundColor: ink,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 40),
                      ),
                      child: Text(
                        'Discard workout',
                        style: LitType.body(14, ink, FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            BigButton(
              label: 'Resume',
              colour: Lit.ink,
              ink: Colors.white,
              width: 120,
              height: 56,
              fontSize: 26,
              onTap: onResume,
            ),
          ],
        ),
      ),
    );
  }
}
