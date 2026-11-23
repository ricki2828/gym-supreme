import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/view_models.dart';

/// LIT type helpers: Saira Extra Condensed caps for display, Schibsted for
/// text. Sizes are the mockups' CSS px (412-wide frame), used as dp.
abstract final class LitType {
  static TextStyle display(double size, [Color colour = Lit.ink]) => TextStyle(
    fontFamily: RunSoloType.display,
    fontSize: size,
    fontWeight: FontWeight.w800,
    height: 0.92,
    letterSpacing: size * 0.01,
    fontFeatures: RunSoloType.tabular,
    color: colour,
  );

  static TextStyle body(
    double size, [
    Color colour = Lit.ink,
    FontWeight weight = FontWeight.w400,
  ]) => TextStyle(
    fontFamily: RunSoloType.ui,
    fontSize: size,
    fontWeight: weight,
    height: 1.35,
    color: colour,
  );

  /// Small caps label ("LIFT 1 OF 5 · SET 3 OF 4").
  static TextStyle cap(double size, [Color colour = Lit.ink]) => TextStyle(
    fontFamily: RunSoloType.ui,
    fontSize: size,
    fontWeight: FontWeight.w700,
    letterSpacing: size * 0.08,
    height: 1.2,
    color: colour,
  );
}

/// The ink sheet at the foot of the picker (rounded top).
class DarkSheet extends StatelessWidget {
  const DarkSheet({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(
      20,
      14,
      20,
      20 + MediaQuery.paddingOf(context).bottom,
    ),
    decoration: const BoxDecoration(
      color: Lit.ink,
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    child: child,
  );
}

/// The full-width display-type action ("START PUSH", "DONE").
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.colour,
    required this.ink,
    required this.onTap,
    this.height = 56,
    this.width,
    this.fontSize = 30,
    this.sub,
    this.subColour,
    this.radius = 16,
    this.semanticLabel,
  });
  final String label;
  final Color colour;
  final Color ink;
  final VoidCallback? onTap;
  final double height;
  final double? width;
  final double fontSize;
  final String? sub;
  final Color? subColour;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: semanticLabel ?? [label, ?sub].join('. '),
    excludeSemantics: true,
    child: Material(
      color: colour,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          height: height,
          width: width ?? double.infinity,
          // Scales down rather than clipping at large text (1.3x): the sub
          // line ("as planned / changed") is what one-tap Done relies on.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: LitType.display(fontSize, ink)),
                  if (sub != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      sub!,
                      style: LitType.body(
                        15,
                        subColour ?? ink,
                        FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// "Condo gym ▾".
class GymChip extends StatelessWidget {
  const GymChip({super.key, required this.name, this.onTap, this.dark = false});
  final String name;
  final VoidCallback? onTap;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Lit.ink;
    return Semantics(
      button: true,
      label: 'Gym: $name. Change gym',
      excludeSemantics: true,
      // 48 dp tap target around a 32 dp chip.
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: dark ? const Color(0xFF5F646D) : Lit.ink,
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: LitType.body(12, fg, FontWeight.w700)),
                  Icon(Icons.arrow_drop_down, size: 16, color: fg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three-bar drag handle.
class Grip extends StatelessWidget {
  const Grip({super.key, this.colour = const Color(0xFF8A8F98)});
  final Color colour;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          Container(
            height: 2.5,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Planned exercises with drag handles; reorder through [onReorder]
/// (`to` is the final index, already adjusted for the removed item).
class PlanList extends StatelessWidget {
  const PlanList({
    super.key,
    required this.items,
    this.onReorder,
    this.dark = false,
    this.ruleColour,
    this.maxHeight,
  });

  /// When set, the list scrolls inside this height instead of growing.
  final double? maxHeight;
  final List<PlanItem> items;
  final void Function(int from, int to)? onReorder;
  final bool dark;
  final Color? ruleColour;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Lit.ink;
    final rule =
        ruleColour ??
        (dark ? const Color(0x1FFFFFFF) : const Color(0x33121417));
    // Stable keys across reorders: the id, plus its occurrence if repeated.
    final seen = <String, int>{};
    final keys = [
      for (final p in items)
        '${p.exerciseId}~${seen.update(p.exerciseId, (n) => n + 1, ifAbsent: () => 0)}',
    ];
    Widget row(int i) {
      final p = items[i];
      // A 48 x 48 drag target around the 18 dp bars (used mid-set).
      final handle = SizedBox(
        width: 44,
        height: 48,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Grip(colour: dark ? const Color(0xFF8A8F98) : Lit.ink),
        ),
      );
      return Container(
        key: ValueKey(keys[i]),
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: rule)),
        ),
        child: Semantics(
          label: '${p.name}, ${prescription(p)}',
          excludeSemantics: true,
          child: Row(
            children: [
              if (onReorder != null)
                ReorderableDragStartListener(index: i, child: handle)
              else
                handle,
              Expanded(
                child: Text(
                  p.name,
                  style: LitType.body(14, fg, FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                prescription(p).toUpperCase(),
                style: LitType.display(22, fg),
              ),
            ],
          ),
        ),
      );
    }

    if (onReorder == null) {
      return Column(children: [for (var i = 0; i < items.length; i++) row(i)]);
    }
    final list = ReorderableListView(
      shrinkWrap: true,
      physics: maxHeight == null ? const NeverScrollableScrollPhysics() : null,
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) => onReorder!(from, to),
      proxyDecorator: (child, _, _) => Material(
        color: dark ? Lit.ink : Lit.ground,
        elevation: 4,
        child: child,
      ),
      children: [for (var i = 0; i < items.length; i++) row(i)],
    );
    return maxHeight == null
        ? list
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: list,
          );
  }
}
