/// Display text for the cut-2 widgets, kept in pure Dart so it is tested on
/// the host (the widgets stay thin and stateless). Plain words, kg, "ea" for
/// dumbbells (design review 18).
library;

import 'ghost.dart';
import 'plates.dart';
import 'rotation.dart';
import 'timers.dart';

// ---- ghost ----------------------------------------------------------------

/// "22.5 × 10" / "× 8" (bodyweight) / "22.5 kg" (no reps). [perHand] adds
/// " ea" for dumbbells.
String loadReps(int? loadG, int? reps, {bool perHand = false}) {
  final kg = loadG == null || loadG == 0 ? null : formatKg(loadG);
  final ea = perHand ? ' ea' : '';
  if (kg != null && reps != null) return '$kg$ea × $reps';
  if (reps != null) return '× $reps';
  if (kg != null) return '$kg kg$ea';
  return '';
}

/// The line under the current or a done set: "Last time 22.5 × 10 · +2.5 kg".
/// Null when there is nothing to say (new set with no ghost values).
String? ghostSetText(SetGhostLine l, {bool perHand = false}) {
  if (l.verdict == GhostVerdict.newSet) return 'New set — none last time';
  final then = loadReps(l.ghostLoadG, l.ghostReps, perHand: perHand);
  if (then.isEmpty) return null;
  if (l.baseline) return 'Starting weight $then';
  final deltas = <String>[
    if (l.loadDeltaG case final d? when d != 0)
      '${d > 0 ? '+' : '−'}${formatKg(d.abs())} kg',
    if (l.repsDelta case final d? when d != 0)
      '${d > 0 ? '+' : '−'}${d.abs()} ${d.abs() == 1 ? 'rep' : 'reps'}',
  ];
  final tail = switch (l.verdict) {
    GhostVerdict.pending => '',
    GhostVerdict.level => ' · level',
    _ when deltas.isEmpty => '',
    _ => ' · ${deltas.join(', ')}',
  };
  return 'Last time $then$tail';
}

/// Screen-reader label: words, no symbols.
String ghostSetSemantics(SetGhostLine l) => switch (l.verdict) {
  _ when l.baseline =>
    'Your starting weight, ${_spoken(l.ghostLoadG, l.ghostReps)}',
  GhostVerdict.newSet => 'No set at this number last time',
  GhostVerdict.pending when _spoken(l.ghostLoadG, l.ghostReps).isEmpty =>
    'No values from last time',
  GhostVerdict.pending => 'Last time ${_spoken(l.ghostLoadG, l.ghostReps)}',
  GhostVerdict.ahead =>
    'Ahead of last time, ${_spoken(l.ghostLoadG, l.ghostReps)}',
  GhostVerdict.behind =>
    'Behind last time, ${_spoken(l.ghostLoadG, l.ghostReps)}',
  GhostVerdict.level =>
    'Level with last time, ${_spoken(l.ghostLoadG, l.ghostReps)}',
};

String _spoken(int? loadG, int? reps) => [
  if (loadG != null && loadG != 0) '${formatKg(loadG)} kilos',
  if (reps != null) '$reps reps',
].join(' for ');

/// The session-total line (N3): "+11% on last time · 2 lifts compared".
/// Null when hidden (no ghost) or before any compared set is done.
String? sessionTotalText(SessionGhostTotal? t) {
  if (t == null || t.ghostSoFarGReps == 0 && t.volumeGReps == 0) return null;
  final lifts =
      '${t.exercisesCompared} ${t.exercisesCompared == 1 ? 'lift' : 'lifts'}';
  final pct = t.deltaPct;
  if (pct == null) return 'Volume ${_tonnes(t.volumeGReps)} · $lifts compared';
  final r = pct.round();
  final head = r == 0
      ? 'Level with last time'
      : '${r > 0 ? '+' : '−'}${r.abs()}% on last time';
  return '$head · $lifts compared';
}

/// gram-reps → "1,240 kg" (load volume in kg-reps, rounded).
String _tonnes(int gReps) {
  final kg = (gReps / 1000).round();
  final s = kg.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b kg';
}

// ---- rotation -------------------------------------------------------------

/// The chip on the session sheet: "Next: Pull · then Legs, Push".
/// [names] maps type id → display name; unknown ids show the id.
String? rotationChipText(Rotation r, Map<String, String> names) {
  final up = r.upcoming;
  if (up.isEmpty) return null;
  String n(String id) => names[id] ?? id;
  if (up.length == 1) return 'Next: ${n(up.first)}';
  return 'Next: ${n(up.first)} · then ${up.skip(1).map(n).join(', ')}';
}

// ---- timers ---------------------------------------------------------------

/// Big label over the countdown.
String timerPhaseText(TimerBlock b, TimerState s) => switch (s.phase) {
  TimerPhase.leadIn => 'GET READY',
  TimerPhase.done => 'DONE',
  TimerPhase.rest => 'REST',
  TimerPhase.work => switch (b.type) {
    TimerType.amrap => 'AMRAP',
    TimerType.emom => 'EMOM',
    TimerType.interval => 'WORK',
  },
};

/// Small line under it: "Round 3 of 20 · 14:12 left".
String timerRoundText(TimerBlock b, TimerState s) {
  final left = '${formatClock(s.totalRemainingMs)} left';
  return switch (s.phase) {
    TimerPhase.done => b.title,
    TimerPhase.leadIn =>
      '${b.title} · starts in '
          '${formatClock(s.phaseRemainingMs)}',
    _ when b.type == TimerType.amrap => left,
    _ => 'Round ${s.round} of ${s.rounds} · $left',
  };
}

/// Plate line for a barbell set: "Per side 20 + 2.5" or the nearest loads.
String plateText(PlateResult r) {
  final e = r.exact;
  if (e != null) return 'Per side ${e.perSideLabel}';
  final opts = [
    if (r.below case final b?) '${formatKg(b.totalG)} (${b.perSideLabel})',
    if (r.above case final a?) '${formatKg(a.totalG)} (${a.perSideLabel})',
  ];
  if (opts.isEmpty) return 'Can’t load this';
  return 'Can’t make it exactly. Nearest: ${opts.join(' or ')}';
}
