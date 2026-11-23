import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/body_map.dart';
import '../widgets/lit_widgets.dart';
import 'view_models.dart';

/// One muscle on the Body tab.
class BodyMuscle {
  const BodyMuscle({
    required this.id,
    required this.name,
    required this.days,
    this.lastType,
  });
  final String id;
  final String name;

  /// Null = never trained.
  final int? days;

  /// The type of the session that last trained it, for its colour.
  final WorkoutType? lastType;

  bool get resting => days != null && days! < 2;

  /// Filled on the map: trained in the last 4 days (plan 18).
  bool get filled => days != null && days! < 4 && !resting;
}

/// The Body tab (b2-body.png, approved M2): days since per muscle.
/// [muscles] in body order (the taxonomy's order).
class BodyScreen extends StatelessWidget {
  const BodyScreen({super.key, required this.muscles, this.weeklyStreak = 0});
  final List<BodyMuscle> muscles;
  final int weeklyStreak;

  @override
  Widget build(BuildContext context) {
    final fills = {
      for (final m in muscles)
        if (m.filled) m.id: m.lastType?.colour ?? Lit.ink,
    };
    final resting = {
      for (final m in muscles)
        if (m.resting) m.id,
    };
    final legend = <(Color?, String)>[];
    final seen = <WorkoutType>{};
    for (final m in muscles) {
      if (m.filled && m.lastType != null && seen.add(m.lastType!)) {
        legend.add((
          m.lastType!.colour,
          '${m.lastType!.label}, ${_ago(m.days!)}',
        ));
      }
    }
    final restingTypes = {
      for (final m in muscles)
        if (m.resting && m.lastType != null) m.lastType!,
    };
    for (final t in restingTypes) {
      final d = muscles
          .where((m) => m.resting && m.lastType == t)
          .map((m) => m.days!)
          .reduce((a, b) => a < b ? a : b);
      legend.add((null, '${t.label}, ${_ago(d)}'));
    }
    final longest = [
      for (final m in muscles)
        if (m.days != null) m,
    ]..sort((a, b) => b.days!.compareTo(a.days!));
    final half = (muscles.length / 2).ceil();

    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          children: [
            Row(
              children: [
                Expanded(child: Text('DAYS SINCE', style: LitType.display(44))),
                if (weeklyStreak > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Lit.ink,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$weeklyStreak WK STREAK',
                      style: LitType.body(13, Colors.white, FontWeight.w800),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Filled: trained in the last 4 days. Hatched: still resting.',
              style: LitType.body(14, Lit.inkSecondary),
            ),
            const SizedBox(height: 10),
            Center(
              child: BodyMap(
                fills: fills,
                resting: resting,
                width: 250,
                semanticLabel:
                    'Body map. ${fills.length} muscles trained in the last '
                    '4 days, ${resting.length} resting.',
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 6,
              children: [
                for (final (c, l) in legend) _Key(colour: c, label: l),
                const _Key(colour: Colors.white, label: 'Ready'),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text('EVERY MUSCLE', style: LitType.display(26)),
                ),
                if (longest.isNotEmpty)
                  Text(
                    'longest rest: ${longest.first.name.toLowerCase()}, '
                    '${daysLabel(longest.first.days)}',
                    style: LitType.body(12, Lit.inkSecondary),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _column(muscles.take(half).toList())),
                const SizedBox(width: 18),
                Expanded(child: _column(muscles.skip(half).toList())),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _column(List<BodyMuscle> ms) =>
      Column(children: [for (final m in ms) _MuscleRow(m: m)]);
}

String _ago(int days) => switch (days) {
  0 => 'today',
  1 => 'yesterday',
  _ => '$days days ago',
};

class _Key extends StatelessWidget {
  const _Key({required this.colour, required this.label});

  /// Null = the resting hatch.
  final Color? colour;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _Swatch(colour: colour),
      const SizedBox(width: 6),
      Text(label, style: LitType.body(12, Lit.ink, FontWeight.w700)),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({this.colour});
  final Color? colour;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 12,
    height: 12,
    child: CustomPaint(painter: _SwatchPainter(colour)),
  );
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.colour);
  final Color? colour;
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      const Radius.circular(3),
    );
    if (colour == null) {
      canvas.save();
      canvas.clipRRect(r);
      canvas.drawRRect(r, Paint()..color = const Color(0xFFD6FFC2));
      final ink = Paint()
        ..color = Lit.ink
        ..strokeWidth = 1.3;
      for (double t = -size.height; t < size.width; t += 5) {
        canvas.drawLine(
          Offset(t, size.height),
          Offset(t + size.height, 0),
          ink,
        );
      }
      canvas.restore();
    } else {
      canvas.drawRRect(r, Paint()..color = colour!);
    }
    canvas.drawRRect(
      r,
      Paint()
        ..color = Lit.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.colour != colour;
}

class _MuscleRow extends StatelessWidget {
  const _MuscleRow({required this.m});
  final BodyMuscle m;
  @override
  Widget build(BuildContext context) {
    final fg = m.resting ? Lit.inkQuiet : Lit.ink;
    return Semantics(
      label: [
        m.name,
        m.days == null ? 'not trained yet' : '${daysLabel(m.days)} since',
        if (m.resting) 'resting',
      ].join(', '),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Lit.hair)),
        ),
        child: Row(
          children: [
            _Swatch(
              colour: m.resting
                  ? null
                  : (m.filled ? (m.lastType?.colour ?? Lit.ink) : Colors.white),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: m.name,
                  style: LitType.body(13, fg, FontWeight.w700),
                  children: [
                    if (m.resting)
                      TextSpan(
                        text: '  resting',
                        style: LitType.body(11, Lit.inkQuiet, FontWeight.w700),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              daysLabel(m.days).toUpperCase(),
              style: LitType.display(22, fg),
            ),
          ],
        ),
      ),
    );
  }
}
