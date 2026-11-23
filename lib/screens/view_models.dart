import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

/// UI-side view models. Screens render these and report intents through
/// callbacks; one adapter (lib/app, wired at integration) maps the engine's
/// API v0 and the session snapshot onto them. Nothing here does I/O.

/// The five workout types (plan 4.2) and their LIT colours.
enum WorkoutType {
  push('Push', Lit.push),
  pull('Pull', Lit.pull),
  legs('Legs', Lit.legs),
  engine('Engine', Lit.engine),
  core('Core', Lit.core);

  const WorkoutType(this.label, this.colour);
  final String label;
  final Color colour;

  /// Text colour on this type's fill. Engine is dark violet, so it takes white.
  Color get onColour => this == WorkoutType.engine ? Colors.white : Lit.ink;
}

/// One picker row: a group of muscles shown together (b2-picker, M1).
class MuscleGroup {
  const MuscleGroup(this.label, this.muscleIds);
  final String label;
  final List<String> muscleIds;

  /// The eight rows of the approved picker (b2-picker.png). All 16 muscles
  /// are covered exactly once.
  static const List<MuscleGroup> picker = [
    MuscleGroup('Chest', ['chest']),
    MuscleGroup('Shoulders', ['front-delts', 'side-delts', 'rear-delts']),
    MuscleGroup('Triceps', ['triceps']),
    MuscleGroup('Back', ['lats', 'traps', 'lower-back']),
    MuscleGroup('Biceps, forearms', ['biceps', 'forearms']),
    MuscleGroup('Core', ['abs', 'obliques']),
    MuscleGroup('Quads, calves', ['quads', 'calves']),
    MuscleGroup('Glutes, hams', ['glutes', 'hamstrings']),
  ];
}

/// Days-since for one muscle (engine MuscleStatus).
class MuscleDays {
  const MuscleDays({this.days, this.resting = false, this.uncovered = false});

  /// Whole days since the last hard set; null = never trained.
  final int? days;

  /// Under 2 days: shown hatched, still pickable (plan 18).
  final bool resting;

  /// No exercise at this gym can train it (B5).
  final bool uncovered;
}

/// How a load is shown and stepped.
enum LoadUnit { kg, kgEach, bodyweight, timed }

/// One planned exercise in a suggested session.
class PlanItem {
  const PlanItem({
    required this.exerciseId,
    required this.name,
    required this.sets,
    required this.reps,
    required this.loadG,
    required this.unit,
    this.reason = '',
  });
  final String exerciseId;
  final String name;
  final int sets;

  /// Reps, or seconds when [unit] is timed.
  final int reps;

  /// Null = cold start: the logger asks for a starting weight.
  final int? loadG;
  final LoadUnit unit;
  final String reason;
}

class SessionPlanView {
  const SessionPlanView({
    required this.type,
    required this.items,
    required this.minutes,
    this.uncovered = const [],
  });

  /// Null when the pick mixes types: selection then uses ink (plan 18).
  final WorkoutType? type;
  final List<PlanItem> items;
  final int minutes;

  /// Muscle names with no kit here.
  final List<String> uncovered;
}

class GymView {
  const GymView({required this.id, required this.name, required this.kit});
  final String id;
  final String name;
  final Set<String> kit;
}

// ---- formatting shared by every screen ------------------------------------

/// "22", "22.5", "1.25": grams to kg with no trailing zeros.
String kg(int grams) {
  final v = grams / 1000;
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// "22 kg ea", "15 kg", "set kg" (cold start), "" (bodyweight).
String loadLabel(int? grams, LoadUnit unit) {
  switch (unit) {
    case LoadUnit.bodyweight:
    case LoadUnit.timed:
      return '';
    case LoadUnit.kg:
      return grams == null ? 'set kg' : '${kg(grams)} kg';
    case LoadUnit.kgEach:
      return grams == null ? 'set kg' : '${kg(grams)} kg ea';
  }
}

/// "3 × 10 · 22 kg ea", "3 × 0:45".
String prescription(PlanItem p) {
  final work = p.unit == LoadUnit.timed ? clock(p.reps) : '${p.reps}';
  final load = loadLabel(p.loadG, p.unit);
  return load.isEmpty ? '${p.sets} × $work' : '${p.sets} × $work · $load';
}

/// Seconds as m:ss.
String clock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "5 days", "1 day", "today", "new".
String daysLabel(int? days) {
  if (days == null) return 'new';
  if (days == 0) return 'today';
  return days == 1 ? '1 day' : '$days days';
}

/// "7,220".
String thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
