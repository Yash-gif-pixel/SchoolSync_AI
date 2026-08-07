"""Exercise the timetable solver against the live school data.

    python test_solver.py            # solve the real school
    python test_solver.py --stress   # also run the over-committed fixture

Checks correctness properly: no teacher or class double-booked, every
curriculum requirement met, lab capacity respected.
"""

from __future__ import annotations

import argparse
import copy
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from app.routers.timetable import load_school  # noqa: E402
from app.services.timetable import solve  # noqa: E402

GREEN, RED, AMBER, GREY, RESET = "\033[92m", "\033[91m", "\033[93m", "\033[90m", "\033[0m"

passed = failed = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    colour = GREEN if ok else RED
    print(f"  {colour}[{'PASS' if ok else 'FAIL'}]{RESET} {label}"
          f"{'  -- ' + detail if detail else ''}")
    if ok:
        passed += 1
    else:
        failed += 1


def verify(data: dict, result) -> None:
    """Independent check of the solution — not trusting the solver's word."""
    assignments = {a["id"]: a for a in data["assignments"]}
    slots = {s["id"]: s for s in data["slots"]}

    by_teacher_slot: dict[tuple[str, str], int] = defaultdict(int)
    by_class_slot: dict[tuple[str, str], int] = defaultdict(int)
    by_lab_slot: dict[tuple[str, str], int] = defaultdict(int)
    placed: dict[str, int] = defaultdict(int)
    room_slot: dict[tuple[str, str], int] = defaultdict(int)

    for e in result.entries:
        a = assignments[e["assignment_id"]]
        by_teacher_slot[a["teacher_id"], e["slot_id"]] += 1
        by_class_slot[a["class_id"], e["slot_id"]] += 1
        placed[a["id"]] += 1
        if a["requires_lab"]:
            by_lab_slot[a["lab_type"], e["slot_id"]] += 1
        if e["room_id"]:
            room_slot[e["room_id"], e["slot_id"]] += 1

    clashes = [k for k, v in by_teacher_slot.items() if v > 1]
    check("no teacher is in two places at once", not clashes,
          f"{len(clashes)} clashes" if clashes else "")

    cclashes = [k for k, v in by_class_slot.items() if v > 1]
    check("no class has two lessons at once", not cclashes,
          f"{len(cclashes)} clashes" if cclashes else "")

    over = [(k, v) for k, v in by_lab_slot.items()
            if v > data["lab_capacity"].get(k[0], 0)]
    check("lab capacity never exceeded", not over,
          f"{len(over)} overflows" if over else "")

    dbl = [k for k, v in room_slot.items() if v > 1]
    check("no room is double-booked", not dbl,
          f"{len(dbl)} double-booked" if dbl else "")

    short = [(a, placed[aid], a["periods_per_week"])
             for aid, a in assignments.items()
             if placed[aid] != a["periods_per_week"]]
    check("every curriculum requirement met", not short,
          f"{len(short)} assignments short" if short else "")

    # spreading
    per_day: dict[tuple[str, str, int], int] = defaultdict(int)
    for e in result.entries:
        a = assignments[e["assignment_id"]]
        per_day[a["class_id"], a["subject_id"], slots[e["slot_id"]]["day_of_week"]] += 1
    worst = max(per_day.values()) if per_day else 0
    check("no subject stacked more than 2x in a day", worst <= 2, f"max {worst}/day")

    lab_no_room = [e for e in result.entries
                   if assignments[e["assignment_id"]]["requires_lab"] and not e["room_id"]]
    check("every lab period got a lab room", not lab_no_room,
          f"{len(lab_no_room)} without" if lab_no_room else "")


def report(result, title: str) -> None:
    print(f"\n{'=' * 74}\n{title}\n{'=' * 74}")
    s = result.stats
    placed = s.get("entries") or 0
    unplaced = s.get("unplaced_periods") or 0
    print(f"  status          : {result.status}  ({s.get('solver_status')})")
    print(f"  solve time      : {s.get('wall_seconds')}s"
          + (f"  (phase 1: {s['phase1_seconds']}s)" if s.get("phase1_seconds") else ""))
    print(f"  phases          : {s.get('phases', 1)}"
          + ("  strict packing" if s.get("strict_packing") else "  relaxed packing"))
    print(f"  variables       : {s.get('variables', 0):,}")
    print(f"  entries placed  : {placed:,} of {placed + unplaced:,}")
    print(f"  unplaced        : {unplaced}")
    if s.get("gaps_before_optimising") is not None:
        print(f"  teacher gaps    : {s.get('teacher_gaps')}  "
              f"(was {s['gaps_before_optimising']} before optimising)")
    else:
        print(f"  teacher gaps    : {s.get('teacher_gaps')}")
    print(f"  branches        : {s.get('branches', 0):,}")

    errs = [d for d in result.diagnostics if d.severity == "error"]
    warns = [d for d in result.diagnostics if d.severity == "warning"]
    if errs:
        print(f"\n  {RED}{len(errs)} error(s):{RESET}")
        for d in errs[:8]:
            print(f"    {RED}• {d.message}{RESET}")
            if d.detail:
                print(f"      {GREY}{d.detail}{RESET}")
        if len(errs) > 8:
            print(f"    {GREY}… and {len(errs) - 8} more{RESET}")
    if warns:
        print(f"\n  {AMBER}{len(warns)} warning(s){RESET}"
              + (f" — e.g. {warns[0].message}" if warns else ""))
    if not errs and not warns:
        print(f"\n  {GREEN}clean — no diagnostics{RESET}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stress", action="store_true",
                    help="also run a deliberately over-committed fixture")
    ap.add_argument("--time-limit", type=float, default=20.0)
    ap.add_argument("--no-gaps", action="store_true",
                    help="skip the gap-minimising objective")
    args = ap.parse_args()

    print("Loading school…")
    data = load_school()
    print(f"  {len(data['classes'])} classes, {len(data['teachers'])} teachers, "
          f"{len(data['assignments'])} assignments, {len(data['slots'])} teaching slots")

    result = solve(data, time_limit=args.time_limit, optimise_gaps=not args.no_gaps)
    report(result, "REAL SCHOOL")
    print()
    verify(data, result)

    check(f"solved within {args.time_limit}s",
          result.stats.get("wall_seconds", 999) <= args.time_limit + 3,
          f"{result.stats.get('wall_seconds')}s")

    if args.stress:
        print(f"\n{'=' * 74}\nSTRESS: deliberately over-committing one teacher\n{'=' * 74}")
        broken = copy.deepcopy(data)
        victim = broken["assignments"][0]["teacher_id"]
        name = broken["teacher_by_id"][victim]["full_name"]
        moved = 0
        for a in broken["assignments"]:
            if a["teacher_id"] != victim and moved < 6:
                a["teacher_id"] = victim
                moved += 1
        load = sum(a["periods_per_week"] for a in broken["assignments"]
                   if a["teacher_id"] == victim)
        print(f"  moved {moved} assignments onto {name} -> {load} periods "
              f"in a {len(broken['slots'])}-slot week")

        broken["teacher_by_id"] = data["teacher_by_id"]
        r2 = solve(broken, time_limit=args.time_limit, optimise_gaps=False)
        report(r2, "OVER-COMMITTED SCHOOL")

        print()
        check("returns a result rather than throwing", r2 is not None)
        check("does not silently succeed", not r2.placed_everything)
        over = [d for d in r2.diagnostics if d.code == "teacher_overcommitted"]
        check("names the over-committed teacher up front", bool(over),
              over[0].message if over else "no preflight diagnostic")
        unplaced = [d for d in r2.diagnostics if d.code == "unplaced"]
        check("says exactly which periods went unplaced", bool(unplaced),
              unplaced[0].message if unplaced else "none reported")
        check("still placed most of the timetable",
              r2.stats.get("entries", 0) > len(data["assignments"]),
              f"{r2.stats.get('entries')} entries")

    print(f"\n{'=' * 74}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
