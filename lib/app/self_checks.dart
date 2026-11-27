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
  });
  final int seq;
  final int wallMs;

  /// 1 done, 2 +1 rep, 3 skip rest.
  final int action;

  /// 0 applied, 1 debounced, 2 stale rev, 3 flag off, 4 error, 5 other.
  final int outcome;
  final int set;
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
  int slots,
  List<String> fields,
) {
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

List<CueEvidence> cueEvidence(Map<String, int> native) =>
    _ring(native, 'sc_cue', 60, ['late', 'flags', 'blk'])
        .map(
          (m) => CueEvidence(
            seq: m['seq']!,
            wallMs: m['wall']!,
            lateMs: m['late']!,
            flags: m['flags']!,
            block: m['blk']!,
          ),
        )
        .toList();

List<LockEvidence> lockEvidence(Map<String, int> native) =>
    _ring(native, 'sc_lock', 20, ['act', 'out', 'set'])
        .map(
          (m) => LockEvidence(
            seq: m['seq']!,
            wallMs: m['wall']!,
            action: m['act']!,
            outcome: m['out']!,
            set: m['set']!,
          ),
        )
        .toList();

List<HealthEvidence> healthEvidence(Map<String, int> native) =>
    _ring(native, 'sc_health', 10, ['op', 'out', 'n'])
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

/// Done taps: how many recorded, and any set recorded twice inside
/// [doubleRecordWindowMs].
SelfCheckVerdict? lockVerdict(List<LockEvidence> all) {
  const title = 'Lock-screen Done';
  final done = all.where((t) => t.isDone).toList();
  if (done.isEmpty) return null;
  final applied = done.where((t) => t.applied).toList();
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
  final errors = done.where((t) => t.outcome == 4).length;
  final stale = done.where((t) => t.outcome == 2).length;
  final held = done.where((t) => t.outcome == 1).length;
  final other = done.where((t) => t.outcome == 5).length;
  final notes = <String>[
    if (held > 0) '$held double-tap${held == 1 ? '' : 's'} held back',
    if (stale > 0) '$stale on an old notification, not recorded',
    if (other > 0) '$other with no workout to record into',
  ];
  final tail = notes.isEmpty ? '' : ' (${notes.join(', ')})';
  if (doubles == 0 && errors == 0 && stale == 0 && other == 0) {
    return SelfCheckVerdict(
      'lock_done',
      title,
      CheckState.good,
      'All good: ${applied.length} Done '
          'tap${applied.length == 1 ? '' : 's'} recorded, none doubled.$tail',
    );
  }
  final why = <String>[
    if (doubles > 0)
      '$doubles set${doubles == 1 ? '' : 's'} recorded twice within '
          '${doubleRecordWindowMs ~/ 1000} s',
    if (errors > 0) '$errors tap${errors == 1 ? '' : 's'} failed',
    if (stale > 0)
      '$stale tap${stale == 1 ? '' : 's'} not recorded (old notification)',
    if (other > 0)
      '$other tap${other == 1 ? '' : 's'} had no workout to record into',
  ];
  return SelfCheckVerdict(
    'lock_done',
    title,
    CheckState.off,
    "Something's off: ${why.join('; ')}. ${applied.length} recorded.",
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

/// The verdicts for every check that has evidence, cues first. A check
/// whose feature is on ([timers], [lockDone], [health]) but has no evidence
/// yet shows a quiet "nothing logged yet" line, so the section says what it
/// is waiting for.
List<SelfCheckVerdict> evaluateSelfChecks(
  Map<String, int> native, {
  bool timers = false,
  bool lockDone = false,
  bool health = false,
}) {
  SelfCheckVerdict waiting(String id, String title, String what) =>
      SelfCheckVerdict(
        id,
        title,
        CheckState.quiet,
        'Nothing logged yet. Appears after $what.',
      );
  return [
    cueVerdict(cueEvidence(native)) ??
        (timers
            ? waiting(
                'cues',
                'Timer cues and rest alerts',
                'a timed session or a rest alert',
              )
            : null),
    lockVerdict(lockEvidence(native)) ??
        (lockDone
            ? waiting(
                'lock_done',
                'Lock-screen Done',
                'a Done tap on the lock screen',
              )
            : null),
    healthVerdict(healthEvidence(native)) ??
        (health
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
