import 'package:flutter/material.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'engine_adapter.dart' show unitOf;
import 'live_screen.dart' show askNumber;
import 'view_models.dart';

/// One lift on the starting-weights screen (0.3 S1).
class StartingWeightRow {
  const StartingWeightRow({
    required this.exerciseId,
    required this.name,
    required this.unit,
    required this.section,
    this.loadG,
    this.hasHistory = false,
  });

  factory StartingWeightRow.of(eng.StartingWeightLift l) => StartingWeightRow(
    exerciseId: l.exerciseId,
    name: l.name,
    unit: unitOf(l.unit),
    section: eng.workoutType(l.typeId)?.name ?? 'More lifts',
    loadG: l.loadG,
    hasHistory: l.hasHistory,
  );

  final String exerciseId;
  final String name;

  /// kg or kg each (dumbbells, per hand).
  final LoadUnit unit;

  /// Heading it is listed under: Push, Pull, Legs, Core or More lifts.
  final String section;
  final int? loadG;

  /// Already logged: history drives it, the starting weight waits unused.
  final bool hasHistory;
}

/// Starting weights (0.3 S1): type what he lifts now, once per lift, so the
/// first session of each lift is not blank. Never a workout: no PB, streak
/// or history. Reached from the Gyms tab and from an empty Today.
class StartingWeightsScreen extends StatelessWidget {
  const StartingWeightsScreen({
    super.key,
    required this.rows,
    this.onEdit,
    this.onClear,
  });

  final List<StartingWeightRow> rows;

  /// Tap a lift: type its weight.
  final ValueChanged<String>? onEdit;

  /// Clear a lift's starting weight.
  final ValueChanged<String>? onClear;

  @override
  Widget build(BuildContext context) {
    final sections = <String, List<StartingWeightRow>>{};
    for (final r in rows) {
      sections.putIfAbsent(r.section, () => []).add(r);
    }
    final set = rows.where((r) => r.loadG != null).length;
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        foregroundColor: Lit.ink,
        title: Text(
          'STARTING WEIGHTS',
          style: LitType.display(30),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('start.list'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              'What you lift now, once per lift. Your first session of a '
              'lift starts there; after you log it, your history takes '
              'over. Not a workout: no PBs, no streak.',
              style: LitType.body(15, Lit.inkSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              '$set of ${rows.length} set',
              key: const Key('start.count'),
              style: LitType.body(14, Lit.inkQuiet, FontWeight.w600),
            ),
            if (rows.isEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'No loaded lifts at this gym yet. Tick its kit in Gyms first.',
                style: LitType.body(15, Lit.ink),
              ),
            ],
            for (final s in sections.entries) ...[
              const SizedBox(height: 18),
              Text(s.key.toUpperCase(), style: LitType.display(30)),
              const SizedBox(height: 4),
              for (final r in s.value)
                _LiftTile(
                  row: r,
                  onTap: onEdit == null ? null : () => onEdit!(r.exerciseId),
                  onClear: onClear == null || r.loadG == null
                      ? null
                      : () => onClear!(r.exerciseId),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LiftTile extends StatelessWidget {
  const _LiftTile({required this.row, this.onTap, this.onClear});
  final StartingWeightRow row;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final value = row.loadG == null
        ? 'Not set'
        : loadLabel(row.loadG, row.unit);
    final note = row.hasHistory ? 'Logged already: your history is used' : null;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: onTap != null,
            label: '${row.name}, $value${note == null ? '' : '. $note'}',
            onTapHint: 'type a starting weight',
            onTap: onTap,
            excludeSemantics: true,
            child: InkWell(
              key: Key('start.row.${row.exerciseId}'),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        row.name,
                        style: LitType.body(16, Lit.ink, FontWeight.w700),
                      ),
                      Text(
                        value,
                        key: Key('start.value.${row.exerciseId}'),
                        style: LitType.body(
                          15,
                          row.loadG == null ? Lit.inkQuiet : Lit.ink,
                          FontWeight.w600,
                        ),
                      ),
                      if (note != null)
                        Text(note, style: LitType.body(13, Lit.inkSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onClear != null)
          IconButton(
            key: Key('start.clear.${row.exerciseId}'),
            tooltip: 'Clear ${row.name}',
            icon: const Icon(Icons.close),
            color: Lit.ink,
            onPressed: onClear,
          ),
      ],
    );
  }
}

/// The screen wired to the engine: every change is one
/// [eng.GymApi.setStartingWeight], then [persist] (the backup snapshot).
class StartingWeightsFlow extends StatefulWidget {
  const StartingWeightsFlow({
    super.key,
    required this.engine,
    required this.gymId,
    this.persist,
  });

  final eng.GymApi engine;
  final String gymId;
  final VoidCallback? persist;

  @override
  State<StartingWeightsFlow> createState() => _StartingWeightsFlowState();
}

class _StartingWeightsFlowState extends State<StartingWeightsFlow> {
  late List<StartingWeightRow> _rows = _read();

  List<StartingWeightRow> _read() => [
    for (final l in widget.engine.startingWeightLifts(gymId: widget.gymId))
      StartingWeightRow.of(l),
  ];

  void _save(String id, int? loadG) {
    try {
      widget.engine.setStartingWeight(id, loadG);
    } on Object catch (e) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not save: ${e.runtimeType}.')),
      );
      return;
    }
    widget.persist?.call();
    setState(() => _rows = _read());
  }

  Future<void> _edit(String id) async {
    final row = _rows.firstWhere((r) => r.exerciseId == id);
    final v = await askNumber(
      context,
      title: row.name,
      unit: row.unit == LoadUnit.kgEach ? 'kg ea' : 'kg',
      decimals: true,
      initial: row.loadG == null ? null : row.loadG! / 1000,
      max: eng.startingWeightMaxG / 1000,
    );
    if (v == null || !mounted) return;
    final g = (v * 1000).round();
    // 0 (or a value that rounds to it) clears, like the clear button.
    _save(id, g <= 0 ? null : g);
  }

  @override
  Widget build(BuildContext context) => StartingWeightsScreen(
    rows: _rows,
    onEdit: _edit,
    onClear: (id) => _save(id, null),
  );
}
