import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/body_map.dart';
import '../widgets/lit_widgets.dart';
import 'view_models.dart';

/// "Light up what?": the muscle picker with days-since and the suggested
/// session sheet (b2-picker.png, approved M1; states s1-s6).
///
/// Stateless over its inputs: the parent owns the selection and asks the
/// engine for [plan] whenever it changes.
class PickerScreen extends StatelessWidget {
  const PickerScreen({
    super.key,
    required this.gym,
    required this.days,
    required this.selected,
    required this.plan,
    this.restNote,
    this.onToggleGroup,
    this.onReorder,
    this.onStart,
    this.onClose,
    this.onGymTap,
  });

  final GymView gym;

  /// Muscle id to days-since. Every one of the 16 should be present.
  final Map<String, MuscleDays> days;

  /// Chosen muscle ids.
  final Set<String> selected;

  /// The suggestion for [selected]; null or empty when nothing is picked.
  final SessionPlanView? plan;

  /// One line of the day's story ("Legs trained yesterday, so they rest.").
  final String? restNote;

  final ValueChanged<MuscleGroup>? onToggleGroup;
  final void Function(int from, int to)? onReorder;
  final VoidCallback? onStart;
  final VoidCallback? onClose;
  final VoidCallback? onGymTap;

  bool get _firstRun => days.values.every((d) => d.days == null);

  bool get _allResting =>
      !_firstRun && days.values.every((d) => d.resting || d.uncovered);

  Color get _pickColour => plan?.type?.colour ?? Lit.ink;
  Color get _onPick => plan?.type?.onColour ?? Colors.white;

  MuscleGroup? _groupOf(String muscleId) {
    for (final g in MuscleGroup.picker) {
      if (g.muscleIds.contains(muscleId)) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final big = MediaQuery.textScalerOf(context).scale(10) > 12.5;
    final fills = {for (final m in selected) m: _pickColour};
    final resting = {
      for (final e in days.entries)
        if (e.value.resting && !selected.contains(e.key)) e.key,
    };
    final noKit = {
      for (final e in days.entries)
        if (e.value.uncovered) e.key,
    };
    final subtitle = _firstRun
        ? 'No history yet. Pick anything. You set each weight on its first set.'
        : ['Tap a row or the body. Filled means in.', ?restNote].join(' ');

    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in MuscleGroup.picker) ...[
          _GroupRow(
            group: g,
            days: [for (final m in g.muscleIds) days[m] ?? const MuscleDays()],
            on: g.muscleIds.every(selected.contains),
            pickColour: _pickColour,
            onPick: _onPick,
            onTap: onToggleGroup == null ? null : () => onToggleGroup!(g),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );

    final body = BodyMap(
      fills: fills,
      resting: resting,
      noKit: noKit,
      width: big ? 150 : 176,
      onTapMuscle: onToggleGroup == null
          ? null
          : (id) {
              final g = _groupOf(id);
              if (g != null) onToggleGroup!(g);
            },
      semanticLabel: selected.isEmpty
          ? 'Body map. Nothing picked.'
          : 'Body map. ${selected.length} muscles picked.',
    );

    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(20, 20, 20, big ? 140 : 380),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'LIGHT UP WHAT?',
                        style: LitType.display(48),
                        semanticsLabel: 'Light up what?',
                      ),
                    ),
                    IconButton(
                      onPressed: onClose,
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, size: 30, color: Lit.ink),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: LitType.body(14, Lit.inkSecondary)),
                if (_allResting) ...[
                  const SizedBox(height: 10),
                  _InkNote(_restingNote()),
                ],
                const SizedBox(height: 10),
                if (big) ...[
                  Center(child: body),
                  const SizedBox(height: 12),
                  rows,
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Column(
                          children: [
                            body,
                            const SizedBox(height: 6),
                            Text(
                              'days since last trained →',
                              style: LitType.body(
                                11,
                                Lit.inkSecondary,
                                FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: rows),
                    ],
                  ),
              ],
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: big ? _peek(context) : _sheet(),
            ),
          ],
        ),
      ),
    );
  }

  String _restingNote() {
    final ranked = [
      for (final g in MuscleGroup.picker)
        (g, g.muscleIds.map((m) => days[m]?.days ?? 999).reduce(_min)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return 'Nearly everything trained in the last 2 days. '
        '${ranked.first.$1.label} is the most rested.';
  }

  void _openPlan(BuildContext context) {
    final p = plan;
    if (p == null || p.items.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SingleChildScrollView(child: _sheet()),
    );
  }

  Widget _peek(BuildContext context) {
    final p = plan;
    final has = p != null && p.items.isNotEmpty;
    return GestureDetector(
      onTap: () => _openPlan(context),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < 0) _openPlan(context);
      },
      child: _peekBody(p, has),
    );
  }

  Widget _peekBody(SessionPlanView? p, bool has) {
    return DarkSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Lit.inkQuiet,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      has
                          ? '${p!.items.length} LIFTS · ${p.minutes} MIN'
                          : 'NOTHING PICKED',
                      style: LitType.display(30, Colors.white),
                    ),
                    Text(
                      has
                          ? 'Swipe up or tap to see them'
                          : 'Pick one muscle or more',
                      style: LitType.body(13, const Color(0xFFA5A9B1)),
                    ),
                  ],
                ),
              ),
              BigButton(
                label: 'START',
                colour: has ? _pickColour : const Color(0xFF2A2D33),
                ink: has ? _onPick : Lit.inkQuiet,
                onTap: has ? onStart : null,
                height: 56,
                width: 100,
                fontSize: 28,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sheet() {
    final p = plan;
    if (p == null || p.items.isEmpty) {
      final rested = [
        for (final g in MuscleGroup.picker)
          (g.label, g.muscleIds.map((m) => days[m]?.days ?? 999).reduce(_min)),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return DarkSheet(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHead('NOTHING PICKED'),
            const SizedBox(height: 8),
            Text(
              'Pick one muscle or more and a session appears here. '
              'Most rested right now: '
              '${rested.take(3).map((r) => r.$1.toLowerCase()).join(', ')}.',
              style: LitType.body(14, const Color(0xFFA5A9B1)),
            ),
            const SizedBox(height: 14),
            const BigButton(
              label: 'PICK A MUSCLE',
              colour: Color(0xFF2A2D33),
              ink: Lit.inkQuiet,
              onTap: null,
            ),
          ],
        ),
      );
    }
    final weighted = [
      for (final i in p.items)
        if (i.unit == LoadUnit.kg || i.unit == LoadUnit.kgEach) i,
    ];
    final cold = weighted.isNotEmpty && weighted.every((i) => i.loadG == null);
    final note = [
      if (cold) 'First time on every lift. Start light; the app remembers what you used.',
      if (p.uncovered.isNotEmpty)
        '${p.uncovered.join(', ')} ${p.uncovered.length == 1 ? 'is' : 'are'} '
            'left out: nothing here can train '
            '${p.uncovered.length == 1 ? 'it' : 'them'}. Add kit in Gyms.',
      if (_allResting) 'Or tap any resting row to train it anyway.',
    ];
    return DarkSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHead('${p.items.length} LIFTS · ${p.minutes} MIN'),
          const SizedBox(height: 4),
          PlanList(items: p.items, onReorder: onReorder, dark: true),
          for (final n in note)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(n, style: LitType.body(13, const Color(0xFFA5A9B1))),
            ),
          const SizedBox(height: 12),
          BigButton(
            label: p.type == null
                ? 'START'
                : 'START ${p.type!.label.toUpperCase()}',
            colour: _pickColour,
            ink: _onPick,
            onTap: onStart,
          ),
        ],
      ),
    );
  }

  Widget _sheetHead(String title) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(child: Text(title, style: LitType.display(30, Colors.white))),
      GymChip(name: gym.name, onTap: onGymTap, dark: true),
    ],
  );
}

int _min(int a, int b) => a < b ? a : b;

class _InkNote extends StatelessWidget {
  const _InkNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Lit.ink,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: LitType.body(13, Colors.white, FontWeight.w600)),
  );
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.days,
    required this.on,
    required this.pickColour,
    required this.onPick,
    this.onTap,
  });
  final MuscleGroup group;
  final List<MuscleDays> days;
  final bool on;
  final Color pickColour;
  final Color onPick;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final noKit = days.every((d) => d.uncovered);
    final resting = !noKit && days.any((d) => d.resting);
    final known = [for (final d in days) ?d.days];
    // The most recently trained muscle in the group sets its days-since.
    final int? since = known.isEmpty ? null : known.reduce(_min);
    final quiet = (resting || noKit) && !on;
    final String note = noKit
        ? 'NO KIT HERE'
        : since == null
        ? 'NEW'
        : resting
        ? '${daysLabel(since).toUpperCase()} · RESTING'
        : daysLabel(since).toUpperCase();
    final fg = on ? onPick : (quiet ? Lit.inkQuiet : Lit.ink);
    final border = on
        ? Lit.ink
        : quiet
        ? const Color(0xFFC9CCC5)
        : Lit.ink;

    final semantics = [
      group.label,
      if (noKit)
        'no kit at this gym'
      else if (since == null)
        'not trained yet'
      else
        '${daysLabel(since)} since trained',
      if (resting) 'resting',
      on ? 'picked' : 'not picked',
    ].join(', ');

    return Semantics(
      button: true,
      selected: on,
      label: semantics,
      excludeSemantics: true,
      child: Material(
        color: on ? pickColour : (noKit ? Lit.ground : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border, width: 1.5),
        ),
        child: InkWell(
          onTap: noKit ? null : onTap,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  if (on) ...[
                    Icon(Icons.check, size: 15, color: fg),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      group.label,
                      style: LitType.body(13, fg, FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(note, style: LitType.display(19, fg)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
