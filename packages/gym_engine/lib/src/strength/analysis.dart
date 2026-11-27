/// Offline strength analysis, computed on read from finished workouts (no
/// schema change, nothing cached). Rules: B1 strength design sections 3-4.
library;

import '../catalog.dart';
import '../model.dart';
import 'e1rm.dart';

const int _dayMs = 86400000;

/// The window of "best e1RM" and the typo guard's prior-best look-back.
const int strengthWindowDays = 90;

/// A set is a warm-up when it opens the exercise below this share of the
/// workout's heaviest load for the exercise.
const double warmUpShare = 0.6;

/// Typo guard: above this multiple of the prior 90-day best ...
const double typoHigh = 1.2;

/// ... or below this multiple, the set is parked until confirmed.
const double typoLow = 0.4;

/// A later workout within this share of a parked value confirms it.
const double typoConfirmBand = 0.10;

/// Why a set does not count as an e1RM candidate.
enum RejectReason {
  workoutDeleted,
  skipped,
  timed,
  noLoad,
  noReps,
  warmUp,
  coldStart,
  repsOver12,

  /// The workout's top set for the lift looks like a typo; parked until a
  /// later workout lands within 10% of it, or he confirms it.
  typoUnconfirmed,
}

/// What the analysis decided about one stored set.
class SetVerdict {
  const SetVerdict({
    required this.set,
    required this.workoutUuid,
    required this.gymId,
    required this.startedAtMs,
    this.reason,
    this.e1rm,
    this.isTop = false,
  });

  final SetRecord set;
  final String workoutUuid;
  final String gymId;
  final int startedAtMs;

  /// Null when the set was eligible (it may still not be the top set).
  final RejectReason? reason;

  /// Set when the set is eligible, or parked as [RejectReason.typoUnconfirmed].
  final E1rm? e1rm;

  /// The workout's top set for the exercise that counts.
  final bool isTop;

  bool get rejected => reason != null;
}

/// The e1RM a workout contributed for one exercise.
class StrengthPoint {
  const StrengthPoint({
    required this.exerciseId,
    required this.workoutUuid,
    required this.gymId,
    required this.startedAtMs,
    required this.setId,
    required this.loadG,
    required this.reps,
    required this.e1rm,
  });

  final String exerciseId;
  final String workoutUuid;
  final String gymId;
  final int startedAtMs;
  final String setId;
  final int loadG;
  final int reps;
  final E1rm e1rm;
}

/// The best e1RM for an exercise in the window, with what it came from.
class ExerciseStrength {
  const ExerciseStrength({
    required this.exerciseId,
    required this.best,
    required this.bestSolid,
    required this.points,
    required this.rejected,
    this.gymId,
  });

  final String exerciseId;

  /// Set for per-gym (stack/machine) lifts: the gym the numbers belong to.
  /// Null for lifts merged across gyms (barbell, dumbbell, bodyweight).
  final String? gymId;

  /// Max e1RM in the window, rough sets included.
  final StrengthPoint best;

  /// Max over sets of 10 reps or fewer (a workout's best solid set counts
  /// even when a rough set was its top); null when only rough sets exist
  /// ("needs a heavier set").
  final StrengthPoint? bestSolid;

  /// Every counted workout's top point in the window, oldest first.
  final List<StrengthPoint> points;

  /// Rejected sets for this exercise in the window.
  final List<SetVerdict> rejected;
}

/// A new all-time best e1RM (non-rough only).
class PbEntry {
  const PbEntry({required this.point, required this.previousG});
  final StrengthPoint point;

  /// The best before this one; null for the first-ever.
  final double? previousG;
}

/// Hard sets of one muscle in one week.
class HardSets {
  const HardSets({this.primary = 0, this.secondary = 0});
  final int primary;
  final int secondary;

  /// Sets that name the muscle as primary or secondary (no fractions).
  int get total => primary + secondary;

  @override
  bool operator ==(Object other) =>
      other is HardSets &&
      other.primary == primary &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(primary, secondary);

  @override
  String toString() => 'HardSets($primary+$secondary)';
}

/// One training week, Monday to Sunday in the workouts' own local time.
class WeeklyStrength {
  const WeeklyStrength({
    required this.weekStart,
    required this.workouts,
    required this.volumeGReps,
    required this.hardSetsByMuscle,
  });

  /// Monday, as a UTC midnight DateTime holding the local calendar date.
  final DateTime weekStart;
  final int workouts;

  /// Load x reps over every counted reps set (warm-ups included), gram-reps.
  final int volumeGReps;

  /// Muscle id -> hard sets. Only muscles with a set appear.
  final Map<String, HardSets> hardSetsByMuscle;

  double get volumeKgReps => volumeGReps / 1000;
}

/// The analysis. Built from the finished workouts; every query is a read
/// over the result. [nowMs] is the injected clock (UTC epoch ms).
///
/// Lifts on a weight stack (catalog load `stack`) are per gym: the typo
/// guard, bests and PBs never merge two gyms' stacks. Everything else
/// (barbell, dumbbell, bodyweight) is merged across gyms.
///
/// Hard sets count every done reps set that is not a warm-up, including
/// cold-start sets and sets parked by the typo guard. On a ramp such as
/// 40/60/80/100 kg only sets below 60% of the heaviest (40) are warm-ups, so
/// 60 and 80 are hard sets.
class StrengthAnalysis {
  StrengthAnalysis({
    required Iterable<WorkoutRecord> workouts,
    required this.catalog,
    required this.nowMs,
    Set<String> deletedUuids = const {},
    Set<String> confirmedSetIds = const {},
  }) : _confirmed = confirmedSetIds {
    final list = workouts.toList()
      ..sort((a, b) {
        final c = a.startedAtMs.compareTo(b.startedAtMs);
        return c != 0 ? c : a.uuid.compareTo(b.uuid);
      });
    for (final w in list) {
      if (deletedUuids.contains(w.uuid)) {
        _deleted.add(w);
      } else {
        _live.add(w);
      }
    }
    _classify(list);
  }

  final Catalog catalog;
  final int nowMs;
  final Set<String> _confirmed;
  final List<WorkoutRecord> _deleted = [];
  final List<WorkoutRecord> _live = [];
  final List<SetVerdict> _verdicts = [];

  /// Verdicts by exercise id, in chronological order.
  final Map<String, List<SetVerdict>> _byExercise = {};

  /// Per-gym lift -> gym of the newest live workout that contains it.
  final Map<String, String> _lastGym = {};

  /// Set ids that are warm-ups.
  final Set<String> _warmUps = {};

  /// Set ids parked by the typo guard and never confirmed.
  final Set<String> _parkedIds = {};

  /// Accepted lift-days by group key, oldest first.
  final Map<String, List<_LiftDay>> _days = {};

  /// Every set with its verdict (deleted workouts included).
  List<SetVerdict> get verdicts => List.unmodifiable(_verdicts);

  bool _perGym(String exerciseId) =>
      catalog.exercise(exerciseId)?.load == 'stack';

  String _group(String exerciseId, String gymId) =>
      _perGym(exerciseId) ? '$exerciseId@$gymId' : exerciseId;

  static RejectReason? _staticReason(SetRecord s) {
    if (s.skipped) return RejectReason.skipped;
    if (s.kind == SetKind.timed) return RejectReason.timed;
    if ((s.loadG ?? 0) <= 0) return RejectReason.noLoad;
    if ((s.reps ?? 0) < 1) return RejectReason.noReps;
    return null;
  }

  /// Epley without the 12-rep cap, only for the typo screen.
  static double _rawEpley(SetRecord s) =>
      s.reps == 1 ? s.loadG!.toDouble() : s.loadG! * (1 + s.reps! / 30);

  void _classify(List<WorkoutRecord> all) {
    final raws = <_Raw>[];
    final parked = <String, List<_Parked>>{};
    for (final w in all) {
      if (_deleted.contains(w)) {
        for (final s in w.sets) {
          raws.add(_Raw(w, s)..reason = RejectReason.workoutDeleted);
        }
        continue;
      }
      final byEx = <String, List<SetRecord>>{};
      for (final s in w.sets) {
        (byEx[s.exerciseId] ??= []).add(s);
        if (_perGym(s.exerciseId)) _lastGym[s.exerciseId] = w.gymId;
      }
      final exIds = byEx.keys.toList()
        ..sort((a, b) {
          final c = byEx[a]!.first.exercisePosition.compareTo(
            byEx[b]!.first.exercisePosition,
          );
          return c != 0 ? c : a.compareTo(b);
        });
      for (final exId in exIds) {
        final sets = byEx[exId]!
          ..sort((a, b) {
            final c = a.setOrdinal.compareTo(b.setOrdinal);
            return c != 0 ? c : a.setId.compareTo(b.setId);
          });
        _liftDay(w, exId, sets, raws, parked);
      }
    }
    // Final verdicts.
    final topIds = <String>{
      for (final days in _days.values)
        for (final d in days) d.point.setId,
    };
    for (final r in raws) {
      final id = r.set.setId;
      final isParked = _parkedIds.contains(id);
      final v = SetVerdict(
        set: r.set,
        workoutUuid: r.w.uuid,
        gymId: r.w.gymId,
        startedAtMs: r.w.startedAtMs,
        reason: isParked ? RejectReason.typoUnconfirmed : r.reason,
        e1rm: r.e1rm,
        isTop: !isParked && r.reason == null && topIds.contains(id),
      );
      _verdicts.add(v);
      (_byExercise[r.set.exerciseId] ??= []).add(v);
    }
  }

  void _liftDay(
    WorkoutRecord w,
    String exId,
    List<SetRecord> sets,
    List<_Raw> raws,
    Map<String, List<_Parked>> parkedByGroup,
  ) {
    final group = _group(exId, w.gymId);
    final prior = _priorBest(group, w.startedAtMs);
    bool confirmed(SetRecord s) => _confirmed.contains(s.setId);
    bool high(SetRecord s) =>
        prior != null &&
        (s.loadG ?? 0) > 0 &&
        (s.reps ?? 0) >= 1 &&
        !confirmed(s) &&
        _rawEpley(s) > typoHigh * prior;

    // Warm-ups: the reference is the heaviest load of the exercise, capped
    // at 1.2x the prior best so a typo cannot raise the bar, and real sets
    // that look too heavy (so are parked) still keep the warm-ups below them.
    final loaded = [
      for (final s in sets)
        if (s.counts && s.kind == SetKind.reps && (s.loadG ?? 0) > 0) s,
    ];
    final warm = <String>{};
    if (loaded.length >= 2) {
      final cap = prior == null ? double.infinity : typoHigh * prior;
      final heaviest = loaded
          .map((s) => s.loadG! > cap ? cap : s.loadG!.toDouble())
          .reduce((a, b) => a > b ? a : b);
      for (final s in loaded) {
        if (s.loadG! < warmUpShare * heaviest) {
          warm.add(s.setId);
        } else {
          break;
        }
      }
    }
    _warmUps.addAll(warm);

    final cands = <_Raw>[];
    for (final s in sets) {
      final r = _Raw(w, s);
      raws.add(r);
      r.reason =
          _staticReason(s) ??
          (warm.contains(s.setId) ? RejectReason.warmUp : null) ??
          (s.completion == Completion.coldStart
              ? RejectReason.coldStart
              : null);
      if (r.reason != null) continue;
      final e = e1rm(s.loadG, s.reps);
      if (e == null) {
        r.reason = RejectReason.repsOver12;
        continue;
      }
      r.e1rm = e;
      cands.add(r);
    }
    if (cands.isEmpty) return;

    // High outliers are parked set by set; they are not candidates.
    final outliers = [
      for (final c in cands)
        if (high(c.set)) c,
    ];
    final keep = [
      for (final c in cands)
        if (!high(c.set)) c,
    ];
    _Raw? better(_Raw? a, _Raw b) {
      if (a == null) return b;
      final c = b.e1rm!.grams.compareTo(a.e1rm!.grams);
      if (c != 0) return c > 0 ? b : a;
      final l = b.set.loadG!.compareTo(a.set.loadG!);
      if (l != 0) return l > 0 ? b : a;
      final o = b.set.setOrdinal.compareTo(a.set.setOrdinal);
      if (o != 0) return o < 0 ? b : a;
      return b.set.setId.compareTo(a.set.setId) < 0 ? b : a;
    }

    _Raw? top, solid;
    for (final c in keep) {
      top = better(top, c);
      if (!c.e1rm!.rough) solid = better(solid, c);
    }
    _Raw? outTop;
    for (final c in outliers) {
      outTop = better(outTop, c);
    }
    StrengthPoint pointOf(_Raw r) => StrengthPoint(
      exerciseId: exId,
      workoutUuid: w.uuid,
      gymId: w.gymId,
      startedAtMs: w.startedAtMs,
      setId: r.set.setId,
      loadG: r.set.loadG!,
      reps: r.set.reps!,
      e1rm: r.e1rm!,
    );

    _LiftDay? day;
    if (top != null) {
      final low =
          prior != null &&
          !confirmed(top.set) &&
          top.e1rm!.grams < typoLow * prior;
      if (low) {
        // The best set is implausibly light: park it, no point.
        _parkedIds.add(top.set.setId);
        (parkedByGroup[group] ??= []).add(
          _Parked(pointOf(top), solid == null ? null : pointOf(solid), [
            top.set.setId,
          ]),
        );
      } else {
        day = _LiftDay(pointOf(top), solid == null ? null : pointOf(solid));
      }
    }
    _Parked? newlyParked;
    if (outTop != null) {
      final ids = [for (final o in outliers) o.set.setId];
      _parkedIds.addAll(ids);
      final solidOut = outliers
          .where((o) => !o.e1rm!.rough)
          .fold<_Raw?>(null, better);
      newlyParked = _Parked(
        pointOf(outTop),
        solidOut == null ? null : pointOf(solidOut),
        ids,
      );
      (parkedByGroup[group] ??= []).add(newlyParked);
    }
    if (day != null) _addDay(group, day);
    // A later workout within 10% confirms earlier parked values.
    final refs = <double>[
      if (day != null) day.point.e1rm.grams,
      if (newlyParked != null) newlyParked.point.e1rm.grams,
    ];
    final list = parkedByGroup[group] ?? const <_Parked>[];
    var changed = true;
    while (changed) {
      changed = false;
      for (final p in list) {
        if (p.confirmed) continue;
        final a = p.point.e1rm.grams;
        final earlier = p.point.startedAtMs < w.startedAtMs;
        final hit =
            earlier && refs.any((b) => (b - a).abs() <= typoConfirmBand * a);
        if (hit) {
          _confirm(group, p);
          changed = true;
          // The fresh parked value is consistent with a confirmed one.
          if (newlyParked != null && !newlyParked.confirmed) {
            final b = newlyParked.point.e1rm.grams;
            if ((b - a).abs() <= typoConfirmBand * a) {
              _confirm(group, newlyParked);
            }
          }
        }
      }
    }
  }

  void _confirm(String group, _Parked p) {
    p.confirmed = true;
    _parkedIds.removeAll(p.setIds);
    _addDay(group, _LiftDay(p.point, p.solid));
  }

  /// Adds a lift-day in time order; a second day for the same workout is
  /// merged into one (best top, best solid).
  void _addDay(String group, _LiftDay d) {
    final list = _days[group] ??= [];
    final i = list.indexWhere(
      (x) => x.point.workoutUuid == d.point.workoutUuid,
    );
    if (i >= 0) {
      list[i] = list[i].merge(d);
      return;
    }
    var at = list.length;
    while (at > 0 && list[at - 1].point.startedAtMs > d.point.startedAtMs) {
      at--;
    }
    list.insert(at, d);
  }

  /// Best accepted top e1RM in the 90 days before [atMs], grams; null if
  /// none. Scans back from the newest day and stops at the window edge.
  double? _priorBest(String group, int atMs) {
    final list = _days[group];
    if (list == null) return null;
    final from = atMs - strengthWindowDays * _dayMs;
    double? best;
    for (var i = list.length - 1; i >= 0; i--) {
      final t = list[i].point.startedAtMs;
      if (t < from) break;
      if (t >= atMs) continue;
      final g = list[i].point.e1rm.grams;
      if (best == null || g > best) best = g;
    }
    return best;
  }

  // ---- queries ----

  bool _inWindow(int ms) =>
      ms <= nowMs && ms >= nowMs - strengthWindowDays * _dayMs;

  /// The group key a query means. A per-gym lift with no [gymId] resolves to
  /// the gym of its newest accepted point (never a merge of gyms).
  String? _resolve(String exerciseId, String? gymId) {
    if (!_perGym(exerciseId)) return exerciseId;
    if (gymId != null) return '$exerciseId@$gymId';
    final g = _lastGym[exerciseId];
    return g == null ? null : '$exerciseId@$g';
  }

  /// Best e1RM per lift over the last 90 days. Keys are the exercise id for
  /// merged lifts, but `id@gym` (e.g. `leg-press@g1`) for stack lifts, which
  /// are per gym: callers must not look those up by exercise id alone (use
  /// [bestFor]). With [gymId], only that gym's lifts.
  Map<String, ExerciseStrength> bestIn90Days({String? gymId}) {
    final out = <String, ExerciseStrength>{};
    for (final key in _days.keys) {
      final at = key.indexOf('@');
      final ex = at < 0 ? key : key.substring(0, at);
      final g = at < 0 ? null : key.substring(at + 1);
      if (gymId != null && g != null && g != gymId) continue;
      final r = _strengthFor(ex, key, g, gymFilter: g == null ? gymId : null);
      if (r != null) out[key] = r;
    }
    return out;
  }

  /// [gymId] limits merged lifts to one gym's workouts and picks the gym of a
  /// per-gym lift (default: the one trained most recently).
  ExerciseStrength? bestFor(String exerciseId, {String? gymId}) {
    final key = _resolve(exerciseId, gymId);
    if (key == null) return null;
    final at = key.indexOf('@');
    return _strengthFor(
      exerciseId,
      key,
      at < 0 ? null : key.substring(at + 1),
      gymFilter: at < 0 ? gymId : null,
    );
  }

  ExerciseStrength? _strengthFor(
    String exerciseId,
    String key,
    String? lockedGym, {
    String? gymFilter,
  }) {
    final days = [
      for (final d in _days[key] ?? const <_LiftDay>[])
        if (_inWindow(d.point.startedAtMs) &&
            (gymFilter == null || d.point.gymId == gymFilter))
          d,
    ];
    if (days.isEmpty) return null;
    StrengthPoint? best, solid;
    for (final d in days) {
      if (best == null || d.point.e1rm.grams > best.e1rm.grams) best = d.point;
      final sp = d.solid;
      if (sp != null && (solid == null || sp.e1rm.grams > solid.e1rm.grams)) {
        solid = sp;
      }
    }
    final g = lockedGym ?? gymFilter;
    return ExerciseStrength(
      exerciseId: exerciseId,
      gymId: lockedGym,
      best: best!,
      bestSolid: solid,
      points: [for (final d in days) d.point],
      rejected: [
        for (final v in _byExercise[exerciseId] ?? const <SetVerdict>[])
          if (v.rejected &&
              _inWindow(v.startedAtMs) &&
              (g == null || v.gymId == g))
            v,
      ],
    );
  }

  /// Rejected sets, oldest workout first; optionally for one exercise.
  List<SetVerdict> rejectedSets({String? exerciseId}) => [
    for (final v
        in exerciseId == null
            ? _verdicts
            : (_byExercise[exerciseId] ?? const <SetVerdict>[]))
      if (v.rejected) v,
  ];

  /// All-time PB history for a lift: each workout's best non-rough set that
  /// beat every earlier one, oldest first. Window-independent. Per-gym lifts
  /// follow the same gym rule as [bestFor].
  List<PbEntry> pbHistory(String exerciseId, {String? gymId}) {
    final key = _resolve(exerciseId, gymId);
    if (key == null) return const [];
    final at = key.indexOf('@');
    final filter = at < 0 ? gymId : null;
    final out = <PbEntry>[];
    double? best;
    for (final d in _days[key] ?? const <_LiftDay>[]) {
      final p = d.solid;
      if (p == null) continue;
      if (filter != null && p.gymId != filter) continue;
      if (best == null || p.e1rm.grams > best) {
        out.add(PbEntry(point: p, previousG: best));
        best = p.e1rm.grams;
      }
    }
    return out;
  }

  /// Weekly volume and hard sets for the last [weeks] weeks, ending with the
  /// week that holds [nowMs]; empty weeks are included. Oldest first. Volume
  /// leaves out sets parked by the typo guard.
  List<WeeklyStrength> weekly({int weeks = 12}) {
    final byWeek = <int, _WeekAcc>{};
    for (final w in _live) {
      final key = _weekStart(w).millisecondsSinceEpoch;
      final acc = byWeek[key] ??= _WeekAcc();
      acc.workouts++;
      for (final s in w.sets) {
        if (!_parkedIds.contains(s.setId)) acc.volume += s.volumeGReps;
        if (!_isHardSet(s)) continue;
        final ex = catalog.exercise(s.exerciseId);
        if (ex == null) continue;
        for (final m in ex.primary) {
          acc.primary[m] = (acc.primary[m] ?? 0) + 1;
        }
        for (final m in ex.secondary) {
          if (ex.primary.contains(m)) continue;
          acc.secondary[m] = (acc.secondary[m] ?? 0) + 1;
        }
      }
    }
    // `nowMs` has no stored offset: the newest workout's offset is the best
    // local guess, else UTC.
    final offset = _live.isEmpty ? 0 : _live.last.tzOffsetMin;
    final thisWeek = _mondayOf(
      DateTime.fromMillisecondsSinceEpoch(nowMs + offset * 60000, isUtc: true),
    );
    return [
      for (var i = weeks - 1; i >= 0; i--)
        _week(thisWeek.subtract(Duration(days: 7 * i)), byWeek),
    ];
  }

  WeeklyStrength _week(DateTime start, Map<int, _WeekAcc> byWeek) {
    final a = byWeek[start.millisecondsSinceEpoch];
    if (a == null) {
      return WeeklyStrength(
        weekStart: start,
        workouts: 0,
        volumeGReps: 0,
        hardSetsByMuscle: const {},
      );
    }
    final ms = {...a.primary.keys, ...a.secondary.keys}.toList()..sort();
    return WeeklyStrength(
      weekStart: start,
      workouts: a.workouts,
      volumeGReps: a.volume,
      hardSetsByMuscle: {
        for (final m in ms)
          m: HardSets(
            primary: a.primary[m] ?? 0,
            secondary: a.secondary[m] ?? 0,
          ),
      },
    );
  }

  /// A hard set: a done reps set with at least one rep that is not a
  /// warm-up. Cold-start and parked sets still count (the effort happened).
  bool _isHardSet(SetRecord s) =>
      s.counts &&
      s.kind == SetKind.reps &&
      (s.reps ?? 0) >= 1 &&
      !_warmUps.contains(s.setId);

  static DateTime _weekStart(WorkoutRecord w) => _mondayOf(w.localStart);

  static DateTime _mondayOf(DateTime local) {
    final d = DateTime.utc(local.year, local.month, local.day);
    return d.subtract(Duration(days: d.weekday - DateTime.monday));
  }
}

class _Raw {
  _Raw(this.w, this.set);
  final WorkoutRecord w;
  final SetRecord set;
  RejectReason? reason;
  E1rm? e1rm;
}

/// One workout's accepted result for a lift: its top point, and its best
/// non-rough point (which differs when the top was a rough 11-12 rep set).
class _LiftDay {
  const _LiftDay(this.point, this.solid);
  final StrengthPoint point;
  final StrengthPoint? solid;

  _LiftDay merge(_LiftDay o) {
    final p = o.point.e1rm.grams > point.e1rm.grams ? o.point : point;
    StrengthPoint? s = solid;
    final os = o.solid;
    if (os != null && (s == null || os.e1rm.grams > s.e1rm.grams)) s = os;
    return _LiftDay(p, s);
  }
}

class _Parked {
  _Parked(this.point, this.solid, this.setIds);
  final StrengthPoint point;
  final StrengthPoint? solid;
  final List<String> setIds;
  bool confirmed = false;
}

class _WeekAcc {
  int workouts = 0;
  int volume = 0;
  final Map<String, int> primary = {};
  final Map<String, int> secondary = {};
}
