import 'dart:convert';

/// One of the 16 muscles. Ids are permanent slugs.
class Muscle {
  const Muscle(this.id, this.name);
  final String id;
  final String name;
}

class Equipment {
  const Equipment(this.id, this.name, this.load);
  final String id;
  final String name;
  final String load;
}

class Preset {
  const Preset({
    required this.id,
    required this.name,
    required this.equipment,
    required this.notes,
  });
  final String id;
  final String name;
  final Set<String> equipment;
  final String notes;
}

class Exercise {
  const Exercise({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.equipmentSets,
    required this.load,
    required this.unilateral,
    required this.cue,
  });
  final String id;
  final String name;
  final List<String> primary;
  final List<String> secondary;

  /// `any of [all of ...]`: offered only if one set is fully present.
  final List<Set<String>> equipmentSets;
  final String load;
  final bool unilateral;
  final String cue;

  /// Bodyweight is present at every gym.
  bool availableWith(Set<String> kit) {
    final have = {...kit, bodyweight};
    return equipmentSets.any(have.containsAll);
  }
}

const String bodyweight = 'bodyweight';

class Catalog {
  Catalog({
    required this.muscles,
    required this.equipment,
    required this.presets,
    required this.exercises,
  });

  /// Parses the two asset files (`exercises_taxonomy.json`, `exercises.json`).
  /// Throws [FormatException] on an unknown muscle or equipment id.
  factory Catalog.fromJson(String taxonomyJson, String exercisesJson) {
    final tax = jsonDecode(taxonomyJson) as Map<String, dynamic>;
    final cat = jsonDecode(exercisesJson) as Map<String, dynamic>;
    final muscles = [
      for (final m in tax['muscles'] as List)
        Muscle((m as Map)['id'] as String, m['name'] as String),
    ];
    final equipment = [
      for (final e in tax['equipment'] as List)
        Equipment(
          (e as Map)['id'] as String,
          e['name'] as String,
          e['load'] as String,
        ),
    ];
    final presets = [
      for (final p in tax['presets'] as List)
        Preset(
          id: (p as Map)['id'] as String,
          name: p['name'] as String,
          equipment: {for (final e in p['equipment'] as List) e as String},
          notes: (p['notes'] as String?) ?? '',
        ),
    ];
    final exercises = [
      for (final e in cat['exercises'] as List)
        Exercise(
          id: (e as Map)['id'] as String,
          name: e['name'] as String,
          primary: [for (final m in e['primary'] as List) m as String],
          secondary: [for (final m in e['secondary'] as List) m as String],
          equipmentSets: [
            for (final s in e['equipment_sets'] as List)
              {for (final x in s as List) x as String},
          ],
          load: e['load'] as String,
          unilateral: e['unilateral'] as bool,
          cue: e['cue'] as String,
        ),
    ];
    final c = Catalog(
      muscles: muscles,
      equipment: equipment,
      presets: presets,
      exercises: exercises,
    );
    final problems = c.validate();
    if (problems.isNotEmpty) {
      throw FormatException('invalid exercise catalog: ${problems.join('; ')}');
    }
    return c;
  }

  final List<Muscle> muscles;
  final List<Equipment> equipment;
  final List<Preset> presets;
  final List<Exercise> exercises;

  Preset preset(String id) => presets.firstWhere((p) => p.id == id);

  /// Unknown ids, duplicate ids, wrong muscle count. Empty means valid.
  List<String> validate() {
    final problems = <String>[];
    final muscleIds = {for (final m in muscles) m.id};
    final equipIds = {for (final e in equipment) e.id};
    if (muscleIds.length != 16) {
      problems.add('expected 16 muscles, found ${muscleIds.length}');
    }
    final seen = <String>{};
    for (final e in exercises) {
      if (!seen.add(e.id)) problems.add('duplicate exercise id ${e.id}');
      if (e.primary.isEmpty) problems.add('${e.id}: no primary muscle');
      for (final m in [...e.primary, ...e.secondary]) {
        if (!muscleIds.contains(m)) problems.add('${e.id}: unknown muscle $m');
      }
      if (e.equipmentSets.isEmpty || e.equipmentSets.any((s) => s.isEmpty)) {
        problems.add('${e.id}: empty equipment set');
      }
      for (final s in e.equipmentSets) {
        for (final q in s) {
          if (!equipIds.contains(q)) {
            problems.add('${e.id}: unknown equipment $q');
          }
        }
      }
    }
    for (final p in presets) {
      for (final q in p.equipment) {
        if (!equipIds.contains(q)) {
          problems.add('preset ${p.id}: unknown equipment $q');
        }
      }
    }
    return problems;
  }
}
