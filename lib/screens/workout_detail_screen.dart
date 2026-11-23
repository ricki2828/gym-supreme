import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'history_screen.dart' show shortDate;
import 'view_models.dart';

class DetailSet {
  const DetailSet({
    required this.loadG,
    required this.reps,
    this.skipped = false,
    this.timed = false,
  });
  final int? loadG;

  /// Reps, or seconds when [timed].
  final int? reps;
  final bool skipped;
  final bool timed;
}

class DetailLift {
  const DetailLift({
    required this.name,
    required this.unit,
    required this.sets,
  });
  final String name;
  final LoadUnit unit;
  final List<DetailSet> sets;
}

class WorkoutDetailView {
  const WorkoutDetailView({
    required this.type,
    required this.startedAt,
    required this.gymName,
    required this.durationS,
    required this.volumeKg,
    required this.lifts,
  });
  final WorkoutType? type;
  final DateTime startedAt;
  final String gymName;
  final int durationS;
  final double volumeKg;
  final List<DetailLift> lifts;

  int get setCount =>
      lifts.fold(0, (a, l) => a + l.sets.where((s) => !s.skipped).length);
}

/// One finished workout from history (review P2: rows did not open; the
/// only way to see old numbers was "Last time" mid-workout).
class WorkoutDetailScreen extends StatelessWidget {
  const WorkoutDetailScreen({super.key, required this.view});
  final WorkoutDetailView view;

  @override
  Widget build(BuildContext context) {
    final type = view.type;
    final label = (type?.label ?? 'Mixed').toUpperCase();
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: type?.colour ?? Lit.ground,
        foregroundColor: type?.onColour ?? Lit.ink,
        title: Text(
          label,
          style: LitType.display(32, type?.onColour ?? Lit.ink),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(
            '${shortDate(view.startedAt)} · ${view.gymName}',
            style: LitType.body(16, Lit.inkSecondary, FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 28,
            runSpacing: 8,
            children: [
              _Stat('${thousands(view.volumeKg.round())} KG', 'volume'),
              _Stat('${view.setCount}', 'sets'),
              _Stat(clock(view.durationS), 'time'),
            ],
          ),
          const SizedBox(height: 18),
          if (view.lifts.isEmpty)
            Text(
              'No sets were logged in this workout.',
              style: LitType.body(15, Lit.inkSecondary),
            ),
          for (final l in view.lifts) _LiftBlock(lift: l),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: LitType.display(36)),
      Text(label, style: LitType.body(14, Lit.inkSecondary)),
    ],
  );
}

class _LiftBlock extends StatelessWidget {
  const _LiftBlock({required this.lift});
  final DetailLift lift;

  String _set(DetailSet s) {
    if (s.skipped) return 'skipped';
    final work = s.timed ? clock(s.reps ?? 0) : '${s.reps ?? 0}';
    final load = loadLabel(s.loadG, lift.unit);
    if (s.timed) return load.isEmpty ? work : '$work · $load';
    return load.isEmpty ? '$work reps' : '$work × $load';
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${lift.name}: '
        '${[for (var i = 0; i < lift.sets.length; i++) 'set ${i + 1} ${_set(lift.sets[i])}'].join(', ')}',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Lit.hair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lift.name, style: LitType.body(17, Lit.ink, FontWeight.w800)),
          const SizedBox(height: 6),
          for (var i = 0; i < lift.sets.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}',
                      style: LitType.body(14, Lit.inkQuiet, FontWeight.w700),
                    ),
                  ),
                  Text(
                    _set(lift.sets[i]).toUpperCase(),
                    style: LitType.display(
                      24,
                      lift.sets[i].skipped ? Lit.inkQuiet : Lit.ink,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
