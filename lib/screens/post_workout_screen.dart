import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/body_map.dart';
import '../widgets/lit_widgets.dart';
import 'view_models.dart';

class PbView {
  const PbView({
    required this.exercise,
    required this.loadG,
    required this.reps,
    required this.unit,
    this.wasLoadG,
    this.wasReps,
  });
  final String exercise;
  final int? loadG;
  final int reps;
  final LoadUnit unit;
  final int? wasLoadG;
  final int? wasReps;
}

/// Engine WorkoutSummary, shaped for the screen.
class PostWorkoutView {
  const PostWorkoutView({
    required this.type,
    required this.gymName,
    required this.durationS,
    required this.volumeKg,
    required this.setCount,
    required this.musclesLit,
    required this.setsPerGroup,
    required this.weeklyStreak,
    this.volumeDeltaPct,
    this.pbs = const [],
    this.weekTypes = const {},
  });
  final WorkoutType? type;
  final String gymName;
  final int durationS;
  final double volumeKg;

  /// Against the last session of the same type; null when there is none.
  final double? volumeDeltaPct;
  final int setCount;

  /// Muscle ids worked hard enough to light.
  final List<String> musclesLit;

  /// "chest" → 10 sets, by picker group label, largest first.
  final List<(String, int)> setsPerGroup;

  /// Weeks in a row with 2+ sessions (plan 18).
  final int weeklyStreak;
  final List<PbView> pbs;

  /// Types trained this week (Monday start), for the five-chip row.
  final Set<WorkoutType> weekTypes;
}

/// Post-workout (plan item 6; b-post.png): volume, muscles lit, PBs, streak.
class PostWorkoutScreen extends StatelessWidget {
  const PostWorkoutScreen({
    super.key,
    required this.view,
    this.onDone,
    this.onShare,
    this.totalExtra,
  });
  final PostWorkoutView view;
  final VoidCallback? onDone;

  /// Hidden when null (cut 1 ships export, not a share card).
  final VoidCallback? onShare;

  /// Cut-2 slot under the stats (ghost session-total line, t61).
  final Widget? totalExtra;

  @override
  Widget build(BuildContext context) {
    final type = view.type;
    final colour = type?.colour ?? Lit.ink;
    final onColour = type?.onColour ?? Colors.white;
    final title = '${type?.label ?? 'Session'}, done'.toUpperCase();
    final lit = view.musclesLit.length;
    final delta = view.volumeDeltaPct;
    final volumeNote = delta == null
        ? 'volume'
        : delta.round() == 0
        ? 'volume, same as last time'
        : 'volume, ${delta > 0 ? 'up' : 'down'} ${delta.abs().round()}%';

    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(title, style: LitType.display(44))),
                      if (view.weeklyStreak > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Lit.ink,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${view.weeklyStreak} WK STREAK',
                            style: LitType.body(
                              14,
                              Colors.white,
                              FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _LitCard(
                    colour: colour,
                    ink: onColour,
                    caption:
                        '${view.gymName.toUpperCase()} · ${clock(view.durationS)}',
                    musclesLit: view.musclesLit,
                    headline: lit == 1 ? '1 MUSCLE LIT' : '$lit MUSCLES LIT',
                  ),
                  for (final pb in view.pbs) ...[
                    const SizedBox(height: 12),
                    _PbCard(pb: pb),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 28,
                    runSpacing: 12,
                    children: [
                      _Stat(
                        value: '${thousands(view.volumeKg.round())} KG',
                        label: volumeNote,
                      ),
                      _Stat(value: '${view.setCount}', label: 'sets'),
                      if (view.setsPerGroup.isNotEmpty)
                        _Stat(
                          value: view.setsPerGroup
                              .take(3)
                              .map((g) => '${g.$2}')
                              .join(' · '),
                          label:
                              'sets: ${view.setsPerGroup.take(3).map((g) => g.$1.toLowerCase()).join(', ')}',
                        ),
                    ],
                  ),
                  ?totalExtra,
                  const SizedBox(height: 18),
                  Text(
                    _weekLine(),
                    style: LitType.body(15, Lit.inkSecondary, FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (final t in WorkoutType.values) ...[
                        if (t != WorkoutType.values.first)
                          const SizedBox(width: 8),
                        Expanded(
                          child: _TypeChip(
                            type: t,
                            on: view.weekTypes.contains(t),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  if (onShare != null) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onShare,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(60),
                          side: const BorderSide(color: Lit.ink, width: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: Text(
                          'Share',
                          style: LitType.body(17, Lit.ink, FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: BigButton(
                      label: 'DONE',
                      colour: Lit.ink,
                      ink: Colors.white,
                      height: 60,
                      fontSize: 36,
                      radius: 18,
                      onTap: onDone,
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

  String _weekLine() {
    final n = view.weekTypes.length;
    final left = [
      for (final t in WorkoutType.values)
        if (!view.weekTypes.contains(t)) t.label,
    ];
    if (left.isEmpty) return 'This week: all 5 lit.';
    final rest = left.length == 1
        ? '${left.first} is left.'
        : '${left.join(', ')} are left.';
    return 'This week: $n of 5 lit. $rest';
  }
}

class _LitCard extends StatelessWidget {
  const _LitCard({
    required this.colour,
    required this.ink,
    required this.caption,
    required this.musclesLit,
    required this.headline,
  });
  final Color colour;
  final Color ink;
  final String caption;
  final List<String> musclesLit;
  final String headline;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$headline. ${musclesLit.join(', ')}',
    excludeSemantics: true,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: CustomPaint(
        painter: _Rays(colour),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(caption, style: LitType.cap(14, ink)),
              const SizedBox(height: 12),
              Center(
                child: BodyMap(
                  fills: {for (final m in musclesLit) m: Lit.ink},
                  unlit: Colors.white.withValues(alpha: 0.5),
                  outline: Colors.transparent,
                  width: 260,
                ),
              ),
              const SizedBox(height: 12),
              Center(child: Text(headline, style: LitType.display(64, ink))),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The sunburst behind the lit body (b-post).
class _Rays extends CustomPainter {
  _Rays(this.colour);
  final Color colour;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colour);
    final c = Offset(size.width / 2, size.height * 0.48);
    final r = size.longestSide;
    final p = Paint()..color = Colors.white.withValues(alpha: 0.16);
    const n = 16;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + r * math.cos(a), c.dy + r * math.sin(a))
        ..lineTo(
          c.dx + r * math.cos(a + math.pi / n),
          c.dy + r * math.sin(a + math.pi / n),
        )
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_Rays old) => old.colour != colour;
}

class _PbCard extends StatelessWidget {
  const _PbCard({required this.pb});
  final PbView pb;
  @override
  Widget build(BuildContext context) {
    final load = pb.loadG == null ? null : kg(pb.loadG!);
    final big = load == null ? '${pb.reps} REPS' : '$load × ${pb.reps}';
    final was = pb.wasReps == null
        ? 'first time'
        : pb.wasLoadG == null
        ? 'was ${pb.wasReps} reps'
        : 'was ${kg(pb.wasLoadG!)} × ${pb.wasReps}';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: Lit.pb,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PB · ${pb.exercise.toUpperCase()}',
            style: LitType.cap(14, Lit.pbInk),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(big, style: LitType.display(80, Lit.pbInk)),
                ),
              ),
              Text(
                was,
                textAlign: TextAlign.right,
                style: LitType.body(16, Lit.pbInk, FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 200),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: LitType.display(48)),
        const SizedBox(height: 2),
        Text(label, style: LitType.body(15, Lit.inkSecondary)),
      ],
    ),
  );
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.type, required this.on});
  final WorkoutType type;
  final bool on;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${type.label}, ${on ? 'trained this week' : 'not yet this week'}',
    excludeSemantics: true,
    child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: on
          ? BoxDecoration(
              color: type.colour,
              borderRadius: BorderRadius.circular(14),
            )
          : null,
      foregroundDecoration: on
          ? null
          : _DashedBox(radius: 14, colour: Lit.inkQuiet),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          type.label,
          style: LitType.body(
            15,
            on ? type.onColour : Lit.inkQuiet,
            FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

class _DashedBox extends Decoration {
  const _DashedBox({required this.radius, required this.colour});
  final double radius;
  final Color colour;
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedPainter(radius, colour);
}

class _DashedPainter extends BoxPainter {
  _DashedPainter(this.radius, this.colour);
  final double radius;
  final Color colour;
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final rect = (offset & cfg.size!).deflate(1);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
      }
    }
  }
}
