"""Exam seating allocation.

The problem, stated plainly: seat every student sitting an exam so that nobody
is next to somebody writing the same paper, using only the rooms belonging to
the grades actually sitting it.

That last clause is the constraint that shapes everything. A school does not
empty out Grade 8 so Grade 1 can spread out — Grade 1 writes in Grade 1's own
rooms, and the rest of the school carries on. So the seat supply is fixed by
the selection, and the anti-copying guarantee has to come from *arrangement*
rather than from empty space.

Two stages, because they are genuinely different problems:

  1. Deal students to rooms. Each section is spread evenly across every
     available room rather than kept together, so no room ends up dominated
     by one section — that even mix is what makes stage 2 solvable.

  2. Lay out each room. Seats are filled with whichever section has the most
     students still waiting, skipping any section already sitting immediately
     left or directly in front. Choosing the largest remaining is what stops
     one section being left over at the end with only adjacent seats free.

No CP-SAT here, unlike the timetable. Stage 2 is a graph-colouring problem
with a known-good greedy, it runs in milliseconds on a thousand students, and
a solver would add a time limit and a failure mode in exchange for nothing.
What it does borrow from the timetable is the honesty: every breach is
counted, verified independently, and reported rather than hidden.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field


@dataclass
class Diagnostic:
    severity: str          # 'error' | 'warning' | 'info'
    code: str
    message: str
    detail: str | None = None

    def as_dict(self) -> dict:
        return {
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "detail": self.detail,
        }


@dataclass
class Seat:
    student_id: str
    room_id: str
    row: int
    col: int

    def as_dict(self) -> dict:
        return {
            "student_id": self.student_id,
            "room_id": self.room_id,
            "seat_row": self.row,
            "seat_col": self.col,
        }


@dataclass
class SeatingResult:
    seats: list[Seat] = field(default_factory=list)
    diagnostics: list[Diagnostic] = field(default_factory=list)
    stats: dict = field(default_factory=dict)

    @property
    def seated_everyone(self) -> bool:
        return not self.stats.get("unseated")


def plan_seating(
    *,
    grades: list[int],
    classes: list[dict],
    students: list[dict],
    rooms: list[dict],
) -> SeatingResult:
    """Build a seating plan.

    `classes` need id, grade, section, name, home_room_id.
    `students` need id, class_id, full_name, roll_no.
    `rooms`    need id, name, seat_rows, seat_cols.
    """
    diagnostics: list[Diagnostic] = []

    wanted = set(grades)
    sitting = [c for c in classes if c["grade"] in wanted]
    if not sitting:
        return SeatingResult(diagnostics=[Diagnostic(
            "error", "no_classes",
            "None of the selected grades have any classes.",
            f"Selected: {sorted(wanted) or 'nothing'}.",
        )])

    class_ids = {c["id"] for c in sitting}
    by_class: dict[str, list[dict]] = defaultdict(list)
    for s in students:
        if s["class_id"] in class_ids:
            by_class[s["class_id"]].append(s)
    for roll in by_class.values():
        roll.sort(key=lambda s: (s.get("roll_no") or 0, s.get("full_name") or ""))

    total_students = sum(len(v) for v in by_class.values())
    if not total_students:
        return SeatingResult(diagnostics=[Diagnostic(
            "error", "no_students",
            "The selected grades have no students on roll.",
            "Nothing to seat. Pick a grade that has students.",
        )])

    empty = [c["name"] for c in sitting if not by_class.get(c["id"])]
    if empty:
        diagnostics.append(Diagnostic(
            "info", "empty_class",
            f"{len(empty)} selected class(es) have no students: "
            f"{', '.join(sorted(empty))}.",
            "They were skipped.",
        ))

    # --- the rooms those grades own ------------------------------------
    room_by_id = {r["id"]: r for r in rooms}
    available: list[dict] = []
    homeless: list[str] = []
    for c in sorted(sitting, key=lambda c: (c["grade"], c["section"])):
        rid = c.get("home_room_id")
        if not rid or rid not in room_by_id:
            homeless.append(c["name"])
            continue
        room = room_by_id[rid]
        if room not in available:
            available.append(room)

    if homeless:
        diagnostics.append(Diagnostic(
            "warning", "no_home_room",
            f"{len(homeless)} class(es) have no home room: "
            f"{', '.join(sorted(homeless))}.",
            "Their students still need seats, but the class contributes none.",
        ))

    if not available:
        return SeatingResult(diagnostics=diagnostics + [Diagnostic(
            "error", "no_rooms",
            "None of the selected grades have a room to sit in.",
            "Assign home rooms to those classes first.",
        )])

    def capacity(r: dict) -> int:
        return int(r.get("seat_rows") or 0) * int(r.get("seat_cols") or 0)

    unshaped = [r["name"] for r in available if capacity(r) <= 0]
    if unshaped:
        diagnostics.append(Diagnostic(
            "warning", "no_seat_grid",
            f"{len(unshaped)} room(s) have no seat layout: "
            f"{', '.join(sorted(unshaped))}.",
            "Set rows and columns on them; they were left out of the plan.",
        ))
        available = [r for r in available if capacity(r) > 0]

    total_seats = sum(capacity(r) for r in available)
    if total_seats < total_students:
        diagnostics.append(Diagnostic(
            "error", "not_enough_seats",
            f"{total_students - total_seats} student(s) cannot be seated.",
            f"The selected grades have {total_seats} seats across "
            f"{len(available)} of their own rooms, but {total_students} "
            f"students are sitting. Add a grade whose rooms are free, or "
            f"split the exam into sittings.",
        ))

    # --- stage 1: deal each section evenly across every room -----------
    #
    # A section is dealt round-robin, and each section starts at a different
    # room, so the rooms fill evenly AND every room ends up holding a slice of
    # several sections. Keeping a section together would make stage 2
    # impossible: a room of nothing but 1A has no valid arrangement.
    room_seats = {r["id"]: capacity(r) for r in available}
    room_order = [r["id"] for r in available]
    holding: dict[str, dict[str, list[dict]]] = {
        rid: defaultdict(list) for rid in room_order
    }
    used = {rid: 0 for rid in room_order}

    unseated: list[dict] = []
    ordered_classes = sorted(sitting, key=lambda c: (c["grade"], c["section"]))
    for offset, cls in enumerate(ordered_classes):
        roll = by_class.get(cls["id"]) or []
        cursor = offset
        for student in roll:
            placed = False
            # One full lap looking for a room with a free seat.
            for step in range(len(room_order)):
                rid = room_order[(cursor + step) % len(room_order)]
                if used[rid] < room_seats[rid]:
                    holding[rid][cls["id"]].append(student)
                    used[rid] += 1
                    cursor = (cursor + step + 1) % len(room_order)
                    placed = True
                    break
            if not placed:
                unseated.append(student)

    # --- stage 2: lay out each room ------------------------------------
    seats: list[Seat] = []
    breaches = 0
    for room in available:
        rid = room["id"]
        placed, room_breaches = _fill_room(
            room=room,
            groups=holding[rid],
        )
        seats.extend(placed)
        breaches += room_breaches

    # Measured from the finished plan rather than trusted from the loop that
    # built it — the same reason the timetable recounts its own gaps.
    verified = _count_adjacent_breaches(seats, students)

    rooms_used = len({s.room_id for s in seats})
    stats = {
        "students": total_students,
        "seated": len(seats),
        "unseated": len(unseated),
        "rooms_available": len(available),
        "rooms_used": rooms_used,
        "seats_available": total_seats,
        "occupancy": round(len(seats) / total_seats, 3) if total_seats else 0,
        "adjacent_same_class": verified,
        "grades": sorted(wanted),
    }

    if verified:
        diagnostics.append(Diagnostic(
            "warning", "adjacent_same_class",
            f"{verified} student(s) sit next to someone from the same class.",
            "This happens when one class fills a room on its own — there is "
            "no arrangement that avoids it. Include another grade to fix it.",
        ))
    elif seats:
        diagnostics.append(Diagnostic(
            "info", "clean",
            "No student sits beside or in front of anyone from their own "
            "class.",
            f"{len(seats)} students across {rooms_used} rooms.",
        ))

    return SeatingResult(seats=seats, diagnostics=diagnostics, stats=stats)


def _fill_room(
    *, room: dict, groups: dict[str, list[dict]]
) -> tuple[list[Seat], int]:
    """Lay out one room.

    Walks the grid in reading order and takes from whichever class has the
    most students still waiting, excluding any class already sitting to the
    left or directly in front. Largest-remaining-first is the part that
    matters: serving the biggest group while it still has choices is what
    prevents it being stranded at the end with only adjacent seats left.
    """
    rows = int(room["seat_rows"])
    cols = int(room["seat_cols"])

    waiting = {cid: list(v) for cid, v in groups.items() if v}
    grid: list[list[str | None]] = [[None] * cols for _ in range(rows)]
    placed: list[Seat] = []
    breaches = 0

    for r in range(rows):
        for c in range(cols):
            if not waiting:
                break

            left = grid[r][c - 1] if c > 0 else None
            above = grid[r - 1][c] if r > 0 else None
            blocked = {x for x in (left, above) if x}

            options = [cid for cid in waiting if cid not in blocked]
            if options:
                pick = max(options, key=lambda cid: len(waiting[cid]))
            else:
                # Only same-class students remain. Seating one is still better
                # than leaving them unseated; the breach gets counted and
                # reported rather than quietly tolerated.
                pick = max(waiting, key=lambda cid: len(waiting[cid]))
                breaches += 1

            student = waiting[pick].pop(0)
            if not waiting[pick]:
                del waiting[pick]

            grid[r][c] = pick
            placed.append(Seat(student["id"], room["id"], r + 1, c + 1))

    return placed, breaches


def _count_adjacent_breaches(seats: list[Seat], students: list[dict]) -> int:
    """Independent check: how many students sit orthogonally beside somebody
    from their own class. Counts pairs, not seats."""
    class_of = {s["id"]: s["class_id"] for s in students}
    occupied: dict[tuple[str, int, int], str] = {
        (s.room_id, s.row, s.col): class_of.get(s.student_id) for s in seats
    }

    breaches = 0
    for (room_id, row, col), cid in occupied.items():
        if cid is None:
            continue
        # Right and below only, so each pair is counted once.
        for dr, dc in ((0, 1), (1, 0)):
            other = occupied.get((room_id, row + dr, col + dc))
            if other is not None and other == cid:
                breaches += 1
    return breaches
