import 'dart:convert';

import 'package:gym_engine/gym_engine.dart' as eng;

/// Pure view models for the Progress tab (G1b). No widgets here: the adapter
/// [buildProgress] turns the strength analysis and the local profile into
/// what the screen draws, with an injected clock.

const int staleBodyweightDays = 60;
const int trendWeeks = 12;
const String profileKey = 'profile';
const String confirmedKey = 'strength_confirmed';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "2026-08-03" from a date.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Today's local calendar date (by the phone's offset) as "YYYY-MM-DD".
String todayIso(int nowMs, int tzOffsetMin) => isoDate(
  DateTime.fromMillisecondsSinceEpoch(nowMs + tzOffsetMin * 60000, isUtc: true),
);

DateTime? _parseIso(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime.utc(y, mo, d);
}

/// "3 Aug" (this year) or "3 Aug 2025".
String dateLabel(String iso, {String? today}) {
  final d = _parseIso(iso);
  if (d == null) return iso;
  final base = '${d.day} ${_months[d.month - 1]}';
  final t = today == null ? null : _parseIso(today);
  return t != null && t.year == d.year ? base : '$base ${d.year}';
}

/// "92", "92.5": one decimal only when there is one.
String kgText(double kg) {
  final r = (kg * 10).round() / 10;
  return r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
}

class BodyweightEntry {
  const BodyweightEntry(this.date, this.grams);

  /// "YYYY-MM-DD", the day he weighed in.
  final String date;
  final int grams;

  double get kg => grams / 1000;
}

/// The bodyweight the cards divide by, and how fresh it is.
class BodyweightRef {
  const BodyweightRef({required this.kg, this.date, this.ageDays});
  final double kg;

  /// Null for the old undated setting.
  final String? date;
  final int? ageDays;

  bool get stale => ageDays != null && ageDays! > staleBodyweightDays;
}

/// Birth year, sex and the bodyweight log. Local only: one JSON value under
/// the `profile` setting key (no schema change, nothing leaves the phone).
class Profile {
  const Profile({this.birthYear, this.sex, this.log = const []});

  final int? birthYear;

  /// `male`, `female`, or null (not set).
  final String? sex;

  /// Oldest first.
  final List<BodyweightEntry> log;

  bool get isEmpty => birthYear == null && sex == null && log.isEmpty;

  Profile copyWith({
    Object? birthYear = _keep,
    Object? sex = _keep,
    List<BodyweightEntry>? log,
  }) => Profile(
    birthYear: identical(birthYear, _keep) ? this.birthYear : birthYear as int?,
    sex: identical(sex, _keep) ? this.sex : sex as String?,
    log: log ?? this.log,
  );

  /// Adds or replaces the entry for [date]; the log stays sorted.
  Profile withWeighIn(String date, int grams) => copyWith(
    log: [
      for (final e in log)
        if (e.date != date) e,
      BodyweightEntry(date, grams),
    ]..sort((a, b) => a.date.compareTo(b.date)),
  );

  Profile withoutWeighIn(String date) => copyWith(
    log: [
      for (final e in log)
        if (e.date != date) e,
    ],
  );

  /// The newest entry on or before [today]. [legacyG] (the old undated
  /// `Settings.bodyweightG`) is the fallback when the log is empty; it is
  /// never called stale because its age is unknown.
  BodyweightRef? bodyweight(String today, {int? legacyG}) {
    final t = _parseIso(today);
    BodyweightEntry? best;
    for (final e in log) {
      if (e.date.compareTo(today) <= 0) best = e;
    }
    if (best == null) {
      if (legacyG != null && legacyG > 0) {
        return BodyweightRef(kg: legacyG / 1000);
      }
      return null;
    }
    final d = _parseIso(best.date);
    return BodyweightRef(
      kg: best.kg,
      date: best.date,
      ageDays: d == null || t == null ? null : t.difference(d).inDays,
    );
  }

  String toJsonText() => jsonEncode({
    'v': 1,
    if (birthYear != null) 'birth_year': birthYear,
    if (sex != null) 'sex': sex,
    'bodyweight': [
      for (final e in log) {'d': e.date, 'g': e.grams},
    ],
  });

  /// Tolerant: anything unreadable is dropped, never thrown.
  static Profile parse(String? text) {
    if (text == null || text.isEmpty) return const Profile();
    try {
      final j = jsonDecode(text);
      if (j is! Map) return const Profile();
      final by = j['birth_year'];
      final sx = j['sex'];
      final log = <BodyweightEntry>[];
      final raw = j['bodyweight'];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final d = e['d'], g = e['g'];
          if (d is String && _parseIso(d) != null && g is int && g > 0) {
            log.add(BodyweightEntry(d, g));
          }
        }
      }
      log.sort((a, b) => a.date.compareTo(b.date));
      return Profile(
        birthYear: by is int ? by : null,
        sex: sx == 'male' || sx == 'female' ? sx as String : null,
        log: log,
      );
    } on Object {
      return const Profile();
    }
  }

  static Profile load(eng.HistoryStore? store) {
    if (store == null) return const Profile();
    try {
      return parse(store.setting(profileKey));
    } on Object {
      return const Profile();
    }
  }

  void save(eng.HistoryStore store) =>
      store.saveSetting(profileKey, toJsonText());
}

const Object _keep = Object();

/// Set ids he confirmed after a typo flag (stored under `strength_confirmed`).
Set<String> loadConfirmed(eng.HistoryStore? store) {
  if (store == null) return {};
  try {
    final t = store.setting(confirmedKey);
    if (t == null) return {};
    return {
      for (final x in jsonDecode(t) as List)
        if (x is String) x,
    };
  } on Object {
    return {};
  }
}

void saveConfirmed(eng.HistoryStore store, Set<String> ids) =>
    store.saveSetting(confirmedKey, jsonEncode(ids.toList()..sort()));

/// One set the strength numbers ignored, with the reason in plain words.
class IgnoredSet {
  const IgnoredSet({
    required this.setId,
    required this.when,
    required this.what,
    required this.reason,
    this.canConfirm = false,
  });
  final String setId;
  final String when;

  /// "60 kg × 5".
  final String what;
  final String reason;

  /// Typo-flagged: he can confirm it is right.
  final bool canConfirm;
}

String reasonText(eng.RejectReason r) => switch (r) {
  eng.RejectReason.workoutDeleted => 'Workout deleted',
  eng.RejectReason.skipped => 'Skipped',
  eng.RejectReason.timed => 'Timed set',
  eng.RejectReason.noLoad => 'No weight logged',
  eng.RejectReason.noReps => 'No reps logged',
  eng.RejectReason.warmUp => 'Warm-up',
  eng.RejectReason.coldStart =>
    'First session at this gym: the weight was a guess',
  eng.RejectReason.repsOver12 => 'Over 12 reps: too many to estimate',
  eng.RejectReason.typoUnconfirmed =>
    'Big jump from your recent best: is it right?',
};

/// One lift on the Strength list.
class LiftCard {
  const LiftCard({
    required this.key,
    required this.name,
    this.gymName,
    this.bestKg,
    this.rough = false,
    this.solidKg,
    this.bestDate,
    this.ratio,
    this.trend = const [],
    this.ignored = const [],
    this.firstAtGym = false,
    this.sessions = 0,
  });

  /// `exerciseId` or `exerciseId@gymId` for a stack lift.
  final String key;
  final String name;

  /// Set for stack lifts: the numbers belong to this gym.
  final String? gymName;

  /// Null when no set has counted yet (e.g. only a first session at a gym).
  final double? bestKg;

  /// The best is an 11-12 rep estimate.
  final bool rough;

  /// Best estimate from 10 reps or fewer; null when only rough sets exist.
  final double? solidKg;
  final String? bestDate;

  /// Best e1RM over bodyweight; null without a bodyweight.
  final double? ratio;

  /// [trendWeeks] weekly bests (kg), oldest first; null = no session.
  final List<double?> trend;
  final List<IgnoredSet> ignored;
  final bool firstAtGym;
  final int sessions;

  int get trendPoints => trend.where((v) => v != null).length;
  bool get hasTypoFlag => ignored.any((s) => s.canConfirm);
}

class PbRow {
  const PbRow({
    required this.lift,
    required this.kg,
    required this.date,
    this.gainKg,
  });
  final String lift;
  final double kg;
  final String date;

  /// Null for a lift's first best.
  final double? gainKg;
}

class MuscleSets {
  const MuscleSets({
    required this.name,
    required this.thisWeek,
    required this.lastWeek,
    required this.primary,
    required this.secondary,
  });
  final String name;
  final int thisWeek;
  final int lastWeek;
  final int primary;
  final int secondary;
}

class WeekVolume {
  const WeekVolume(this.label, this.kgReps, this.workouts);
  final String label;
  final double kgReps;
  final int workouts;
}

class ProgressView {
  const ProgressView({
    required this.cards,
    required this.weeks,
    required this.muscles,
    required this.pbs,
    required this.flagged,
    required this.profile,
    required this.bodyweight,
    required this.today,
    required this.sessions,
  });

  final List<LiftCard> cards;
  final List<WeekVolume> weeks;
  final List<MuscleSets> muscles;
  final List<PbRow> pbs;

  /// Every typo-flagged set in the window, with its lift name in [what].
  final List<(String lift, IgnoredSet set)> flagged;
  final Profile profile;
  final BodyweightRef? bodyweight;
  final String today;

  /// Workouts in the last 90 days.
  final int sessions;

  bool get isEmpty => cards.isEmpty && sessions == 0;

  /// One or two sessions: trends and bests are still thin.
  bool get firstData => !isEmpty && sessions < 3;
}

const _dayMs = 86400000;

/// Builds the Progress view. [workouts] are the stored (live) workouts.
ProgressView buildProgress({
  required List<eng.WorkoutRecord> workouts,
  required eng.Catalog catalog,
  required Map<String, String> gymNames,
  required Profile profile,
  required int nowMs,
  required int tzOffsetMin,
  int? legacyBodyweightG,
  Set<String> confirmed = const {},
}) {
  final today = todayIso(nowMs, tzOffsetMin);
  final bw = profile.bodyweight(today, legacyG: legacyBodyweightG);
  final analysis = eng.StrengthAnalysis(
    workouts: workouts,
    catalog: catalog,
    nowMs: nowMs,
    confirmedSetIds: confirmed,
  );
  final windowFrom = nowMs - eng.strengthWindowDays * _dayMs;
  bool inWindow(int ms) => ms >= windowFrom && ms <= nowMs;

  bool perGym(String id) => catalog.exercise(id)?.load == 'stack';
  String keyOf(String id, String gym) => perGym(id) ? '$id@$gym' : id;
  String nameOf(String id) => catalog.exercise(id)?.name ?? id;
  String dayOf(int ms) => dateLabel(todayIso(ms, tzOffsetMin), today: today);

  // Every lift seen anywhere (PBs are all-time), and those in the window.
  final lifts = <String, (String ex, String? gym)>{};
  final windowKeys = <String>{};
  final verdictsByKey = <String, List<eng.SetVerdict>>{};
  for (final v in analysis.verdicts) {
    final ex = v.set.exerciseId;
    final k = keyOf(ex, v.gymId);
    lifts[k] = (ex, perGym(ex) ? v.gymId : null);
    if (inWindow(v.startedAtMs)) {
      windowKeys.add(k);
      (verdictsByKey[k] ??= []).add(v);
    }
  }

  IgnoredSet ignoredOf(eng.SetVerdict v) {
    final s = v.set;
    final what = s.loadG != null && s.reps != null
        ? '${kgText(s.loadG! / 1000)} kg × ${s.reps}'
        : s.reps != null
        ? '${s.reps} reps'
        : s.loadG != null
        ? '${kgText(s.loadG! / 1000)} kg'
        : 'set ${s.setOrdinal}';
    return IgnoredSet(
      setId: s.setId,
      when: dayOf(v.startedAtMs),
      what: what,
      reason: reasonText(v.reason!),
      canConfirm: v.reason == eng.RejectReason.typoUnconfirmed,
    );
  }

  // Week buckets for the trend, newest week last.
  final offsetMs = tzOffsetMin * 60000;
  int weekIndex(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms + offsetMs, isUtc: true);
    final mon = DateTime.utc(
      d.year,
      d.month,
      d.day,
    ).subtract(Duration(days: d.weekday - DateTime.monday));
    return mon.millisecondsSinceEpoch ~/ (7 * _dayMs);
  }

  final nowWeek = weekIndex(nowMs);
  final cards = <LiftCard>[];
  final flagged = <(String, IgnoredSet)>[];
  for (final k in windowKeys) {
    final (ex, gym) = lifts[k]!;
    final es = analysis.bestFor(ex, gymId: gym);
    final verdicts = verdictsByKey[k]!;
    final ignored = [
      for (final v in verdicts.reversed)
        if (v.rejected) ignoredOf(v),
    ];
    for (final i in ignored) {
      if (i.canConfirm) flagged.add((nameOf(ex), i));
    }
    final trend = List<double?>.filled(trendWeeks, null);
    var sessions = 0;
    if (es != null) {
      sessions = es.points.length;
      for (final p in es.points) {
        final back = nowWeek - weekIndex(p.startedAtMs);
        if (back < 0 || back >= trendWeeks) continue;
        final i = trendWeeks - 1 - back;
        final kg = p.e1rm.kg;
        if (trend[i] == null || kg > trend[i]!) trend[i] = kg;
      }
    }
    final best = es?.best;
    cards.add(
      LiftCard(
        key: k,
        name: nameOf(ex),
        gymName: gym == null ? null : (gymNames[gym] ?? 'this gym'),
        bestKg: best?.e1rm.kg,
        rough: best?.e1rm.rough ?? false,
        solidKg: es?.bestSolid?.e1rm.kg,
        bestDate: best == null ? null : dayOf(best.startedAtMs),
        ratio: best != null && bw != null && bw.kg > 0
            ? best.e1rm.kg / bw.kg
            : null,
        trend: trend,
        ignored: ignored,
        firstAtGym: verdicts.any((v) => v.reason == eng.RejectReason.coldStart),
        sessions: sessions,
      ),
    );
  }
  // Heaviest lifts first; lifts with nothing counted yet go last.
  cards.sort((a, b) {
    final c = (b.bestKg ?? -1).compareTo(a.bestKg ?? -1);
    return c != 0 ? c : a.name.compareTo(b.name);
  });

  // PBs: all-time per lift, newest first.
  final pbRows = <(int, PbRow)>[];
  for (final k in lifts.keys) {
    final (ex, gym) = lifts[k]!;
    for (final e in analysis.pbHistory(ex, gymId: gym)) {
      pbRows.add((
        e.point.startedAtMs,
        PbRow(
          lift: gym == null
              ? nameOf(ex)
              : '${nameOf(ex)} (${gymNames[gym] ?? 'this gym'})',
          kg: e.point.e1rm.kg,
          date: dayOf(e.point.startedAtMs),
          gainKg: e.previousG == null
              ? null
              : (e.point.e1rm.grams - e.previousG!) / 1000,
        ),
      ));
    }
  }
  pbRows.sort((a, b) => b.$1.compareTo(a.$1));

  // Weekly volume and hard sets.
  final weekly = analysis.weekly(weeks: trendWeeks);
  final weeks = [
    for (final w in weekly)
      WeekVolume(
        '${w.weekStart.day} ${_months[w.weekStart.month - 1]}',
        w.volumeKgReps,
        w.workouts,
      ),
  ];
  final thisW = weekly.isEmpty ? null : weekly.last;
  final lastW = weekly.length < 2 ? null : weekly[weekly.length - 2];
  final muscles = <MuscleSets>[];
  for (final m in catalog.muscles) {
    final a = thisW?.hardSetsByMuscle[m.id];
    final b = lastW?.hardSetsByMuscle[m.id];
    if ((a?.total ?? 0) == 0 && (b?.total ?? 0) == 0) continue;
    muscles.add(
      MuscleSets(
        name: m.name,
        thisWeek: a?.total ?? 0,
        lastWeek: b?.total ?? 0,
        primary: a?.primary ?? 0,
        secondary: a?.secondary ?? 0,
      ),
    );
  }
  muscles.sort((a, b) {
    final c = b.thisWeek.compareTo(a.thisWeek);
    return c != 0 ? c : b.lastWeek.compareTo(a.lastWeek);
  });

  return ProgressView(
    cards: cards,
    weeks: weeks,
    muscles: muscles,
    pbs: [for (final r in pbRows.take(12)) r.$2],
    flagged: flagged,
    profile: profile,
    bodyweight: bw,
    today: today,
    sessions: {
      for (final w in workouts)
        if (inWindow(w.startedAtMs)) w.uuid,
    }.length,
  );
}
