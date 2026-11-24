import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'history_screen.dart' show shortDate;
import 'live_screen.dart' show askNumber;
import 'view_models.dart';

class DetailSet {
  const DetailSet({
    required this.loadG,
    required this.reps,
    this.skipped = false,
    this.timed = false,
    this.setId = '',
  });

  /// The stored set's id (edits address sets by it).
  final String setId;
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
    this.uuid = '',
    this.edited = false,
  });
  final String uuid;

  /// Edited after it was logged (`edited_at_ms` set).
  final bool edited;
  final WorkoutType? type;
  final DateTime startedAt;
  final String gymName;
  final int durationS;
  final double volumeKg;
  final List<DetailLift> lifts;

  int get setCount =>
      lifts.fold(0, (a, l) => a + l.sets.where((s) => !s.skipped).length);

  /// Every stored set, skipped ones too.
  int get storedSetCount => lifts.fold(0, (a, l) => a + l.sets.length);
}

const _danger = Color(0xFFB3261E);

/// "Delete this workout?" True when he confirms. Shared by the detail screen
/// and the long-press on a history row.
Future<bool> askDeleteWorkout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this workout?'),
      content: const Text(
        'It leaves your history and your stats. You can undo for 10 seconds.',
      ),
      actions: [
        TextButton(
          key: const Key('delete.keep'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep it'),
        ),
        TextButton(
          key: const Key('delete.confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: _danger),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}

enum _SetAction { reps, load, remove }

/// One finished workout from history (review P2: rows did not open; the
/// only way to see old numbers was "Last time" mid-workout).
class WorkoutDetailScreen extends StatelessWidget {
  const WorkoutDetailScreen({
    super.key,
    required this.view,
    this.onDelete,
    this.onEditSet,
    this.onRemoveSet,
  });
  final WorkoutDetailView view;

  /// Delete the workout (asked for here, confirmed here). Null: read-only.
  final VoidCallback? onDelete;

  /// One set's new load (grams, null = none) and reps. Null: read-only.
  final void Function(String setId, int? loadG, int reps)? onEditSet;

  /// Remove one set (confirmed here).
  final void Function(String setId)? onRemoveSet;

  bool get _editable => onEditSet != null || onRemoveSet != null;

  Future<void> _editSet(
    BuildContext context,
    DetailLift lift,
    int index,
  ) async {
    final s = lift.sets[index];
    final canValues =
        onEditSet != null && !s.skipped && !s.timed && s.reps != null;
    final canLoad =
        canValues && (lift.unit == LoadUnit.kg || lift.unit == LoadUnit.kgEach);
    final action = await showModalBottomSheet<_SetAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '${lift.name.toUpperCase()} · SET ${index + 1}',
                  style: LitType.display(26),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  _setText(s, lift.unit),
                  style: LitType.body(15, Lit.inkSecondary, FontWeight.w600),
                ),
              ),
              if (canValues)
                ListTile(
                  key: const Key('edit.reps'),
                  minTileHeight: 56,
                  title: const Text('Change reps'),
                  onTap: () => Navigator.of(ctx).pop(_SetAction.reps),
                ),
              if (canLoad)
                ListTile(
                  key: const Key('edit.load'),
                  minTileHeight: 56,
                  title: const Text('Change load'),
                  onTap: () => Navigator.of(ctx).pop(_SetAction.load),
                ),
              if (onRemoveSet != null)
                ListTile(
                  key: const Key('edit.remove'),
                  minTileHeight: 56,
                  title: const Text(
                    'Remove set',
                    style: TextStyle(color: _danger),
                  ),
                  onTap: () => Navigator.of(ctx).pop(_SetAction.remove),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _SetAction.reps:
        final v = await askNumber(
          context,
          title: 'Reps',
          unit: 'reps',
          initial: s.reps,
          max: 200,
        );
        if (v != null && v >= 1) onEditSet!(s.setId, s.loadG, v.round());
      case _SetAction.load:
        final v = await askNumber(
          context,
          title: 'Load',
          unit: lift.unit == LoadUnit.kgEach ? 'kg ea' : 'kg',
          initial: s.loadG == null ? null : s.loadG! / 1000,
          decimals: true,
          max: 500,
        );
        if (v != null) onEditSet!(s.setId, (v * 1000).round(), s.reps!);
      case _SetAction.remove:
        await _confirmRemove(context, lift, index);
    }
  }

  Future<void> _confirmRemove(
    BuildContext context,
    DetailLift lift,
    int index,
  ) async {
    final s = lift.sets[index];
    // Removing the last LOGGED set (skipped sets do not count) would leave a
    // workout with nothing logged: offer Delete instead.
    final loggedLeft = view.setCount - (s.skipped ? 0 : 1);
    final only = loggedLeft == 0 && onDelete != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(only ? 'Delete this workout?' : 'Remove set ${index + 1}?'),
        content: Text(
          only
              ? 'It is the last logged set, so removing it would leave a '
                    'workout with nothing logged. You can undo for 10 seconds.'
              : '${lift.name}, ${_setText(s, lift.unit)}. The later sets of '
                    'this lift renumber.',
        ),
        actions: [
          TextButton(
            key: const Key('remove.keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('remove.confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: _danger),
            child: Text(only ? 'Delete workout' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (only) {
      onDelete!();
    } else {
      onRemoveSet!(s.setId);
    }
  }

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
        actions: [
          if (onDelete != null)
            PopupMenuButton<String>(
              key: const Key('detail.menu'),
              tooltip: 'More',
              onSelected: (_) async {
                if (await askDeleteWorkout(context)) onDelete!();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  key: Key('detail.delete'),
                  value: 'delete',
                  child: Text('Delete workout'),
                ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(
            '${shortDate(view.startedAt)} · ${view.gymName}'
            '${view.edited ? ' · edited' : ''}',
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
          for (final l in view.lifts)
            _LiftBlock(
              lift: l,
              onTapSet: _editable ? (i) => _editSet(context, l, i) : null,
            ),
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

String _setText(DetailSet s, LoadUnit unit) {
  if (s.skipped) return 'skipped';
  final work = s.timed ? clock(s.reps ?? 0) : '${s.reps ?? 0}';
  final load = loadLabel(s.loadG, unit);
  if (s.timed) return load.isEmpty ? work : '$work · $load';
  return load.isEmpty ? '$work reps' : '$work × $load';
}

class _LiftBlock extends StatelessWidget {
  const _LiftBlock({required this.lift, this.onTapSet});
  final DetailLift lift;

  /// Index of the tapped set; null = read-only rows.
  final ValueChanged<int>? onTapSet;

  String _set(DetailSet s) => _setText(s, lift.unit);

  Widget _row(int i) {
    final s = lift.sets[i];
    final row = Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '${i + 1}',
            style: LitType.body(14, Lit.inkQuiet, FontWeight.w700),
          ),
        ),
        Expanded(
          child: Text(
            _set(s).toUpperCase(),
            style: LitType.display(24, s.skipped ? Lit.inkQuiet : Lit.ink),
          ),
        ),
        if (onTapSet != null)
          const Icon(Icons.edit_outlined, size: 18, color: Lit.inkQuiet),
      ],
    );
    final tap = onTapSet;
    if (tap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      );
    }
    return Semantics(
      button: true,
      label: '${lift.name}, set ${i + 1}, ${_set(s)}, edit',
      excludeSemantics: true,
      onTap: () => tap(i),
      child: InkWell(
        key: Key('set.${s.setId.isEmpty ? '$i' : s.setId}'),
        onTap: () => tap(i),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(alignment: Alignment.centerLeft, child: row),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final block = Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Lit.hair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lift.name, style: LitType.body(17, Lit.ink, FontWeight.w800)),
          const SizedBox(height: 6),
          for (var i = 0; i < lift.sets.length; i++) _row(i),
        ],
      ),
    );
    // Read-only: one label per lift. Editable: each set row is its own button.
    if (onTapSet != null) return block;
    return Semantics(
      label:
          '${lift.name}: '
          '${[for (var i = 0; i < lift.sets.length; i++) 'set ${i + 1} ${_set(lift.sets[i])}'].join(', ')}',
      excludeSemantics: true,
      child: block,
    );
  }
}
