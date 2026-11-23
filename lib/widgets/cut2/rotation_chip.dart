import 'package:flutter/material.dart';
import 'package:gym_engine/cut2.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../lit_widgets.dart';

/// "Next: Pull · then Legs, Push" chip for the session sheet
/// (PickerScreen.sheetExtra). Tap opens the rotation editor. Hidden when the
/// rotation is empty.
class RotationChip extends StatelessWidget {
  const RotationChip({
    super.key,
    required this.rotation,
    required this.names,
    this.onTap,
    this.dark = true,
  });

  final Rotation rotation;

  /// Workout type id → display name.
  final Map<String, String> names;
  final VoidCallback? onTap;

  /// On the ink sheet by default.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final text = rotationChipText(rotation, names);
    if (text == null) return const SizedBox.shrink();
    final fg = dark ? Colors.white : Lit.ink;
    return Semantics(
      button: onTap != null,
      label: onTap == null ? text : '$text. Change rotation',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: ShapeDecoration(
            shape: StadiumBorder(
              side: BorderSide(color: fg.withValues(alpha: 0.5), width: 1.5),
            ),
          ),
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: LitType.body(14, fg, FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
