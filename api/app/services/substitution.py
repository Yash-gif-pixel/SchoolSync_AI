"""Find cover for an absent teacher's periods.

A greedy ranked match rather than an optimisation: when a teacher goes off
sick the admin wants a shortlist they can act on in seconds, with the reasoning
visible. Three criteria, in strict priority order:

  1. Availability — genuinely free in that exact slot, and not themselves away.
  2. Domain match — same department, so the cover period is worth something.
  3. Load balance — of the remaining candidates, whoever is carrying least
     that day, so cover does not always land on the same people.

Every suggestion carries the rationale that produced it, because "why this
person?" is the first question an administrator asks.
"""

from __future__ import annotations

import datetime as dt
from collections import defaultdict
from dataclasses import dataclass

# Sunday is not a school day; slots run day_of_week 1..6 (Mon..Sat).
NON_SCHOOL_WEEKDAY = 7


@dataclass
class Candidate:
    teacher_id: str
    name: str
    same_department: bool
    load_that_day: int
    load_that_week: int
    rationale: str

    @property
    def sort_key(self) -> tuple:
        # same-department first, then lightest day, then lightest week
        return (0 if self.same_department else 1, self.load_that_day, self.load_that_week)


def dates_in_range(start: dt.date, end: dt.date) -> list[dt.date]:
    out, d = [], start
    while d <= end:
        if d.isoweekday() != NON_SCHOOL_WEEKDAY:
            out.append(d)
        d += dt.timedelta(days=1)
    return out


def find_substitutes(
    *,
    absent_teacher_id: str,
    from_date: dt.date,
    to_date: dt.date,
    timetable: list[dict],
    teachers: list[dict],
    other_absences: dict[dt.date, set[str]],
    event_commitments: dict[dt.date, dict[str, str]] | None = None,
    existing_cover: dict[dt.date, set[tuple[str, str]]] | None = None,
    max_per_period: int = 3,
) -> list[dict]:
    """Suggestions for every period the absent teacher would have taught.

    `timetable` rows need: entry_id, teacher_id, class_name, subject_name,
    department_id, day_of_week, slot_index, slot_id.
    `other_absences` maps a date to the teachers already away that day.
    `event_commitments` maps a date to {teacher_id: event name} — somebody
    rehearsing for Annual Day is in the building but is not available to
    cover, and suggesting them is worse than admitting there is no cover.
    `existing_cover` maps a date to the (teacher, slot) pairs already
    confirmed. **A free period is only free once.** Two teachers off sick on
    the same Tuesday are two separate runs of this function, and without this
    both of them are offered the one colleague who happens to be free in
    period 3 — who is then confirmed twice and expected in two rooms at once.
    """
    events = event_commitments or {}
    covering = existing_cover or {}
    teacher_by_id = {t["id"]: t for t in teachers}
    absent = teacher_by_id.get(absent_teacher_id, {})
    absent_dept = absent.get("department_id")

    # Who is teaching what, when.
    busy: dict[tuple[str, str], bool] = {}
    week_load: dict[str, int] = defaultdict(int)
    day_load: dict[tuple[str, int], int] = defaultdict(int)
    for row in timetable:
        busy[row["teacher_id"], row["slot_id"]] = True
        week_load[row["teacher_id"]] += 1
        day_load[row["teacher_id"], row["day_of_week"]] += 1

    mine = [r for r in timetable if r["teacher_id"] == absent_teacher_id]
    suggestions: list[dict] = []

    for date in dates_in_range(from_date, to_date):
        dow = date.isoweekday()
        on_duty_today = events.get(date, {})
        away_today = (
            other_absences.get(date, set())
            | set(on_duty_today)
            | {absent_teacher_id}
        )
        covering_today = covering.get(date, set())

        for period in [r for r in mine if r["day_of_week"] == dow]:
            candidates: list[Candidate] = []

            for t in teachers:
                tid = t["id"]
                if tid in away_today:
                    continue
                if busy.get((tid, period["slot_id"])):
                    continue
                if (tid, period["slot_id"]) in covering_today:
                    # Already standing in for somebody else this period.
                    continue

                same_dept = (
                    absent_dept is not None
                    and t.get("department_id") == absent_dept
                )
                d_load = day_load[tid, dow]
                bits = ["free this period"]
                if same_dept:
                    bits.append("same department")
                else:
                    bits.append("other department")
                bits.append(f"{d_load} periods that day")

                candidates.append(Candidate(
                    teacher_id=tid,
                    name=t.get("full_name", "?"),
                    same_department=same_dept,
                    load_that_day=d_load,
                    load_that_week=week_load[tid],
                    rationale=" · ".join(bits),
                ))

            candidates.sort(key=lambda c: c.sort_key)
            top = candidates[:max_per_period]

            if not top:
                # Say which of the two reasons it is. "No teacher is free"
                # sends an admin hunting through the timetable; "eleven are at
                # Annual Day" tells them what to actually do about it.
                why = "No teacher is free this period."
                if on_duty_today:
                    names = sorted(set(on_duty_today.values()))
                    why = (
                        f"No teacher is free this period — "
                        f"{len(on_duty_today)} are committed to "
                        f"{' and '.join(names)}."
                    )
                suggestions.append({
                    "date": date.isoformat(),
                    "timetable_entry_id": period["entry_id"],
                    "class_name": period["class_name"],
                    "subject_name": period["subject_name"],
                    "slot_index": period["slot_index"],
                    "day_of_week": dow,
                    "substitute_teacher_id": None,
                    "rank": None,
                    "rationale": why,
                    "no_cover": True,
                })
                continue

            for rank, cand in enumerate(top, start=1):
                suggestions.append({
                    "date": date.isoformat(),
                    "timetable_entry_id": period["entry_id"],
                    "class_name": period["class_name"],
                    "subject_name": period["subject_name"],
                    "slot_index": period["slot_index"],
                    "day_of_week": dow,
                    "substitute_teacher_id": cand.teacher_id,
                    "substitute_name": cand.name,
                    "rank": rank,
                    "rationale": cand.rationale,
                    "no_cover": False,
                })

    return suggestions
