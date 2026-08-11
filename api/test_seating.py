"""Exercise the seating engine against the live school data.

    python test_seating.py

Verifies the two promises independently of the code that made the plan: every
student gets exactly one seat, no seat is double-booked, only the selected
grades' own rooms are used, and nobody sits beside somebody from their own
class.
"""

from __future__ import annotations

import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from app.db import admin  # noqa: E402
from app.services.seating import plan_seating  # noqa: E402

GREEN, RED, AMBER, GREY, RESET = (
    "\033[92m", "\033[91m", "\033[93m", "\033[90m", "\033[0m")

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


def load() -> tuple[list, list, list]:
    sb = admin()
    classes = sb.table("classes").select(
        "id, grade, section, name, home_room_id").execute().data or []
    students, start = [], 0
    while True:
        rows = sb.table("students").select(
            "id, class_id, full_name, roll_no").range(
                start, start + 999).execute().data or []
        students.extend(rows)
        if len(rows) < 1000:
            break
        start += 1000
    rooms = sb.table("rooms").select(
        "id, name, type, block, floor_no, room_no, seat_rows, seat_cols"
    ).execute().data or []
    return classes, students, rooms


def verify(label, grades, classes, students, rooms, result) -> None:
    print(f"\n{'=' * 74}\n{label}\n{'=' * 74}")
    s = result.stats
    print(f"  students {s.get('students')}   seated {s.get('seated')}   "
          f"unseated {s.get('unseated')}")
    print(f"  rooms {s.get('rooms_used')}/{s.get('rooms_available')}   "
          f"seats {s.get('seats_available')}   "
          f"occupancy {(s.get('occupancy') or 0) * 100:.0f}%")

    for d in result.diagnostics:
        colour = {"error": RED, "warning": AMBER}.get(d.severity, GREY)
        print(f"  {colour}* {d.message}{RESET}")
        if d.detail:
            print(f"    {GREY}{d.detail}{RESET}")
    print()

    if not result.seats:
        check("produced a plan", False, "no seats allocated")
        return

    class_of = {st["id"]: st["class_id"] for st in students}
    cls_by_id = {c["id"]: c for c in classes}
    room_by_id = {r["id"]: r for r in rooms}

    # every student exactly once
    counts = Counter(x.student_id for x in result.seats)
    dupes = [k for k, v in counts.items() if v > 1]
    check("no student seated twice", not dupes, f"{len(dupes)} duplicated")

    expected = {
        st["id"] for st in students
        if cls_by_id.get(st["class_id"], {}).get("grade") in set(grades)
    }
    missing = expected - set(counts)
    check("every student has a seat", not missing,
          f"{len(missing)} without one")

    # no seat used twice
    seat_keys = Counter((x.room_id, x.row, x.col) for x in result.seats)
    clashes = [k for k, v in seat_keys.items() if v > 1]
    check("no seat double-booked", not clashes, f"{len(clashes)} clashes")

    # inside the grid
    outside = [
        x for x in result.seats
        if not (1 <= x.row <= (room_by_id[x.room_id]["seat_rows"] or 0)
                and 1 <= x.col <= (room_by_id[x.room_id]["seat_cols"] or 0))
    ]
    check("every seat is inside the room", not outside,
          f"{len(outside)} out of bounds")

    # THE rule the user asked for: only the selected grades' own rooms
    allowed = {
        c["home_room_id"] for c in classes
        if c["grade"] in set(grades) and c["home_room_id"]
    }
    trespass = {x.room_id for x in result.seats} - allowed
    check("only the selected grades' own rooms are used", not trespass,
          f"{len(trespass)} other rooms used: "
          f"{[room_by_id[r]['name'] for r in trespass]}" if trespass else "")

    # anti-copying
    occupied = {(x.room_id, x.row, x.col): class_of[x.student_id]
                for x in result.seats}
    breaches = []
    for (rid, r, c), cid in occupied.items():
        for dr, dc in ((0, 1), (1, 0)):
            if occupied.get((rid, r + dr, c + dc)) == cid:
                breaches.append((room_by_id[rid]["name"], r, c))
    check("nobody sits beside their own class", not breaches,
          f"{len(breaches)} breaches, e.g. {breaches[:3]}" if breaches else "")

    # spread: each room should hold a mix
    per_room: dict[str, set] = defaultdict(set)
    for x in result.seats:
        per_room[x.room_id].add(class_of[x.student_id])
    solo = [room_by_id[r]["name"] for r, cs in per_room.items() if len(cs) < 2]
    check("every room holds more than one class", not solo,
          f"{len(solo)} single-class rooms: {solo}" if solo else "")


def main() -> int:
    classes, students, rooms = load()
    shaped = [r for r in rooms if (r.get("seat_rows") or 0) > 0]
    print(f"{len(classes)} classes, {len(students)} students, "
          f"{len(shaped)}/{len(rooms)} rooms with a seat grid")
    if not shaped:
        print(f"\n{RED}No room has seat_rows/seat_cols set — apply "
              f"db/006_seating.sql first.{RESET}")
        return 1

    for label, grades in [
        ("ONE GRADE — Grade 1 alone (4 sections, its own 4 rooms)", [1]),
        ("TWO GRADES — Grades 1 and 2", [1, 2]),
        ("WHOLE SCHOOL — every grade with students", [1, 2, 3, 4, 5, 6]),
        ("SPARSE — Grade 6 (100 students, 200 seats)", [6]),
    ]:
        result = plan_seating(
            grades=grades, classes=classes, students=students, rooms=rooms)
        verify(label, grades, classes, students, rooms, result)

    print(f"\n{'=' * 74}\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
