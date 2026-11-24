import 'package:flutter/gestures.dart';
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
    onTap: onTap,
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
      onTap: onTap,
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
    this.markFirst = false,
    this.lockFirst = false,
    this.moveMenu = false,
    this.onMoveItem,
  });

  /// Move up / down from the row menu, by exercise id (live lists): resolved
  /// by the owner at the moment it runs, not by the index the row had when it
  /// was drawn. Without it the menu falls back to [onReorder] with indexes.
  final void Function(String exerciseId, int delta)? onMoveItem;

  /// Live lists: a 48 dp handle that starts a drag after a short hold, a
  /// long-press anywhere on the row, and a Move up / Move down menu on every
  /// row (the sure way when a drag will not take). Off for the picker.
  final bool moveMenu;

  /// The first row cannot be dragged (a timer block runs on it): its handle
  /// is dimmed and does nothing.
  final bool lockFirst;

  /// Tags the first row "NOW" (the live screen's list starts with the
  /// current exercise).
  final bool markFirst;

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
      final locked = lockFirst && i == 0;
      final grip = Grip(
        colour: locked
            ? (dark ? const Color(0x558A8F98) : const Color(0x55121417))
            : (dark ? const Color(0xFF8A8F98) : Lit.ink),
      );
      // The handle: an opaque 48 x 56 target around the 18 dp bars.
      final handle = moveMenu
          ? Container(
              key: Key('plan.handle.$i'),
              width: 48,
              height: 56,
              color: Colors.transparent,
              alignment: Alignment.center,
              child: grip,
            )
          : SizedBox(
              width: 44,
              height: 48,
              child: Align(alignment: Alignment.centerLeft, child: grip),
            );
      final label =
          '${markFirst && i == 0 ? 'Current exercise: ' : ''}'
          '${p.name}, ${prescription(p)}'
          '${locked ? ', timer running, cannot be moved' : ''}';
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The tag sits above the name, not beside it: a 320 dp phone at
          // 1.3x text has no room for another word in the row.
          if (markFirst && i == 0) Text('NOW', style: LitType.cap(11, fg)),
          Text(p.name, style: LitType.body(14, fg, FontWeight.w700)),
          if (moveMenu)
            Text(prescription(p), style: LitType.body(13, fg, FontWeight.w600)),
        ],
      );
      final live = onReorder != null && !locked;
      Widget body;
      if (moveMenu) {
        final canUp = i > 0 && !locked && !(lockFirst && i == 1);
        final canDown = i < items.length - 1 && !locked;
        // The label covers the text only: the handle and the menu are
        // siblings, so the menu keeps its own tap action.
        body = Row(
          children: [
            live ? _HandleDrag(index: i, child: handle) : handle,
            Expanded(
              child: Semantics(
                label: label,
                excludeSemantics: true,
                child: text,
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: PopupMenuButton<int>(
                key: Key('plan.menu.$i'),
                padding: EdgeInsets.zero,
                tooltip: 'Move ${p.name}',
                enabled:
                    (onReorder != null || onMoveItem != null) &&
                    (canUp || canDown),
                icon: Icon(Icons.more_vert, color: fg),
                onSelected: (d) => onMoveItem != null
                    ? onMoveItem!(p.exerciseId, d)
                    : onReorder!(i, i + d),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: Key('plan.up.$i'),
                    value: -1,
                    enabled: canUp,
                    child: const Text('Move up'),
                  ),
                  PopupMenuItem(
                    key: Key('plan.down.$i'),
                    value: 1,
                    enabled: canDown,
                    child: const Text('Move down'),
                  ),
                ],
              ),
            ),
          ],
        );
        if (live) {
          body = ReorderableDelayedDragStartListener(index: i, child: body);
        }
      } else {
        body = Semantics(
          label: label,
          excludeSemantics: true,
          child: Row(
            children: [
              if (live)
                ReorderableDragStartListener(index: i, child: handle)
              else
                handle,
              Expanded(child: text),
              const SizedBox(width: 8),
              Text(
                prescription(p).toUpperCase(),
                style: LitType.display(22, fg),
              ),
            ],
          ),
        );
      }
      return Container(
        key: ValueKey(keys[i]),
        constraints: BoxConstraints(minHeight: moveMenu ? 56 : 48),
        padding: EdgeInsets.symmetric(vertical: moveMenu ? 4 : 0),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: rule)),
        ),
        child: body,
      );
    }

    Widget capped(Widget w) => maxHeight == null
        ? w
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: w,
          );
    if (onReorder == null) {
      final rows = Column(
        children: [for (var i = 0; i < items.length; i++) row(i)],
      );
      return capped(
        maxHeight == null ? rows : SingleChildScrollView(child: rows),
      );
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
    return capped(list);
  }
}

/// The row's drag handle: a drag starts after a 120 ms hold, which beats the
/// page's own scroll (an immediate drag lost to it, so it took several tries).
class _HandleDrag extends ReorderableDragStartListener {
  const _HandleDrag({required super.index, required super.child});
  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(
        delay: const Duration(milliseconds: 120),
        debugOwner: this,
      );
}
