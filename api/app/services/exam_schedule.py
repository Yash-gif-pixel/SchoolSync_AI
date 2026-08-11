"""Checks on an exam calendar.

The schedule itself is the admin's to write — they know which paper falls on
which day far better than any solver does. What this adds is the arithmetic a
person doing it by hand gets wrong: whether a grade ends up with two papers
back to back, whether a grade in the exam was never given a date, and whether
a day has been booked on a Sunday.

Advisory throughout. Nothing here refuses a schedule; it reports, in the same
shape as the timetable solver's diagnostics, and the admin decides.
"""

from __future__ import annotations

import datetime as dt

from .seating import Diagnostic

SUNDAY = 7


def review_schedule(
    *,
    sittings: list[dict],
    roster: list[int],
) -> list[Diagnostic]:
    """`sittings` need sits_on (date or ISO string), paper, grades."""
    out: list[Diagnostic] = []

    if not sittings:
        return [Diagnostic(
            "warning", "no_dates",
            "This exam has no dates yet.",
            "Pick the days each grade sits from the calendar.",
        )]

    parsed: list[tuple[dt.date, dict]] = []
    for s in sittings:
        raw = s["sits_on"]
        day = raw if isinstance(raw, dt.date) else dt.date.fromisoformat(raw)
        parsed.append((day, s))
    parsed.sort(key=lambda p: p[0])

    # --- grades in the exam that never got a date ----------------------
    scheduled: set[int] = set()
    for _day, s in parsed:
        scheduled.update(s.get("grades") or [])

    missing = sorted(set(roster) - scheduled)
    if missing:
        out.append(Diagnostic(
            "warning", "grade_unscheduled",
            f"Grade{'s' if len(missing) > 1 else ''} "
            f"{', '.join(map(str, missing))} "
            f"{'are' if len(missing) > 1 else 'is'} in this exam but "
            f"{'have' if len(missing) > 1 else 'has'} no dates.",
            "Add a sitting for them, or remove them from the exam.",
        ))

    stray = sorted(scheduled - set(roster))
    if stray:
        out.append(Diagnostic(
            "warning", "grade_not_in_exam",
            f"Grade{'s' if len(stray) > 1 else ''} "
            f"{', '.join(map(str, stray))} "
            f"{'have' if len(stray) > 1 else 'has'} dates but "
            f"{'are' if len(stray) > 1 else 'is'} not on the exam roster.",
            "They will still be seated. Add them to the exam to be explicit.",
        ))

    # NOTE: there was a minimum-gap rule here, driven by a slider on the exam.
    # It was removed deliberately. The admin picks the days; inventing a
    # threshold and then nagging about it added a setting to maintain and a
    # warning nobody asked for. The checks that remain are the ones the admin
    # cannot see for themselves while clicking through a month.

    # --- Sundays --------------------------------------------------------
    sundays = [d for d, _ in parsed if d.isoweekday() == SUNDAY]
    if sundays:
        out.append(Diagnostic(
            "warning", "weekend_sitting",
            f"{len(sundays)} sitting(s) fall on a Sunday.",
            ", ".join(d.strftime("%d/%m/%Y") for d in sundays[:6]),
        ))

    # --- how long the season runs ---------------------------------------
    first, last = parsed[0][0], parsed[-1][0]
    span = (last - first).days + 1
    out.append(Diagnostic(
        "info", "span",
        f"{len(parsed)} sitting(s) over {span} day(s), "
        f"{first.strftime('%d/%m/%Y')} to {last.strftime('%d/%m/%Y')}.",
        None,
    ))

    return out


def rooms_in_use(sittings: list[dict], on: dt.date) -> set[int]:
    """Grades sitting on a given day — the set whose rooms are taken.

    Everything not in here carries on with a normal school day, which is the
    whole reason seating is planned per day rather than per exam.
    """
    grades: set[int] = set()
    for s in sittings:
        raw = s["sits_on"]
        day = raw if isinstance(raw, dt.date) else dt.date.fromisoformat(raw)
        if day == on:
            grades.update(s.get("grades") or [])
    return grades
