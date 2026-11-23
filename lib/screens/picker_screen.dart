import 'dart:math' as math;

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
    this.sheetExtra,
    this.minutes,
    this.onMinutes,
  });

  /// Cut-2 slot at the top of the session sheet (rotation "next up" chip).
  final Widget? sheetExtra;

  /// The session's time budget (30, 45 or 60); the engine fills or trims to
  /// it. Null hides the control.
  final int? minutes;
  final ValueChanged<int>? onMinutes;

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

  /// "Nearly everything" (s2): at least three in four muscles still resting.
  bool get _allResting =>
      !_firstRun &&
      days.isNotEmpty &&
      days.values.where((d) => d.resting).length * 4 >= days.length * 3;

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
              // Same rule as the rows: no kit here, not pickable (unless
              // already picked, so it can be dropped).
              if (g != null && (_pickable(g) || _isOn(g))) onToggleGroup!(g);
            },
      semanticLabel: selected.isEmpty
          ? 'Body map. Nothing picked.'
          : 'Body map. ${selected.length} muscles picked.',
    );

    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
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
                    // Large text has only the read-only peek, so the time
                    // budget lives here, in the live page (rebuilds with it).
                    if (onMinutes != null && minutes != null) ...[
                      const SizedBox(height: 12),
                      _MinutesChips(
                        value: minutes!,
                        onChanged: onMinutes!,
                        dark: false,
                      ),
                    ],
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
            ),
            if (big)
              _peek(context)
            else
              // Small phones (320x616 with a status bar): the sheet never
              // takes more than ~3/4 of the screen and scrolls past that, and
              // the plan list's own cap scales with the screen (ui-e2e, #42).
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.75,
                ),
                child: _sheet(
                  listCap: math.min(
                    300,
                    MediaQuery.sizeOf(context).height * 0.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _pickable(MuscleGroup g) =>
      !g.muscleIds.every((m) => days[m]?.uncovered ?? false);

  bool _isOn(MuscleGroup g) => g.muscleIds.every(selected.contains);

  /// Pickable groups, longest rested first (never trained counts as most).
  List<MuscleGroup> _mostRested() {
    final ranked = [
      for (final g in MuscleGroup.picker)
        if (_pickable(g))
          (g, g.muscleIds.map((m) => days[m]?.days ?? 999).reduce(_min)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final r in ranked) r.$1];
  }

  String _restingNote() {
    final top = _mostRested();
    return 'Nearly everything trained in the last 2 days.'
        '${top.isEmpty ? '' : ' ${top.first.label} is the most rested.'}';
  }

  void _openPlan(BuildContext context) {
    final p = plan;
    if (p == null || p.items.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // The modal captures this build's plan, so it is read-only: a reorder
      // here would index a stale list. Reordering stays on the live screen.
      builder: (modal) => SingleChildScrollView(
        child: _sheet(
          readOnly: true,
          onStartHere: onStart == null
              ? null
              : () {
                  Navigator.of(modal).pop();
                  onStart!();
                },
        ),
      ),
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

  Widget _sheet({
    bool readOnly = false,
    VoidCallback? onStartHere,
    double listCap = 300,
  }) {
    final p = plan;
    if (p == null || p.items.isEmpty) {
      final rested = _mostRested();
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
              '${rested.take(3).map((g) => g.label.toLowerCase()).join(', ')}.',
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
      if (readOnly) 'Reorder once you start.',
    ];
    final middle = <Widget>[
      ?sheetExtra,
      _sheetHead('${p.items.length} LIFTS · ${p.minutes} MIN'),
      // Not in the read-only peek: it shows a plan captured when it
      // opened, so a new budget there would start the old plan.
      if (!readOnly && onMinutes != null && minutes != null) ...[
        const SizedBox(height: 8),
        _MinutesChips(value: minutes!, onChanged: onMinutes!),
      ],
      const SizedBox(height: 4),
      PlanList(
        items: p.items,
        onReorder: readOnly ? null : onReorder,
        dark: true,
        // Many or long lifts scroll inside the sheet instead of overflowing.
        maxHeight: readOnly ? null : listCap,
      ),
      for (final n in note)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(n, style: LitType.body(13, const Color(0xFFA5A9B1))),
        ),
    ];
    final start = BigButton(
      label: p.type == null ? 'START' : 'START ${p.type!.label.toUpperCase()}',
      colour: _pickColour,
      ink: _onPick,
      onTap: readOnly ? onStartHere : onStart,
    );
    return DarkSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // On the page, the middle scrolls when the sheet hits its cap and
          // START stays pinned and visible. The peek modal scrolls as a whole
          // (unbounded height there, so no Flexible).
          if (readOnly)
            ...middle
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: middle,
                ),
              ),
            ),
          const SizedBox(height: 12),
          start,
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
      onTap: noKit && !on ? null : onTap,
      child: Material(
        color: on ? pickColour : (noKit ? Lit.ground : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border, width: 1.5),
        ),
        child: InkWell(
          onTap: noKit && !on ? null : onTap,
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
                  // Label keeps most of the row so names wrap at words;
                  // a long state ("TODAY · RESTING") scales down instead.
                  Expanded(
                    flex: 5,
                    child: Text(
                      group.label,
                      style: LitType.body(13, fg, FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 4,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(note, style: LitType.display(19, fg)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 30 / 45 / 60 minutes (review P1-4, t61 item 4: suggest(minutes:)).
class _MinutesChips extends StatelessWidget {
  const _MinutesChips({
    required this.value,
    required this.onChanged,
    this.dark = true,
  });
  final int value;
  final ValueChanged<int> onChanged;

  /// On the ink sheet (true) or the light page (false).
  final bool dark;
  static const options = [30, 45, 60];

  @override
  Widget build(BuildContext context) => Wrap(
    // Wraps on a narrow phone at large text instead of overflowing.
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 6,
    children: [
      Text(
        'Time',
        style: LitType.body(
          13,
          dark ? const Color(0xFFA5A9B1) : Lit.inkSecondary,
          FontWeight.w700,
        ),
      ),
      for (final m in options)
        Semantics(
          button: true,
          selected: m == value,
          label: '$m minutes',
          excludeSemantics: true,
          onTap: () => onChanged(m),
          child: InkWell(
            key: Key('picker.minutes.$m'),
            onTap: () => onChanged(m),
            customBorder: const StadiumBorder(),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 64),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: ShapeDecoration(
                color: m == value
                    ? (dark ? Colors.white : Lit.ink)
                    : Colors.transparent,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: m == value
                        ? (dark ? Colors.white : Lit.ink)
                        : (dark ? const Color(0xFF5F646D) : Lit.inkQuiet),
                    width: 1.5,
                  ),
                ),
              ),
              child: Text(
                '$m MIN',
                style: LitType.display(
                  20,
                  dark
                      ? (m == value ? Lit.ink : Colors.white)
                      : (m == value ? Colors.white : Lit.ink),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
