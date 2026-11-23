import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'live_screen.dart' show askNumber;
import 'view_models.dart';

/// One loaded kit item's weights at a gym, for the gym setup list.
class WeightRow {
  const WeightRow({
    required this.id,
    required this.name,
    required this.weightsG,
    this.perHand = false,
    this.fromDefaults = false,
  });
  final String id;
  final String name;

  /// Ascending, grams.
  final List<int> weightsG;

  /// Dumbbells and kettlebells: one weight per hand ("kg ea").
  final bool perHand;

  /// He has not set them: these are the app's fallback list.
  final bool fromDefaults;

  /// "2–24 kg ea · 12 pairs", "5–100 kg · 20 pins".
  String get summary {
    if (weightsG.isEmpty) return 'none set';
    final range = weightsG.length == 1
        ? '${kg(weightsG.first)} kg'
        : '${kg(weightsG.first)}–${kg(weightsG.last)} kg';
    final n = weightsG.length;
    final what = perHand
        ? (n == 1 ? 'pair' : 'pairs')
        : (n == 1 ? 'weight' : 'weights');
    return '$range${perHand ? ' ea' : ''} · $n $what';
  }
}

/// Edit the weights one kit item really has (P1-2): the cable stack's pin
/// steps, the dumbbell pairs on the rack. +/- and progression only use
/// these; a typed weight off the list is still logged as lifted.
class WeightListScreen extends StatefulWidget {
  const WeightListScreen({super.key, required this.row});
  final WeightRow row;

  @override
  State<WeightListScreen> createState() => _WeightListScreenState();
}

class _WeightListScreenState extends State<WeightListScreen> {
  late final Set<int> _w = {...widget.row.weightsG};

  String get _unit => widget.row.perHand ? 'kg ea' : 'kg';

  Future<void> _addOne() async {
    final v = await askNumber(
      context,
      title: 'Add a weight',
      unit: _unit,
      decimals: true,
    );
    if (v == null || v <= 0) return;
    setState(() => _w.add((v * 1000).round()));
  }

  Future<void> _fill() async {
    final from = await askNumber(
      context,
      title: 'From',
      unit: 'kg',
      decimals: true,
      initial: widget.row.perHand ? 2 : 5,
    );
    if (from == null || !mounted) return;
    final to = await askNumber(
      context,
      title: 'To',
      unit: 'kg',
      decimals: true,
      initial: widget.row.perHand ? 24 : 100,
    );
    if (to == null || !mounted) return;
    final step = await askNumber(
      context,
      title: 'Step',
      unit: 'kg',
      decimals: true,
      initial: widget.row.perHand ? 2 : 5,
      max: 50,
    );
    if (step == null || step <= 0) return;
    final a = (from * 1000).round();
    final b = (to * 1000).round();
    final st = (step * 1000).round();
    if (a <= 0 || st <= 0 || b < a || (b - a) ~/ st > 200) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('That range does not work: check from, to and step.'),
          ),
        );
      }
      return;
    }
    setState(() {
      for (var g = a; g <= b; g += st) {
        _w.add(g);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _w.toList()..sort();
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        foregroundColor: Lit.ink,
        title: Text(widget.row.name.toUpperCase(), style: LitType.display(30)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  Text(
                    widget.row.perHand
                        ? 'The pairs on the rack. Tap one to drop it.'
                        : 'The weights it really has (pin steps). Tap one to '
                              'drop it.',
                    style: LitType.body(15, Lit.inkSecondary),
                  ),
                  if (widget.row.fromDefaults) ...[
                    const SizedBox(height: 6),
                    Text(
                      'These are the app\'s guesses until you set yours.',
                      style: LitType.body(14, Lit.inkQuiet, FontWeight.w600),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (sorted.isEmpty)
                    Text(
                      'None yet. Add weights or fill a range.',
                      style: LitType.body(15, Lit.ink),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in sorted)
                        Semantics(
                          button: true,
                          label: '${kg(g)} $_unit',
                          onTapHint: 'remove',
                          excludeSemantics: true,
                          onTap: () => setState(() => _w.remove(g)),
                          child: Material(
                            color: Lit.ink,
                            shape: const StadiumBorder(),
                            child: InkWell(
                              onTap: () => setState(() => _w.remove(g)),
                              customBorder: const StadiumBorder(),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                  minWidth: 64,
                                ),
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                decoration: const ShapeDecoration(
                                  color: Colors.transparent,
                                  shape: StadiumBorder(),
                                ),
                                child: Text(
                                  kg(g),
                                  style: LitType.display(26, Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _addOne,
                          icon: const Icon(Icons.add),
                          label: const Text('Add one'),
                          style: _outline,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _fill,
                          icon: const Icon(Icons.linear_scale),
                          label: const Text('Fill a range'),
                          style: _outline,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: sorted.isEmpty ? null : () => setState(_w.clear),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: BigButton(
                label: 'SAVE · ${sorted.length}',
                colour: Lit.ink,
                ink: Colors.white,
                height: 60,
                fontSize: 32,
                onTap: sorted.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(sorted),
                semanticLabel: 'Save ${sorted.length} weights',
              ),
            ),
          ],
        ),
      ),
    );
  }

  static final ButtonStyle _outline = OutlinedButton.styleFrom(
    foregroundColor: Lit.ink,
    minimumSize: const Size.fromHeight(52),
    side: const BorderSide(color: Lit.ink, width: 2),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  );
}
