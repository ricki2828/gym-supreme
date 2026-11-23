import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

/// The 16-muscle body map, front and back, drawn A-style in LIT colours
/// (plan 18-19; geometry ported from gym-supreme-jam/src/d.py `body16`).
///
/// Ink outline, white when unlit, solid [fills] colour when chosen or
/// trained, an ink hatch on light green when [resting]. Muscle ids are the
/// taxonomy slugs (`assets/exercises_taxonomy.json`).
class BodyMap extends StatelessWidget {
  const BodyMap({
    super.key,
    required this.fills,
    this.resting = const {},
    this.noKit = const {},
    this.width = 176,
    this.onTapMuscle,
    this.semanticLabel,
  });

  /// Muscle id to fill colour. Missing ids draw white.
  final Map<String, Color> fills;

  /// Muscles drawn hatched (still resting).
  final Set<String> resting;

  /// Muscles with no kit at this gym: dashed outline, no fill.
  final Set<String> noKit;
  final double width;

  /// Called with the muscle id under a tap; null disables hit testing.
  final ValueChanged<String>? onTapMuscle;

  /// Screen-reader summary. The figure itself is one node; the rows beside it
  /// carry per-muscle labels (plan 18).
  final String? semanticLabel;

  static const double _vbW = 250;
  static const double _vbH = 326;

  @override
  Widget build(BuildContext context) {
    final height = width * _vbH / _vbW;
    final painter = _BodyPainter(fills: fills, resting: resting, noKit: noKit);
    Widget child = CustomPaint(size: Size(width, height), painter: painter);
    if (onTapMuscle != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final id = BodyGeometry.hit(d.localPosition * (_vbW / width));
          if (id != null) onTapMuscle!(id);
        },
        child: child,
      );
    }
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: child,
    );
  }
}

/// A shape in the 160 x 326 single-figure viewBox (internal to the map).
sealed class BodyShape {
  const BodyShape();
  Path path();
}

class _RRect extends BodyShape {
  const _RRect(this.x, this.y, this.w, this.h, this.r);
  final double x, y, w, h, r;
  @override
  Path path() => Path()
    ..addRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
    );
}

class _Oval extends BodyShape {
  const _Oval(this.cx, this.cy, this.rx, this.ry);
  final double cx, cy, rx, ry;
  @override
  Path path() => Path()
    ..addOval(
      Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
    );
}

class _Poly extends BodyShape {
  const _Poly(this.pts);
  final List<Offset> pts;
  @override
  Path path() => Path()..addPolygon(pts, true);
}

List<BodyShape> _pair(double x, double y, double w, double h, double r) => [
  _RRect(x, y, w, h, r),
  _RRect(160 - x - w, y, w, h, r),
];

const _lat = [
  Offset(57, 64),
  Offset(78, 80),
  Offset(78, 112),
  Offset(62, 124),
  Offset(57, 100),
];
List<Offset> _mirror(List<Offset> pts) => [
  for (final p in pts) Offset(160 - p.dx, p.dy),
];

/// Geometry of both figures, in the 250 x 326 viewBox (front at dx -20,
/// back at dx +110), as in the mockup source.
abstract final class BodyGeometry {
  static const double frontDx = -20;
  static const double backDx = 110;

  static final List<BodyShape> base = [
    const _Oval(80, 24, 14, 17),
    const _RRect(73, 38, 14, 14, 4),
    const _Oval(37, 166, 6.5, 6.5),
    const _Oval(123, 166, 6.5, 6.5),
    ..._pair(57, 312, 20, 9, 4),
  ];

  /// `null` key = a non-muscle part (hips band), drawn grey.
  static final List<(String?, List<BodyShape>)> front = [
    ('side-delts', const [_Oval(40, 67, 6.5, 11), _Oval(120, 67, 6.5, 11)]),
    ('front-delts', const [_Oval(51, 64, 7, 10), _Oval(109, 64, 7, 10)]),
    ('chest', _pair(59, 56, 20, 26, 7)),
    ('biceps', _pair(35, 81, 15, 33, 7.5)),
    ('forearms', _pair(30, 118, 14, 40, 7)),
    ('abs', const [_RRect(67, 86, 26, 46, 6)]),
    ('obliques', _pair(57, 86, 8, 40, 4)),
    (null, const [_RRect(58, 135, 44, 14, 6)]),
    ('quads', _pair(57, 152, 21, 80, 10)),
    ('calves', _pair(59, 238, 17, 70, 8.5)),
  ];

  static final List<(String?, List<BodyShape>)> back = [
    ('side-delts', const [_Oval(40, 67, 6.5, 11), _Oval(120, 67, 6.5, 11)]),
    ('rear-delts', const [_Oval(51, 64, 7, 10), _Oval(109, 64, 7, 10)]),
    (
      'traps',
      const [
        _Poly([
          Offset(80, 46),
          Offset(100, 57),
          Offset(86, 76),
          Offset(74, 76),
          Offset(60, 57),
        ]),
      ],
    ),
    ('lats', [const _Poly(_lat), _Poly(_mirror(_lat))]),
    ('triceps', _pair(35, 81, 15, 33, 7.5)),
    ('forearms', _pair(30, 118, 14, 40, 7)),
    ('lower-back', const [_RRect(66, 127, 28, 9, 4)]),
    ('glutes', _pair(57, 139, 22, 26, 10)),
    ('hamstrings', _pair(57, 168, 21, 64, 10)),
    ('calves', _pair(59, 238, 17, 70, 8.5)),
  ];

  /// Every muscle id the map draws (all 16).
  static Set<String> get muscleIds => {
    for (final (k, _) in [...front, ...back]) ?k,
  };

  /// The muscle under [p] (viewBox coordinates), back figure checked after
  /// front; later shapes win, as in paint order.
  static String? hit(Offset p) {
    for (final (dx, parts) in [(frontDx, front), (backDx, back)]) {
      final local = p.translate(-dx, 0);
      for (final (id, shapes) in parts.reversed) {
        if (id == null) continue;
        if (shapes.any((s) => s.path().contains(local))) return id;
      }
    }
    return null;
  }
}

class _BodyPainter extends CustomPainter {
  _BodyPainter({
    required this.fills,
    required this.resting,
    required this.noKit,
  });
  final Map<String, Color> fills;
  final Set<String> resting;
  final Set<String> noKit;

  static const Color _baseGrey = Color(0xFFDADCD6);
  static const Color _hatchGround = Color(0xFFD6FFC2);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / BodyMap._vbW);
    _side(canvas, BodyGeometry.front, BodyGeometry.frontDx);
    _side(canvas, BodyGeometry.back, BodyGeometry.backDx);
  }

  void _side(Canvas canvas, List<(String?, List<BodyShape>)> parts, double dx) {
    canvas.save();
    canvas.translate(dx, 0);
    final grey = Paint()..color = _baseGrey;
    for (final s in BodyGeometry.base) {
      canvas.drawPath(s.path(), grey);
    }
    final stroke = Paint()
      ..color = Lit.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    for (final (id, shapes) in parts) {
      for (final s in shapes) {
        final path = s.path();
        if (id == null) {
          canvas.drawPath(path, grey);
          continue;
        }
        if (noKit.contains(id)) {
          canvas.drawPath(path, Paint()..color = Lit.ground);
          _dashed(canvas, path, stroke..color = Lit.inkQuiet);
          stroke.color = Lit.ink;
          continue;
        }
        if (resting.contains(id)) {
          _hatch(canvas, path);
        } else {
          canvas.drawPath(path, Paint()..color = fills[id] ?? Colors.white);
        }
        canvas.drawPath(path, stroke);
      }
    }
    canvas.restore();
  }

  /// 45 deg ink hatch on light green, 5-unit pitch (mockup pattern `h`).
  void _hatch(Canvas canvas, Path path) {
    canvas.save();
    canvas.clipPath(path);
    final b = path.getBounds();
    canvas.drawRect(b, Paint()..color = _hatchGround);
    final ink = Paint()
      ..color = Lit.ink
      ..strokeWidth = 1.3;
    final span = b.width + b.height;
    for (double t = -span; t < span; t += 5) {
      canvas.drawLine(
        Offset(b.left + t, b.bottom),
        Offset(b.left + t + b.height, b.top),
        ink,
      );
    }
    canvas.restore();
  }

  void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.fills != fills || old.resting != resting || old.noKit != noKit;
}
