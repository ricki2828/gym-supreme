import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'view_models.dart';

/// Kit ids by section, in display order (b-gym.png). Bodyweight is implied
/// at every gym and never listed. Unknown ids from the catalog fall into
/// "Other" so a new taxonomy id still shows up.
const Map<String, List<String>> kitSections = {
  'Free weights': [
    'dumbbells',
    'adjustable-bench',
    'flat-bench',
    'kettlebells',
    'barbell',
    'squat-rack',
    'plates',
    'ez-bar',
    'trap-bar',
  ],
  'Machines': [
    'cable-stack',
    'overhead-cable-bench',
    'lat-pulldown',
    'seated-row',
    'leg-extension',
    'leg-curl',
    'leg-press',
    'chest-press',
    'shoulder-press',
    'smith',
    'pull-up-bar',
    'dip-station',
  ],
  'Engine': [
    'treadmill',
    'bike',
    'air-bike',
    'rower',
    'ski-machine',
    'sled',
    'wall-ball',
    'box',
  ],
  'Other': ['bands'],
};

class KitItem {
  const KitItem(this.id, this.name);
  final String id;
  final String name;
}

class PresetView {
  const PresetView(this.id, this.name);
  final String id;
  final String name;
}

/// "Where are you training?": first run and gym setup (plan item 1).
/// A preset only pre-ticks; he fixes what differs.
class GymSetupScreen extends StatelessWidget {
  const GymSetupScreen({
    super.key,
    required this.gyms,
    required this.currentGymId,
    required this.kit,
    required this.equipment,
    required this.presets,
    required this.dumbbellMaxG,
    this.firstRun = false,
    this.onPickGym,
    this.onAddGym,
    this.onPreset,
    this.onToggle,
    this.onDumbbellMax,
    this.onSave,
  });

  final List<GymView> gyms;
  final String currentGymId;

  /// Ticked equipment ids for the current gym (the working copy).
  final Set<String> kit;

  /// Every equipment item from the catalog except bodyweight.
  final List<KitItem> equipment;
  final List<PresetView> presets;

  /// Heaviest dumbbell pair at this gym, in grams (Q14: range unknown, so
  /// first run asks).
  final int dumbbellMaxG;
  final bool firstRun;

  final ValueChanged<String>? onPickGym;
  final VoidCallback? onAddGym;
  final ValueChanged<String>? onPreset;
  final ValueChanged<String>? onToggle;

  /// +1 or -1 step of 2.5 kg.
  final ValueChanged<int>? onDumbbellMax;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final e in equipment) e.id: e};
    final listed = {for (final ids in kitSections.values) ...ids};
    final sections = <String, List<KitItem>>{
      for (final s in kitSections.entries)
        s.key: [for (final id in s.value) ?byId[id]],
    };
    final others = [
      for (final e in equipment)
        if (!listed.contains(e.id) && e.id != 'bodyweight') e,
    ];
    sections['Other'] = [...?sections['Other'], ...others];
    final count = kit.where((k) => k != 'bodyweight').length;

    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                children: [
                  Text(
                    'WHERE ARE YOU TRAINING?',
                    style: LitType.display(56),
                    semanticsLabel: 'Where are you training?',
                  ),
                  if (firstRun) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Tick the kit your gym has. Sessions only use what is lit. '
                      'You can change it any time in Gyms.',
                      style: LitType.body(15, Lit.inkSecondary),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _GymCards(
                    gyms: gyms,
                    currentGymId: currentGymId,
                    kitCount: count,
                    onPick: onPickGym,
                    onAdd: onAddGym,
                  ),
                  if (presets.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _PresetBanner(presets: presets, onPreset: onPreset),
                  ],
                  for (final s in sections.entries)
                    if (s.value.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(s.key.toUpperCase(), style: LitType.display(30)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final item in s.value)
                            _KitPill(
                              label: item.id == 'dumbbells'
                                  ? 'Dumbbells to ${kg(dumbbellMaxG)} kg'
                                  : item.name,
                              on: kit.contains(item.id),
                              onTap: onToggle == null
                                  ? null
                                  : () => onToggle!(item.id),
                            ),
                        ],
                      ),
                      if (s.key == 'Free weights' &&
                          kit.contains('dumbbells')) ...[
                        const SizedBox(height: 12),
                        _DumbbellRange(
                          maxG: dumbbellMaxG,
                          onStep: onDumbbellMax,
                        ),
                      ],
                    ],
                  const SizedBox(height: 14),
                  Text(
                    'Tap to add or drop. Plans only use what is lit.',
                    style: LitType.body(14, Lit.inkSecondary),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: BigButton(
                label: 'SAVE · $count ON THE FLOOR',
                colour: Lit.ink,
                ink: Colors.white,
                height: 64,
                fontSize: 34,
                onTap: count == 0 ? null : onSave,
                semanticLabel: 'Save gym, $count bits of kit',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GymCards extends StatelessWidget {
  const _GymCards({
    required this.gyms,
    required this.currentGymId,
    required this.kitCount,
    this.onPick,
    this.onAdd,
  });
  final List<GymView> gyms;
  final String currentGymId;
  final int kitCount;
  final ValueChanged<String>? onPick;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => SizedBox(
    // Grows with large text so a two-line name and the kit line still fit.
    height: MediaQuery.textScalerOf(context).scale(120).clamp(120.0, 190.0),
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final g in gyms) ...[
          _card(g, g.id == currentGymId),
          const SizedBox(width: 12),
        ],
        Semantics(
          button: true,
          label: 'Add a gym',
          excludeSemantics: true,
          child: InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(24),
            child: CustomPaint(
              painter: _DashedRRect(),
              child: const SizedBox(
                width: 64,
                child: Icon(Icons.add, color: Lit.ink, size: 30),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _card(GymView g, bool on) {
    final n = on ? kitCount : g.kit.where((k) => k != 'bodyweight').length;
    final fg = on ? Colors.white : Lit.ink;
    return Semantics(
      button: true,
      selected: on,
      label: '${g.name}, $n bits of kit',
      excludeSemantics: true,
      child: Material(
        color: on ? Lit.ink : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: on
              ? BorderSide.none
              : const BorderSide(color: Lit.hair, width: 2),
        ),
        child: InkWell(
          onTap: onPick == null ? null : () => onPick!(g.id),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            width: 150,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.name.toUpperCase(),
                  style: LitType.display(30, fg),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Text(
                  '$n bits of kit',
                  style: LitType.body(
                    14,
                    on ? const Color(0xFFA5A9B1) : Lit.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetBanner extends StatelessWidget {
  const _PresetBanner({required this.presets, this.onPreset});
  final List<PresetView> presets;
  final ValueChanged<String>? onPreset;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      color: Lit.pull.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Start from a preset? It only pre-ticks.',
          style: LitType.body(15, Lit.ink, FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in presets)
              _KitPill(
                label: p.name,
                on: false,
                outline: true,
                onTap: onPreset == null ? null : () => onPreset!(p.id),
              ),
          ],
        ),
      ],
    ),
  );
}

class _KitPill extends StatelessWidget {
  const _KitPill({
    required this.label,
    required this.on,
    this.onTap,
    this.outline = false,
  });
  final String label;
  final bool on;
  final bool outline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final border = on || outline ? Lit.ink : const Color(0xFFC9CCC5);
    return Semantics(
      button: true,
      selected: outline ? null : on,
      label: outline ? 'Preset: $label' : '$label, ${on ? 'have' : 'not here'}',
      excludeSemantics: true,
      child: Material(
        color: on ? Lit.ink : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: border, width: 2)),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (on) ...[
                    const Icon(Icons.check, size: 18, color: Colors.white),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: LitType.body(
                      17,
                      on
                          ? Colors.white
                          : (outline ? Lit.ink : Lit.inkSecondary),
                      FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DumbbellRange extends StatelessWidget {
  const _DumbbellRange({required this.maxG, this.onStep});
  final int maxG;
  final ValueChanged<int>? onStep;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: Lit.hair, width: 2),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Heaviest dumbbell pair',
            style: LitType.body(15, Lit.ink, FontWeight.w600),
          ),
        ),
        _Step(
          icon: Icons.remove,
          label: 'Lighter',
          onTap: onStep == null ? null : () => onStep!(-1),
        ),
        SizedBox(
          width: 84,
          child: Text(
            '${kg(maxG)} KG',
            textAlign: TextAlign.center,
            style: LitType.display(28),
          ),
        ),
        _Step(
          icon: Icons.add,
          label: 'Heavier',
          onTap: onStep == null ? null : () => onStep!(1),
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: Material(
      color: Lit.ink,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white),
        ),
      ),
    ),
  );
}

class _DashedRRect extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          const Radius.circular(24),
        ),
      );
    final paint = Paint()
      ..color = const Color(0xFFB5B9B2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRect old) => false;
}
