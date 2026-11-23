import 'package:flutter/material.dart';
import 'package:gym_engine/cut2.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../../widgets/lit_widgets.dart';

/// Edit the rotation (R5 option a, N1): drag to reorder, tap a row to make
/// it next, skip the next one. Every change goes out through [onChanged];
/// the caller persists it (`saveRotation`) and passes the new [rotation]
/// back in, so the list never indexes a stale copy.
class RotationScreen extends StatelessWidget {
  const RotationScreen({
    super.key,
    required this.rotation,
    required this.names,
    required this.onChanged,
    this.colours = const {},
  });

  final Rotation rotation;
  final Map<String, String> names;
  final ValueChanged<Rotation> onChanged;

  /// Workout type id → its colour (push pink, pull blue, ...).
  final Map<String, Color> colours;

  @override
  Widget build(BuildContext context) {
    final r = rotation;
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        elevation: 0,
        title: Text('ROTATION', style: LitType.display(28)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'Drag to change the order. Tap one to do it next.',
              style: LitType.body(15, Lit.inkSecondary, FontWeight.w600),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: r.order.length,
              buildDefaultDragHandles: false,
              // onReorderItem gives the final index (already adjusted).
              onReorderItem: (from, to) => onChanged(r.move(from, to)),
              itemBuilder: (context, i) {
                final id = r.order[i];
                final isNext = i == r.next;
                final name = names[id] ?? id;
                return Semantics(
                  key: ValueKey(id),
                  button: !isNext,
                  selected: isNext,
                  label: isNext ? '$name, next' : '$name. Make it next',
                  child: ListTile(
                    minTileHeight: 56,
                    leading: CircleAvatar(
                      radius: 10,
                      backgroundColor: colours[id] ?? Lit.ink,
                    ),
                    title: Text(
                      name,
                      style: LitType.body(
                        18,
                        Lit.ink,
                        isNext ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                    subtitle: isNext
                        ? Text('NEXT', style: LitType.cap(12, Lit.ink))
                        : null,
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                    onTap: isNext ? null : () => onChanged(r.pointAt(id)),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              8,
              20,
              20 + MediaQuery.paddingOf(context).bottom,
            ),
            child: BigButton(
              label:
                  'SKIP ${(names[r.nextId] ?? r.nextId ?? '').toUpperCase()}',
              colour: Lit.ink.withValues(alpha: 0.12),
              ink: Lit.ink,
              fontSize: 24,
              onTap: r.order.length < 2 ? null : () => onChanged(r.skip()),
              semanticLabel: r.nextId == null
                  ? 'Skip'
                  : 'Skip ${names[r.nextId] ?? r.nextId}',
            ),
          ),
        ],
      ),
    );
  }
}
