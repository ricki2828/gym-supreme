import 'package:flutter/material.dart';
import 'package:gym_engine/cut2.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../lit_widgets.dart';

/// Ghost line under the current or a done set (LiveScreen.setExtra, R6).
/// Renders nothing when there is no ghost (first session at this gym).
class GhostSetLine extends StatelessWidget {
  const GhostSetLine({
    super.key,
    required this.line,
    this.perHand = false,
    this.ink = Lit.ink,
  });

  final SetGhostLine? line;
  final bool perHand;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final text = l == null ? null : ghostSetText(l, perHand: perHand);
    if (l == null || text == null) return const SizedBox.shrink();
    // Icons, not ▲/▼: the bundled fonts lack those glyphs (tofu).
    final icon = switch (l.verdict) {
      GhostVerdict.ahead => Icons.arrow_drop_up,
      GhostVerdict.behind => Icons.arrow_drop_down,
      _ => null,
    };
    final colour = ink.withValues(alpha: 0.78);
    return Semantics(
      label: ghostSetSemantics(l),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            // Space kept when there is no arrow, so the lines align.
            SizedBox(
              width: 22,
              child: icon == null ? null : Icon(icon, size: 22, color: ink),
            ),
            Flexible(
              child: Text(
                text,
                style: LitType.body(14, colour, FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Session-total line (N3) for the post-workout screen
/// (PostWorkoutScreen.totalExtra) and the live screen. Hidden when null.
class GhostTotalLine extends StatelessWidget {
  const GhostTotalLine({super.key, required this.total, this.ink = Lit.ink});

  final SessionGhostTotal? total;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final text = sessionTotalText(total);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: LitType.body(15, ink, FontWeight.w700)),
    );
  }
}
