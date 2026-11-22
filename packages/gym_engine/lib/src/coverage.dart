import 'catalog.dart';

/// Per muscle: the exercises a kit can do for it as a primary mover.
class CoverageReport {
  CoverageReport(this.byMuscle);
  final Map<String, List<Exercise>> byMuscle;

  List<String> get covered => [
    for (final e in byMuscle.entries)
      if (e.value.isNotEmpty) e.key,
  ];

  /// Muscles with no valid exercise at this kit. The picker says so (plan B5).
  List<String> get uncovered => [
    for (final e in byMuscle.entries)
      if (e.value.isEmpty) e.key,
  ];
}

/// Offers only exercises whose equipment set is fully present, and reports
/// every muscle as covered or uncovered. Muscle order follows the catalog.
CoverageReport coverageFor(Catalog catalog, Set<String> kit) {
  final ok = [
    for (final e in catalog.exercises)
      if (e.availableWith(kit)) e,
  ];
  return CoverageReport({
    for (final m in catalog.muscles)
      m.id: [
        for (final e in ok)
          if (e.primary.contains(m.id)) e,
      ],
  });
}
