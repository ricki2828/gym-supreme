#!/usr/bin/env python3
"""T1 proof ladder (0.3 plan): checks the `cue` log lines of one timer block.

Usage: emom_check.py <rounds> <label>   (cue JSON lines on stdin, one per line; any text before
the first `{` on a line, such as a logcat prefix, is ignored).
Pass = <rounds> emom_minute cues plus one block_end, indices 0..rounds each exactly once, none
missed, max late_ms <= 1000. Prints the offsets for the CI log; exit 1 on failure.
"""
import json
import sys

MAX_LATE_MS = 1000


def main() -> int:
    rounds, label = int(sys.argv[1]), sys.argv[2]
    cues = []
    for raw in sys.stdin:
        i = raw.find("{")
        if i >= 0:
            cues.append(json.loads(raw[i:]))
    idx = [c["index"] for c in cues]
    late = [c["late_ms"] for c in cues]
    emom = [c for c in cues if c["kind"] == "emom_minute"]
    end = [c for c in cues if c["kind"] == "block_end"]
    missed = [c["index"] for c in cues if c.get("missed")]
    dups = sorted({i for i in idx if idx.count(i) > 1})
    mx = max(late) if late else None
    print(f"T1 {label}: emom_minute {len(emom)}/{rounds}, block_end {len(end)}/1, duplicates {dups}, missed {missed}, max_late_ms {mx}")
    print(f"T1 {label}: late_ms by index " + ",".join(f"{c['index']}:{c['late_ms']}" for c in sorted(cues, key=lambda c: c["index"])))
    print(f"T1 {label}: audio " + ",".join(sorted({str(c.get('audio')) for c in cues}))
          + "; wake_lock_held " + ",".join(sorted({str(c.get('wake_lock_held')) for c in cues})))
    ok = (len(emom) == rounds and len(end) == 1 and not dups and not missed
          and sorted(idx) == list(range(rounds + 1)) and mx is not None and mx <= MAX_LATE_MS)
    if not ok:
        print(f"::error::T1 {label}: cue run failed (want {rounds}+1 cues, each once, none missed, max late <= {MAX_LATE_MS} ms)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
