#!/usr/bin/env python3
"""Build assets/exercises.json and assets/exercises_taxonomy.json.

Inputs (all committed, so CI needs no network):
  tools/data/free-exercise-db.trim.json  data fields only from yuhonas/free-exercise-db
                                         (Unlicense; no images, no instruction text)
  tools/exercise_taxonomy.json           16 muscles, equipment ids, presets
  tools/exercise_overrides.json          the curated list: equipment sets, load model, our own cue

Usage:
  python3 tools/build_exercises.py           write the assets and print preset coverage
  python3 tools/build_exercises.py --check   fail if the assets differ from a fresh build,
                                             or any id is unknown (CI)

Exit 1 on any error. A preset leaving a muscle uncovered is reported, not an error.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOADS = {"dumbbell", "stack", "barbell", "bodyweight", "timed", "bands", "distance", "plates"}
SHOULDER_IDS = {"front-delts", "side-delts", "rear-delts"}


def slug(seed_id: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", seed_id.lower()).strip("-")
    return s


def load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def derive(seed_muscles, mmap, shoulders, errs, who):
    out = []
    for m in seed_muscles:
        if m == "shoulders":
            if not shoulders:
                errs.append(f"{who}: seed has shoulders, override needs 'shoulders'")
                continue
            t = shoulders
        elif m in mmap:
            t = mmap[m]
        else:
            errs.append(f"{who}: unmapped seed muscle {m!r}")
            continue
        if t not in out:
            out.append(t)
    return out


def build():
    errs = []
    tax = load_json(ROOT / "tools/exercise_taxonomy.json")
    seed = {e["id"]: e for e in load_json(ROOT / "tools/data/free-exercise-db.trim.json")}
    over = load_json(ROOT / "tools/exercise_overrides.json")
    muscles = {m["id"] for m in tax["muscles"]}
    equip = {e["id"] for e in tax["equipment"]}
    if len(muscles) != 16:
        errs.append(f"taxonomy has {len(muscles)} muscles, expected 16")
    for k, v in tax["seed_muscle_map"].items():
        if v not in muscles:
            errs.append(f"seed_muscle_map {k!r} -> unknown muscle {v!r}")
    if len({p["id"] for p in tax["presets"]}) != len(tax["presets"]):
        errs.append("duplicate preset id")
    for q in tax["equipment"]:
        if q["load"] not in LOADS | {"none"}:
            errs.append(f"equipment {q['id']}: unknown load {q['load']!r}")
    for p in tax["presets"]:
        for e in p["equipment"]:
            if e not in equip:
                errs.append(f"preset {p['id']}: unknown equipment {e!r}")

    ex, ids = [], set()
    for o in over:
        sid = o["seed"]
        who = sid
        s = seed.get(sid)
        if s is None:
            errs.append(f"{who}: not in the seed")
            continue
        eid = o.get("id") or slug(sid)
        if eid in ids:
            errs.append(f"{who}: duplicate id {eid}")
        ids.add(eid)
        if o["load"] not in LOADS:
            errs.append(f"{who}: unknown load {o['load']!r}")
        if not o.get("cue"):
            errs.append(f"{who}: missing cue")
        sh = o.get("shoulders")
        if sh and sh not in SHOULDER_IDS:
            errs.append(f"{who}: bad shoulders {sh!r}")
        mm = tax["seed_muscle_map"]
        prim = o["primary"] if "primary" in o else derive(s["primaryMuscles"], mm, sh, errs, who)
        sec = o["secondary"] if "secondary" in o else derive(s["secondaryMuscles"], mm, sh, errs, who)
        sec = [m for m in sec if m not in prim]
        for m in prim + sec:
            if m not in muscles:
                errs.append(f"{who}: unknown muscle {m!r}")
        if not prim:
            errs.append(f"{who}: no primary muscle")
        sets = o["equip"]
        if not sets or any(not st for st in sets):
            errs.append(f"{who}: empty equipment set")
        for st in sets:
            for e in st:
                if e not in equip:
                    errs.append(f"{who}: unknown equipment {e!r}")
        ex.append({
            "id": eid,
            "seed_id": sid,
            "name": s["name"],
            "primary": prim,
            "secondary": sec,
            "equipment_sets": sets,
            "load": o["load"],
            "unilateral": bool(o.get("unilateral")),
            "mechanic": s.get("mechanic"),
            "force": s.get("force"),
            "level": s.get("level"),
            "cue": o["cue"],
        })
    ex.sort(key=lambda e: e["id"])
    catalog = {"version": 1, "source": "yuhonas/free-exercise-db (Unlicense), data fields only; cues are our own",
               "exercises": ex}
    taxonomy = {"version": 1, "muscles": tax["muscles"], "equipment": tax["equipment"], "presets": tax["presets"]}
    return catalog, taxonomy, errs


def coverage(catalog, taxonomy):
    muscles = [m["id"] for m in taxonomy["muscles"]]
    res = {}
    for p in taxonomy["presets"]:
        have = set(p["equipment"]) | {"bodyweight"}
        ok = [e for e in catalog["exercises"] if any(set(s) <= have for s in e["equipment_sets"])]
        cov = {m: [e["id"] for e in ok if m in e["primary"]] for m in muscles}
        res[p["id"]] = (len(ok), cov)
    return res


def dump(obj) -> str:
    return json.dumps(obj, indent=1, ensure_ascii=False) + "\n"


def main():
    check = "--check" in sys.argv
    catalog, taxonomy, errs = build()
    if errs:
        print("\n".join("ERROR " + e for e in errs), file=sys.stderr)
        return 1
    for pid, (n, cov) in coverage(catalog, taxonomy).items():
        unc = [m for m, v in cov.items() if not v]
        print(f"preset {pid}: {n} exercises, covered {16 - len(unc)}/16, uncovered: {unc or 'none'}")
        print("  primaries per muscle:", {m: len(v) for m, v in cov.items()})
    outs = {ROOT / "assets/exercises.json": dump(catalog), ROOT / "assets/exercises_taxonomy.json": dump(taxonomy)}
    bad = 0
    for p, text in outs.items():
        if check:
            if not p.exists() or p.read_text(encoding="utf-8") != text:
                print(f"DRIFT {p.relative_to(ROOT)}: run python3 tools/build_exercises.py", file=sys.stderr)
                bad = 1
        else:
            p.write_text(text, encoding="utf-8")
    return bad


if __name__ == "__main__":
    sys.exit(main())
