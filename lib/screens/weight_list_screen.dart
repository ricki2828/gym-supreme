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

/// One bar or the plates at a gym, for the setup list (0.3 P1). Not a
/// [WeightRow]: a bar is one weight and plates are counted in pairs.
class PlateRow {
  const PlateRow({
    required this.id,
    required this.name,
    required this.summary,
    this.fromDefaults = false,
  });
  final String id;
  final String name;

  /// "20 kg bar", "2 × 20 · 1 × 10 kg a side".
  final String summary;

  /// He has not said: the app uses a standard bar and unlimited plates.
  final bool fromDefaults;
}

/// Plate sizes the pairs editor offers, in grams, ascending. A size he
/// already stored that is not here is shown too.
const List<int> plateChoicesG = [1250, 2500, 5000, 10000, 15000, 20000, 25000];

/// Most pairs of one size the editor counts.
const int maxPlatePairs = 10;

/// How many pairs of each size the gym has (0.3 P1). Returns the list the
/// engine stores for kit id `plates`: one entry per pair, ascending, so a
/// size twice is two pairs. An empty list means "not said": standard plates.
class PlatePairsScreen extends StatefulWidget {
  const PlatePairsScreen({super.key, required this.pairsG});

  /// The stored list (one entry per pair).
  final List<int> pairsG;

  @override
  State<PlatePairsScreen> createState() => _PlatePairsScreenState();
}

class _PlatePairsScreenState extends State<PlatePairsScreen> {
  final Map<int, int> _n = {};

  @override
  void initState() {
    super.initState();
    for (final g in widget.pairsG) {
      _n[g] = (_n[g] ?? 0) + 1;
    }
  }

  List<int> get _sizes => {...plateChoicesG, ..._n.keys}.toList()..sort();

  List<int> get _list => [
    for (final s in _sizes)
      for (var i = 0; i < (_n[s] ?? 0); i++) s,
  ];

  void _step(int size, int d) => setState(() {
    final v = ((_n[size] ?? 0) + d).clamp(0, maxPlatePairs);
    if (v == 0) {
      _n.remove(size);
    } else {
      _n[size] = v;
    }
  });

  @override
  Widget build(BuildContext context) {
    final total = _list.length;
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        foregroundColor: Lit.ink,
        title: Text('PLATES', style: LitType.display(30)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  Text(
                    'How many pairs of each plate the rack has. Barbell loads '
                    'only use what you set.',
                    style: LitType.body(15, Lit.inkSecondary),
                  ),
                  const SizedBox(height: 10),
                  for (final s in _sizes)
                    _PairRow(
                      size: s,
                      pairs: _n[s] ?? 0,
                      onMinus: () => _step(s, -1),
                      onPlus: () => _step(s, 1),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: BigButton(
                label: total == 0 ? 'SAVE · STANDARD' : 'SAVE · $total PAIRS',
                colour: Lit.ink,
                ink: Colors.white,
                height: 60,
                fontSize: 32,
                onTap: () => Navigator.of(context).pop(_list),
                semanticLabel: total == 0
                    ? 'Save, no plates listed so standard plates'
                    : 'Save $total pairs of plates',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairRow extends StatelessWidget {
  const _PairRow({
    required this.size,
    required this.pairs,
    required this.onMinus,
    required this.onPlus,
  });
  final int size;
  final int pairs;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final name = '${kg(size)} kg';
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Lit.hair)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: LitType.body(18, Lit.ink, FontWeight.w700),
            ),
          ),
          IconButton(
            key: Key('plates.minus.$size'),
            tooltip: 'Fewer $name pairs',
            onPressed: pairs == 0 ? null : onMinus,
            icon: const Icon(Icons.remove),
            iconSize: 28,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$pairs',
              key: Key('plates.count.$size'),
              textAlign: TextAlign.center,
              style: LitType.display(30),
            ),
          ),
          IconButton(
            key: Key('plates.plus.$size'),
            tooltip: 'More $name pairs',
            onPressed: pairs >= maxPlatePairs ? null : onPlus,
            icon: const Icon(Icons.add),
            iconSize: 28,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }
}

/// "2 × 20 · 1 × 10 kg a side" from the stored pair list, largest first.
String platePairsSummary(List<int> pairsG) {
  if (pairsG.isEmpty) return 'standard plates';
  final n = <int, int>{};
  for (final g in pairsG) {
    n[g] = (n[g] ?? 0) + 1;
  }
  final sizes = n.keys.toList()..sort((a, b) => b.compareTo(a));
  final parts = [for (final s in sizes) '${n[s]} × ${kg(s)}'];
  return '${parts.join(' · ')} kg a side';
}
