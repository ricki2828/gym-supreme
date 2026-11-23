import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../lit_widgets.dart';

/// AMRAP result, entered at the end (R4).
typedef AmrapResult = ({int rounds, int extraReps});

/// Asks for full rounds and reps into the next round. Null on cancel.
Future<AmrapResult?> askAmrapResult(BuildContext context) =>
    showDialog<AmrapResult>(
      context: context,
      builder: (_) => const _AmrapDialog(),
    );

class _AmrapDialog extends StatefulWidget {
  const _AmrapDialog();
  @override
  State<_AmrapDialog> createState() => _AmrapDialogState();
}

class _AmrapDialogState extends State<_AmrapDialog> {
  final _rounds = TextEditingController();
  final _reps = TextEditingController(text: '0');

  @override
  void dispose() {
    _rounds.dispose();
    _reps.dispose();
    super.dispose();
  }

  int? _parse(TextEditingController c) {
    final v = int.tryParse(c.text.trim());
    return v == null || v < 0 || v > 999 ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final rounds = _parse(_rounds);
    final reps = _parse(_reps);
    Widget field(String label, TextEditingController c, {bool auto = false}) =>
        TextField(
          controller: c,
          autofocus: auto,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          decoration: InputDecoration(labelText: label),
          style: LitType.display(32),
          onChanged: (_) => setState(() {}),
        );
    return AlertDialog(
      backgroundColor: Lit.ground,
      title: Text('HOW MANY ROUNDS?', style: LitType.display(26)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          field('Full rounds', _rounds, auto: true),
          const SizedBox(height: 8),
          field('Reps into the next round', _reps),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: rounds == null || reps == null
              ? null
              : () =>
                    Navigator.of(context)
                        .pop((rounds: rounds, extraReps: reps)),
          child: const Text('Log it'),
        ),
      ],
    );
  }
}
