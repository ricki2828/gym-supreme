/// Self-checks (0.3.2): one-line verdicts built from the evidence the app
/// logs itself during real use (android SelfCheckLog.kt, read through the
/// native counters as `sc_*` keys). Pure Dart: [evaluateSelfChecks] takes the
/// counters map and returns the verdicts the Diagnostics screen shows. The
/// same keys are in the JSON export, so a reviewer can redo any verdict.
library;

/// A cue (timer cue or rest alert) counts as on time up to this lateness.
const int cueOnTimeMs = 1000;

/// Timer blocks the cue verdict looks back over.
const int cueBlocksConsidered = 5;

/// Rest alerts the cue verdict looks back over.
const int restAlertsConsidered = 30;

/// Two applied Done taps on one set this close are a double record.
const int doubleRecordWindowMs = 5000;

/// Evidence older than this is shown as "last checked <date>", not as a
/// current verdict.
const int evidenceMaxAgeDays = 14;

enum CheckState { good, off, quiet }

class SelfCheckVerdict {
  const SelfCheckVerdict(this.id, this.title, this.state, this.text);

  /// 'cues', 'lock_done' or 'health'.
  final String id;
  final String title;
  final CheckState state;

  /// One line: "All good: ...", "Something's off: ..." or a neutral note.
  final String text;
}

/// A timer cue or rest alert as logged.
class CueEvidence {
  const CueEvidence({
    required this.seq,
    required this.wallMs,
    required this.lateMs,
    required this.flags,
    required this.block,
  });
  final int seq;
  final int wallMs;
  final int lateMs;
  final int flags;
  final int block;

  bool get missed => flags & 1 != 0;
  bool get screenOff => flags & 2 != 0;
  bool get batterySaver => flags & 4 != 0;
  bool get doze => flags & 8 != 0;
  bool get toneFailed => flags & 16 != 0;
  bool get rest => flags & 32 != 0;
  int get route => (flags >> 8) & 3;
  bool get onTime => !missed && lateMs <= cueOnTimeMs;
}

class LockEvidence {
  const LockEvidence({
    required this.seq,
    required this.wallMs,
    required this.action,
    required this.outcome,
    required this.set,
    this.fromApp = false,
  });
  final int seq;
  final int wallMs;

  /// 1 done, 2 +1 rep, 3 skip rest.
  final int action;

  /// 0 applied, 1 debounced, 2 stale rev, 3 flag off, 4 error, 5 not pending,
  /// 6 paused, 7 finished, 8 unknown set, 9 not eligible, 10 no session,
  /// 11 no journal, 12 other.
  final int outcome;
  final int set;

  /// A Done made in the app (logged when the journal takes the snapshot),
  /// not a notification tap.
  final bool fromApp;
  bool get applied => outcome == 0;
  bool get isDone => action == 1;
}

class HealthEvidence {
  const HealthEvidence({
    required this.seq,
    required this.wallMs,
    required this.delete,
    required this.outcome,
    required this.count,
  });
  final int seq;
  final int wallMs;
  final bool delete;

  /// 0 ok, 1 failed, 2 permission denied, 3 not available, 4 disabled.
  final int outcome;
  final int count;
}

/// Entries of one ring, oldest first. [fields] are the key suffixes.
List<Map<String, int>> _ring(
  Map<String, int> native,
  String base,
  List<String> fields,
) {
  // The ring size is the writer's (`<base>_slots`), so the two sides cannot
  // drift; a missing key reads the keys that are there.
  final slots = native['${base}_slots'] ?? 100;
  final out = <Map<String, int>>[];
  for (var i = 0; i < slots; i++) {
    final slot = '${base}_${i.toString().padLeft(2, '0')}';
    final seq = native['${slot}_seq'];
    if (seq == null) continue;
    out.add({
      'seq': seq,
      'wall': native['${slot}_wall'] ?? 0,
      for (final f in fields) f: native['${slot}_$f'] ?? 0,
    });
  }
  out.sort((a, b) => a['seq']!.compareTo(b['seq']!));
  return out;
}

/// Timer cues (oldest first) followed by rest alerts (oldest first): two
/// rings, so neither evicts the other.
List<CueEvidence> cueEvidence(Map<String, int> native) => [
  for (final base in ['sc_cue', 'sc_rest'])
    ..._ring(native, base, ['late', 'flags', 'blk']).map(
      (m) => CueEvidence(
        seq: m['seq']!,
        wallMs: m['wall']!,
        lateMs: m['late']!,
        flags: m['flags']!,
        block: m['blk']!,
      ),
    ),
];

List<LockEvidence> lockEvidence(Map<String, int> native) =>
    _ring(native, 'sc_lock', ['act', 'out', 'set', 'src'])
        .map(
          (m) => LockEvidence(
            seq: m['seq']!,
            wallMs: m['wall']!,
            action: m['act']!,
            outcome: m['out']!,
            set: m['set']!,
            fromApp: m['src'] == 1,
          ),
        )
        .toList();

List<HealthEvidence> healthEvidence(Map<String, int> native) =>
    _ring(native, 'sc_health', ['op', 'out', 'n'])
        .map(
          (m) => HealthEvidence(
            seq: m['seq']!,
            wallMs: m['wall']!,
            delete: m['op'] == 1,
            outcome: m['out']!,
            count: m['n']!,
          ),
        )
        .toList();

String _secs(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

String _lateText(int ms) => ms < 1000 ? '$ms ms' : _secs(ms);

/// Timer cues of the last [cueBlocksConsidered] blocks plus the last
/// [restAlertsConsidered] rest alerts (rest alerts under Doze / battery saver
/// share the cue path, so they share the verdict).
SelfCheckVerdict? cueVerdict(List<CueEvidence> all) {
  const title = 'Timer cues and rest alerts';
  if (all.isEmpty) return null;
  final timer = all.where((c) => !c.rest).toList();
  final blocks = <int>[];
  for (final c in timer.reversed) {
    if (!blocks.contains(c.block)) blocks.add(c.block);
  }
  final keep = blocks.take(cueBlocksConsidered).toSet();
  final cues = [
    ...timer.where((c) => keep.contains(c.block)),
    ...all.where((c) => c.rest).toList().reversed.take(restAlertsConsidered),
  ];
  final n = cues.length;
  final onTime = cues.where((c) => c.onTime).length;
  final missed = cues.where((c) => c.missed).length;
  final late = cues.where((c) => !c.missed && c.lateMs > cueOnTimeMs).toList();
  final worst = cues
      .where((c) => !c.missed)
      .fold<int>(0, (m, c) => c.lateMs > m ? c.lateMs : m);
  final tone = cues.where((c) => c.toneFailed).length;
  final sessions = blocks.take(cueBlocksConsidered).length;
  final rests = cues.where((c) => c.rest).length;
  final scope =
      '$n cues: $sessions timed session${sessions == 1 ? '' : 's'}, '
      '$rests rest alert${rests == 1 ? '' : 's'}';
  if (missed == 0 && late.isEmpty && tone == 0) {
    return SelfCheckVerdict(
      'cues',
      title,
      CheckState.good,
      'All good: $onTime of $n on time, worst ${_lateText(worst)} late. '
          '($scope)',
    );
  }
  final why = <String>[];
  if (late.isNotEmpty) {
    why.add(
      '${late.length} late (worst ${_lateText(worst)}), $onTime of $n on time',
    );
    final saver = late.where((c) => c.batterySaver).length;
    final off = late.where((c) => c.screenOff).length;
    final doze = late.where((c) => c.doze).length;
    final hints = <String>[
      if (saver > 0) 'battery saver on for $saver',
      if (doze > 0) 'Doze for $doze',
      if (off > 0) 'screen off for $off',
    ];
    if (hints.isNotEmpty) why.add('late ones: ${hints.join(', ')}');
  }
  if (late.isEmpty) why.add('$onTime of $n on time');
  if (missed > 0) why.add('$missed missed');
  if (tone > 0) why.add('tone failed on $tone');
  return SelfCheckVerdict(
    'cues',
    title,
    CheckState.off,
    "Something's off: ${why.join('; ')}. ($scope)",
  );
}

/// Done taps, lock screen and in app: how many recorded, and any set
/// recorded twice (by either route) inside [doubleRecordWindowMs]. A second
/// tap on a set already done ("not pending") and a double-tap held back by the
/// debounce are the guards working, not problems.
SelfCheckVerdict? lockVerdict(List<LockEvidence> all) {
  const title = 'Done taps (lock screen and app)';
  final done = all.where((t) => t.isDone).toList();
  if (done.isEmpty) return null;
  final applied = done.where((t) => t.applied).toList();
  final lockN = applied.where((t) => !t.fromApp).length;
  final appN = applied.length - lockN;
  var doubles = 0;
  for (var i = 0; i < applied.length; i++) {
    for (var j = i + 1; j < applied.length; j++) {
      if (applied[i].set == applied[j].set &&
          (applied[j].wallMs - applied[i].wallMs).abs() <=
              doubleRecordWindowMs) {
        doubles++;
        break;
      }
    }
  }
  int count(bool Function(int o) f) => done.where((t) => f(t.outcome)).length;
  final errors = count((o) => o == 4);
  final stale = count((o) => o == 2);
  final unmatched = count((o) => o == 8 || o == 9);
  final nothing = count((o) => o == 10 || o == 11 || o == 12);
  final guards = count((o) => o == 1 || o == 5);
  final paused = count((o) => o == 6);
  final finished = count((o) => o == 7);
  String taps(int n) => '$n tap${n == 1 ? '' : 's'}';
  final notes = <String>[
    if (guards > 0) '${taps(guards)} held back as double taps',
    if (paused > 0) '${taps(paused)} while paused',
    if (finished > 0) '${taps(finished)} after the workout finished',
  ];
  final tail = notes.isEmpty ? '' : ' (${notes.join(', ')})';
  final recorded =
      '${applied.length} Done ${applied.length == 1 ? 'tap' : 'taps'} '
      'recorded ($lockN lock screen, $appN in app)';
  if (doubles == 0 &&
      errors == 0 &&
      stale == 0 &&
      unmatched == 0 &&
      nothing == 0) {
    return SelfCheckVerdict(
      'lock_done',
      title,
      CheckState.good,
      'All good: $recorded, no set recorded twice.$tail',
    );
  }
  final why = <String>[
    if (doubles > 0)
      '$doubles set${doubles == 1 ? '' : 's'} recorded twice within '
          '${doubleRecordWindowMs ~/ 1000} s',
    if (errors > 0) '${taps(errors)} failed',
    if (stale > 0) '${taps(stale)} on an old notification, not recorded',
    if (unmatched > 0)
      '${taps(unmatched)} on a set the workout no longer matched',
    if (nothing > 0) '${taps(nothing)} with no workout to record into',
  ];
  return SelfCheckVerdict(
    'lock_done',
    title,
    CheckState.off,
    "Something's off: ${why.join('; ')}. $recorded.$tail",
  );
}

String _stamp(int wallMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(wallMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

const _healthOutcomes = [
  'ok',
  'failed',
  'permission denied',
  'not available',
  'switch off',
];

/// Last write and last delete result.
SelfCheckVerdict? healthVerdict(List<HealthEvidence> all) {
  const title = 'Health Connect';
  if (all.isEmpty) return null;
  final write = all.where((h) => !h.delete).lastOrNull;
  final delete = all.where((h) => h.delete).lastOrNull;
  String name(int o) => _healthOutcomes[o.clamp(0, 4)];
  // Switch off / not available is a state, not a failure.
  bool bad(HealthEvidence? h) =>
      h != null && (h.outcome == 1 || h.outcome == 2);
  String line(String what, HealthEvidence? h) => h == null
      ? 'no $what yet'
      : 'last $what ${name(h.outcome)} (${h.count}, ${_stamp(h.wallMs)})';
  final text = '${line('write', write)}; ${line('delete', delete)}';
  if (bad(write) || bad(delete)) {
    return SelfCheckVerdict(
      'health',
      title,
      CheckState.off,
      "Something's off: $text",
    );
  }
  final ok = write != null && write.outcome == 0;
  return SelfCheckVerdict(
    'health',
    title,
    ok ? CheckState.good : CheckState.quiet,
    ok ? 'All good: $text' : 'Not recorded to Health Connect: $text',
  );
}

SelfCheckVerdict _aged(SelfCheckVerdict v, int newestMs, int nowMs) {
  final stale = nowMs - newestMs > evidenceMaxAgeDays * 86400000;
  if (stale) {
    return SelfCheckVerdict(
      v.id,
      v.title,
      CheckState.quiet,
      'Last checked ${_stamp(newestMs)}: ${v.text}',
    );
  }
  return v;
}

int _newest(Iterable<int> walls) => walls.fold(0, (m, w) => w > m ? w : m);

/// The verdicts for every check that has evidence, cues first. A check
/// whose feature is on ([timers], [lockDone], [health]) but has no evidence
/// yet shows a quiet "nothing logged yet" line, so the section says what it
/// is waiting for. Evidence older than [evidenceMaxAgeDays] at [nowMs] is
/// shown as "last checked <date>", not as a current verdict; cue and Done
/// lines end with the date of the newest entry.
List<SelfCheckVerdict> evaluateSelfChecks(
  Map<String, int> native, {
  bool timers = false,
  bool lockDone = false,
  bool health = false,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  SelfCheckVerdict waiting(String id, String title, String what) =>
      SelfCheckVerdict(
        id,
        title,
        CheckState.quiet,
        'Nothing logged yet. Appears after $what.',
      );
  SelfCheckVerdict withDate(SelfCheckVerdict v, int newest) => _aged(
    SelfCheckVerdict(
      v.id,
      v.title,
      v.state,
      '${v.text} Newest ${_stamp(newest)}.',
    ),
    newest,
    now,
  );
  final cues = cueEvidence(native);
  final cue = cueVerdict(cues);
  final locks = lockEvidence(native);
  final lock = lockVerdict(locks);
  final hc = healthEvidence(native);
  final hv = healthVerdict(hc);
  return [
    cue != null
        ? withDate(cue, _newest(cues.map((c) => c.wallMs)))
        : (timers
              ? waiting(
                  'cues',
                  'Timer cues and rest alerts',
                  'a timed session or a rest alert',
                )
              : null),
    lock != null
        ? withDate(
            lock,
            _newest(locks.where((t) => t.isDone).map((t) => t.wallMs)),
          )
        : (lockDone
              ? waiting(
                  'lock_done',
                  'Done taps (lock screen and app)',
                  'a Done tap',
                )
              : null),
    hv != null
        ? _aged(hv, _newest(hc.map((h) => h.wallMs)), now)
        : (health
              ? waiting(
                  'health',
                  'Health Connect',
                  'a workout is written to Health Connect',
                )
              : null),
  ].nonNulls.toList();
}

/// Keys of the evidence rings, which the counter list leaves out (they have
/// their own section and are in the export as raw keys).
bool isSelfCheckKey(String key) => key.startsWith('sc_');
