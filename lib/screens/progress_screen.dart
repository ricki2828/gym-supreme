import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'progress_model.dart';

/// The Progress tab (G1b): strength per lift, weekly volume, hard sets by
/// muscle, PBs. A pure widget over [ProgressView]; the adapter in flows.dart
/// builds the view from the engine.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({
    super.key,
    required this.view,
    required this.onOpenProfile,
    required this.onOpenLift,
    required this.onConfirm,
  });

  final ProgressView view;
  final VoidCallback onOpenProfile;
  final void Function(LiftCard card) onOpenLift;

  /// Typo-flagged set: he says the number is right.
  final void Function(IgnoredSet set) onConfirm;

  @override
  Widget build(BuildContext context) {
    final bw = view.bodyweight;
    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            Row(
              children: [
                Expanded(child: Text('PROGRESS', style: LitType.display(44))),
                TextButton(
                  key: const Key('progress.profile'),
                  onPressed: onOpenProfile,
                  child: Text(
                    'Profile',
                    style: LitType.body(14, Lit.ink, FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (view.profile.isEmpty || bw == null || bw.date == null)
              _ProfileNudge(
                onTap: onOpenProfile,
                hasProfile: !view.profile.isEmpty,
                undated: bw != null && bw.date == null,
              ),
            if (bw != null && bw.stale)
              _StaleBodyweight(
                text:
                    'Bodyweight from ${dateLabel(bw.date!, today: view.today)}. '
                    'Tap to update.',
                onTap: onOpenProfile,
              ),
            if (view.isEmpty)
              const _Empty()
            else ...[
              if (view.firstData) const _FirstData(),
              for (final f in view.flagged.take(3))
                _FlagRow(lift: f.$1, set: f.$2, onConfirm: onConfirm),
              _Heading('STRENGTH', 'Best e1RM, last 90 days'),
              for (final c in view.cards)
                _LiftTile(card: c, onTap: () => onOpenLift(c)),
              if (view.cards.isEmpty) const _Quiet('Nothing to estimate yet.'),
              _Heading('WEEKLY VOLUME', 'kg × reps, last 12 weeks'),
              _VolumeChart(weeks: view.weeks),
              _Heading('HARD SETS', 'Sets that count, by muscle'),
              if (view.muscles.isEmpty)
                const _Quiet('No hard sets this week or last.')
              else ...[
                const _SetsHeader(),
                for (final m in view.muscles) _MuscleRow(m: m),
              ],
              _Heading('PERSONAL BESTS', 'Newest first'),
              if (view.pbs.isEmpty)
                const _Quiet('Your first best shows up after a counted set.')
              else
                for (final p in view.pbs) _PbRow(p: p),
            ],
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.sub);
  final String title;
  final String sub;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: LitType.display(26)),
        const SizedBox(height: 2),
        Text(sub, style: LitType.body(12, Lit.inkSecondary)),
      ],
    ),
  );
}

class _Quiet extends StatelessWidget {
  const _Quiet(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: LitType.body(14, Lit.inkSecondary)),
  );
}

class _Box extends StatelessWidget {
  const _Box({
    super.key,
    required this.child,
    this.colour = Colors.white,
    this.onTap,
  });
  final Widget child;
  final Color colour;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: colour,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Lit.ink, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    ),
  );
}

class _ProfileNudge extends StatelessWidget {
  const _ProfileNudge({
    required this.onTap,
    required this.hasProfile,
    this.undated = false,
  });
  final VoidCallback onTap;
  final bool hasProfile;

  /// Only the old undated bodyweight exists.
  final bool undated;
  @override
  Widget build(BuildContext context) => _Box(
    key: const Key('progress.noProfile'),
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          undated
              ? 'ADD A DATED WEIGH-IN'
              : hasProfile
              ? 'ADD YOUR BODYWEIGHT'
              : 'NO PROFILE YET',
          style: LitType.display(22),
        ),
        const SizedBox(height: 4),
        Text(
          undated
              ? 'Your saved bodyweight has no date, so it cannot be checked '
                    'for age. Log a weigh-in. It stays on this phone.'
              : 'Add your bodyweight to see each lift as a multiple of it. '
                    'It stays on this phone.',
          style: LitType.body(14, Lit.inkSecondary),
        ),
      ],
    ),
  );
}

class _StaleBodyweight extends StatelessWidget {
  const _StaleBodyweight({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => _Box(
    key: const Key('progress.staleBodyweight'),
    colour: Lit.rest,
    onTap: onTap,
    child: Text(text, style: LitType.body(14, Lit.ink, FontWeight.w700)),
  );
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      key: const Key('progress.empty'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NOTHING TO SHOW YET', style: LitType.display(30)),
        const SizedBox(height: 6),
        Text(
          'Finish a workout and your strength shows up here. '
          'Nothing is estimated from sets you have not logged.',
          style: LitType.body(15, Lit.inkSecondary),
        ),
      ],
    ),
  );
}

class _FirstData extends StatelessWidget {
  const _FirstData();
  @override
  Widget build(BuildContext context) => _Box(
    key: const Key('progress.firstData'),
    colour: Lit.rest,
    child: Text(
      'Early days. Trends and bests firm up after a few sessions.',
      style: LitType.body(14, Lit.ink, FontWeight.w700),
    ),
  );
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({
    required this.lift,
    required this.set,
    required this.onConfirm,
  });
  final String lift;
  final IgnoredSet set;
  final void Function(IgnoredSet) onConfirm;
  @override
  Widget build(BuildContext context) => _Box(
    colour: Lit.core,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                set.light ? 'Confirm light number?' : 'Confirm big number?',
                style: LitType.body(14, Lit.ink, FontWeight.w800),
              ),
              Text(
                '$lift, ${set.what}, ${set.when}. Left out until you confirm.',
                style: LitType.body(13, Lit.ink),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: Key('progress.confirm.${set.setId}'),
          onPressed: () => onConfirm(set),
          child: Text('Yes', style: LitType.body(14, Lit.ink, FontWeight.w800)),
        ),
      ],
    ),
  );
}

class _LiftTile extends StatelessWidget {
  const _LiftTile({required this.card, required this.onTap});
  final LiftCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = card;
    final kg = c.bestKg;
    final notes = <String>[
      if (c.firstAtGym)
        'First session at ${c.gymName ?? 'this gym'}: set weights not counted',
      if (c.hasTypoFlag)
        c.hasLightFlag
            ? 'A light number is waiting for your OK'
            : 'A big number is waiting for your OK',
    ];
    return Semantics(
      container: true,
      label: [
        c.name,
        if (kg != null) 'best estimated one rep max ${kgText(kg)} kilograms',
        if (c.rough) 'rough estimate',
        if (c.ratio != null) '${c.ratio!.toStringAsFixed(2)} times bodyweight',
      ].join(', '),
      excludeSemantics: true,
      button: true,
      child: _Box(
        key: Key('progress.lift.${c.key}'),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.name.toUpperCase(),
              style: LitType.display(22),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (c.gymName != null)
              Text(c.gymName!, style: LitType.body(12, Lit.inkSecondary)),
            const SizedBox(height: 6),
            if (kg == null)
              Text(
                'No counted set yet',
                style: LitType.body(15, Lit.inkSecondary, FontWeight.w700),
              )
            else
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 10,
                runSpacing: 4,
                children: [
                  Text('${kgText(kg)} kg', style: LitType.display(44)),
                  if (c.rough) const _RoughTag(),
                  if (c.ratio != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${c.ratio!.toStringAsFixed(2)} × bodyweight',
                        style: LitType.body(15, Lit.ink, FontWeight.w800),
                      ),
                    ),
                ],
              ),
            if (kg != null)
              Text(
                [
                  'e1RM${c.bestDate == null ? '' : ', ${c.bestDate}'}',
                  if (c.rough)
                    c.solidKg == null
                        ? 'needs a heavier set (10 reps or fewer)'
                        : 'best at 10 reps or fewer: ${kgText(c.solidKg!)} kg',
                ].join(' · '),
                style: LitType.body(12, Lit.inkSecondary),
              ),
            const SizedBox(height: 8),
            c.trendPoints >= 2
                ? SizedBox(
                    height: 36,
                    child: CustomPaint(
                      size: const Size(double.infinity, 36),
                      painter: SparklinePainter(c.trend),
                    ),
                  )
                : Text(
                    c.sessions == 0
                        ? ''
                        : 'Trend shows after a second session.',
                    style: LitType.body(12, Lit.inkQuiet),
                  ),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  n,
                  style: LitType.body(12, Lit.ink, FontWeight.w700),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoughTag extends StatelessWidget {
  const _RoughTag();
  @override
  Widget build(BuildContext context) => Container(
    key: const Key('progress.rough'),
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Lit.rest,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Lit.ink),
    ),
    child: Text('ROUGH · 11-12 REPS', style: LitType.cap(11)),
  );
}

/// 12 weekly bests, gaps skipped. Ink line, last point dotted.
class SparklinePainter extends CustomPainter {
  SparklinePainter(this.values);
  final List<double?> values;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <(int, double)>[
      for (var i = 0; i < values.length; i++)
        if (values[i] != null) (i, values[i]!),
    ];
    if (pts.length < 2) return;
    var lo = pts.first.$2, hi = pts.first.$2;
    for (final p in pts) {
      if (p.$2 < lo) lo = p.$2;
      if (p.$2 > hi) hi = p.$2;
    }
    final span = hi - lo < 0.001 ? 1.0 : hi - lo;
    const pad = 4.0;
    Offset at((int, double) p) => Offset(
      pad + (size.width - 2 * pad) * p.$1 / (values.length - 1),
      size.height - pad - (size.height - 2 * pad) * (p.$2 - lo) / span,
    );
    final path = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    for (final p in pts.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = Lit.hair
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Lit.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    for (final p in pts) {
      canvas.drawCircle(at(p), 2.5, Paint()..color = Lit.ink);
    }
    canvas.drawCircle(at(pts.last), 5, Paint()..color = Lit.pb);
    canvas.drawCircle(
      at(pts.last),
      5,
      Paint()
        ..color = Lit.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.values != values;
}

class _VolumeChart extends StatelessWidget {
  const _VolumeChart({required this.weeks});
  final List<WeekVolume> weeks;
  @override
  Widget build(BuildContext context) {
    final top = weeks.fold<double>(0, (m, w) => w.kgReps > m ? w.kgReps : m);
    final now = weeks.isEmpty ? null : weeks.last;
    return _Box(
      key: const Key('progress.volume'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (now != null)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 8,
              children: [
                Text(thousandsKg(now.kgReps), style: LitType.display(34)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'kg this week, ${now.workouts} '
                    '${now.workouts == 1 ? 'workout' : 'workouts'}',
                    style: LitType.body(13, Lit.inkSecondary),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < weeks.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Container(
                        height: top <= 0 ? 2 : 2 + 62 * (weeks[i].kgReps / top),
                        decoration: BoxDecoration(
                          color: i == weeks.length - 1 ? Lit.ink : Lit.hair,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                weeks.isEmpty ? '' : weeks.first.label,
                style: LitType.body(11, Lit.inkQuiet),
              ),
              Text('this week', style: LitType.body(11, Lit.inkQuiet)),
            ],
          ),
        ],
      ),
    );
  }
}

/// "7,220".
String thousandsKg(double kg) {
  final s = kg.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

class _SetsHeader extends StatelessWidget {
  const _SetsHeader();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        const Expanded(child: SizedBox()),
        SizedBox(
          width: 76,
          child: Text(
            'THIS WK',
            textAlign: TextAlign.right,
            style: LitType.cap(11, Lit.inkSecondary),
          ),
        ),
        SizedBox(
          width: 76,
          child: Text(
            'LAST WK',
            textAlign: TextAlign.right,
            style: LitType.cap(11, Lit.inkSecondary),
          ),
        ),
      ],
    ),
  );
}

class _MuscleRow extends StatelessWidget {
  const _MuscleRow({required this.m});
  final MuscleSets m;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${m.name}, ${m.thisWeek} hard sets this week, '
        '${m.lastWeek} last week',
    excludeSemantics: true,
    child: Container(
      constraints: const BoxConstraints(minHeight: 36),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Lit.hair)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              m.name,
              style: LitType.body(14, Lit.ink, FontWeight.w700),
            ),
          ),
          SizedBox(
            width: 76,
            child: Text(
              '${m.thisWeek}',
              textAlign: TextAlign.right,
              style: LitType.display(24),
            ),
          ),
          SizedBox(
            width: 76,
            child: Text(
              '${m.lastWeek}',
              textAlign: TextAlign.right,
              style: LitType.display(24, Lit.inkQuiet),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PbRow extends StatelessWidget {
  const _PbRow({required this.p});
  final PbRow p;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Lit.hair)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.lift, style: LitType.body(14, Lit.ink, FontWeight.w700)),
              Text(
                p.gainKg == null
                    ? '${p.date} · first best'
                    : '${p.date} · +${kgText(p.gainKg!)} kg',
                style: LitType.body(12, Lit.inkSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('${kgText(p.kg)} kg', style: LitType.display(26)),
      ],
    ),
  );
}

/// The detail sheet for one lift: what counted, and every set that did not.
Future<void> showLiftSheet(
  BuildContext context, {
  required LiftCard card,
  required void Function(IgnoredSet set) onConfirm,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Lit.ground,
  showDragHandle: true,
  builder: (_) => LiftSheet(card: card, onConfirm: onConfirm),
);

class LiftSheet extends StatelessWidget {
  const LiftSheet({super.key, required this.card, required this.onConfirm});
  final LiftCard card;
  final void Function(IgnoredSet set) onConfirm;

  @override
  Widget build(BuildContext context) {
    const cap = 30;
    final shown = card.ignored.take(cap).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          key: const Key('progress.sheet'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shrinkWrap: true,
          children: [
            Text(card.name.toUpperCase(), style: LitType.display(30)),
            if (card.gymName != null)
              Text(card.gymName!, style: LitType.body(13, Lit.inkSecondary)),
            const SizedBox(height: 6),
            Text(
              card.bestKg == null
                  ? 'No set has counted yet.'
                  : 'Best e1RM ${kgText(card.bestKg!)} kg'
                        '${card.bestDate == null ? '' : ' on ${card.bestDate}'}. '
                        'Epley estimate, 1 to 10 reps; 11-12 reps are rough.',
              style: LitType.body(14, Lit.ink),
            ),
            if (card.ratio != null && card.bwKg != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${card.ratio!.toStringAsFixed(2)} × bodyweight, vs '
                  '${kgText(card.bwKg!)} kg'
                  '${card.bwDate == null ? ' (no date)' : ' (${dateLabel(card.bwDate!)})'}',
                  key: const Key('progress.sheet.bw'),
                  style: LitType.body(14, Lit.ink, FontWeight.w700),
                ),
              ),
            const SizedBox(height: 16),
            Text('LEFT OUT', style: LitType.display(24)),
            Text(
              'Sets in the last 90 days that do not count, and why.',
              style: LitType.body(12, Lit.inkSecondary),
            ),
            const SizedBox(height: 6),
            if (card.ignored.isEmpty)
              const _Quiet('Every set counted.')
            else
              for (final s in shown)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Lit.hair)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s.what} · ${s.when}',
                              style: LitType.body(14, Lit.ink, FontWeight.w700),
                            ),
                            Text(
                              s.reason,
                              style: LitType.body(12, Lit.inkSecondary),
                            ),
                          ],
                        ),
                      ),
                      if (s.canConfirm)
                        TextButton(
                          key: Key('progress.sheet.confirm.${s.setId}'),
                          onPressed: () => onConfirm(s),
                          child: Text(
                            'It is right',
                            style: LitType.body(13, Lit.ink, FontWeight.w800),
                          ),
                        ),
                    ],
                  ),
                ),
            if (card.ignored.length > cap)
              _Quiet('and ${card.ignored.length - cap} older sets'),
          ],
        ),
      ),
    );
  }
}
