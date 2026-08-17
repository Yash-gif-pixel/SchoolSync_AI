"""The cover matcher, tested without a database.

`find_substitutes` is pure: timetable rows and staff in, ranked suggestions
out. That makes the rules that actually matter — who is genuinely free, and in
what order they should be offered — cheap to pin down.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.substitution import dates_in_range, find_substitutes  # noqa: E402

MON = dt.date(2026, 8, 17)   # a Monday
TUE = dt.date(2026, 8, 18)
SUN = dt.date(2026, 8, 23)

MATHS, SCIENCE = "dept-maths", "dept-science"

# Absent teacher, plus four colleagues with different reasons to be picked.
STAFF = [
    {"id": "away", "full_name": "Isha Singh", "department_id": MATHS},
    {"id": "maths_busy", "full_name": "Ravi Kumar", "department_id": MATHS},
    {"id": "maths_free", "full_name": "Priya Nair", "department_id": MATHS},
    {"id": "sci_free", "full_name": "Arun Das", "department_id": SCIENCE},
    {"id": "sci_light", "full_name": "Meena Rao", "department_id": SCIENCE},
]


def entry(eid, teacher, slot, dow=1, slot_index=3, cls="8B", subject="Maths"):
    return {
        "entry_id": eid,
        "slot_id": slot,
        "teacher_id": teacher,
        "class_name": cls,
        "subject_name": subject,
        "day_of_week": dow,
        "slot_index": slot_index,
    }


def match(timetable, **kwargs):
    return find_substitutes(
        absent_teacher_id="away",
        from_date=kwargs.pop("from_date", MON),
        to_date=kwargs.pop("to_date", MON),
        timetable=timetable,
        teachers=kwargs.pop("teachers", STAFF),
        other_absences=kwargs.pop("other_absences", {}),
        **kwargs,
    )


# ------------------------------------------------------------- date range
def test_sunday_is_not_a_school_day():
    days = dates_in_range(dt.date(2026, 8, 17), dt.date(2026, 8, 24))
    assert SUN not in days
    assert len(days) == 7  # Mon-Sat, then the following Monday


def test_a_single_day_range_is_that_day():
    assert dates_in_range(MON, MON) == [MON]


# ---------------------------------------------------------------- ranking
def test_the_absent_teacher_is_never_their_own_cover():
    out = match([entry("e1", "away", "slot-3")])
    assert all(s["substitute_teacher_id"] != "away" for s in out)


def test_a_teacher_teaching_that_slot_is_not_offered():
    out = match([
        entry("e1", "away", "slot-3"),
        entry("e2", "maths_busy", "slot-3", cls="9A"),
    ])
    assert "maths_busy" not in {s["substitute_teacher_id"] for s in out}


def test_same_department_outranks_a_lighter_load():
    """Domain match beats load balance: a Maths teacher with a full day is a
    better cover for a Maths lesson than a free Science teacher."""
    timetable = [
        entry("e1", "away", "slot-3"),
        # The other Maths teacher is in front of a class this period, so the
        # choice really is "heavily loaded Maths" against "free Science".
        entry("e0", "maths_busy", "slot-3", cls="9A"),
    ]
    # Give the remaining Maths colleague a heavy day, elsewhere in it.
    for i, slot in enumerate(["slot-1", "slot-2", "slot-4"]):
        timetable.append(entry(f"m{i}", "maths_free", slot, slot_index=i))

    out = match(timetable)
    top = [s for s in out if s["rank"] == 1][0]
    assert top["substitute_teacher_id"] == "maths_free"
    assert "same department" in top["rationale"]


def test_within_a_department_the_lighter_day_wins():
    timetable = [entry("e1", "away", "slot-3")]
    timetable += [entry(f"s{i}", "sci_free", s, slot_index=i)
                  for i, s in enumerate(["slot-1", "slot-2"])]

    out = match(timetable, teachers=[t for t in STAFF
                                     if t["department_id"] != MATHS
                                     or t["id"] == "away"])
    ranked = sorted((s for s in out if not s["no_cover"]),
                    key=lambda s: s["rank"])
    assert ranked[0]["substitute_teacher_id"] == "sci_light"


def test_at_most_three_candidates_per_period():
    out = match([entry("e1", "away", "slot-3")])
    assert len({s["rank"] for s in out}) <= 3
    assert max(s["rank"] for s in out) <= 3


def test_the_rationale_says_why():
    out = match([entry("e1", "away", "slot-3")])
    assert all("free this period" in s["rationale"] for s in out)


# ------------------------------------------------------------ unavailable
def test_a_teacher_on_leave_is_not_offered():
    out = match([entry("e1", "away", "slot-3")],
                other_absences={MON: {"maths_free"}})
    assert "maths_free" not in {s["substitute_teacher_id"] for s in out}


def test_a_teacher_at_a_school_event_is_not_offered():
    out = match([entry("e1", "away", "slot-3")],
                event_commitments={MON: {"maths_free": "Annual Day"}})
    assert "maths_free" not in {s["substitute_teacher_id"] for s in out}


def test_no_cover_says_which_of_the_two_reasons_it_is():
    """An admin needs to know whether to look at the timetable or the event."""
    busy_everyone = {t["id"]: "Annual Day"
                     for t in STAFF if t["id"] != "away"}
    out = match([entry("e1", "away", "slot-3")],
                event_commitments={MON: busy_everyone})

    assert len(out) == 1
    assert out[0]["no_cover"] is True
    assert out[0]["substitute_teacher_id"] is None
    assert "Annual Day" in out[0]["rationale"]


# -------------------------------------------------- one free period, once
def test_a_teacher_already_covering_that_period_is_not_offered_again():
    """Two absences on the same day are two separate runs of this matcher.
    Without existing_cover both are offered the one colleague who is free in
    period 3, who is then confirmed twice and due in two rooms at once."""
    out = match(
        [entry("e1", "away", "slot-3")],
        existing_cover={MON: {("maths_free", "slot-3")}},
    )
    assert "maths_free" not in {s["substitute_teacher_id"] for s in out}
    # Everyone else is still fair game.
    assert "sci_free" in {s["substitute_teacher_id"] for s in out}


def test_cover_in_a_different_period_does_not_block_them():
    out = match(
        [entry("e1", "away", "slot-3")],
        existing_cover={MON: {("maths_free", "slot-9")}},
    )
    assert "maths_free" in {s["substitute_teacher_id"] for s in out}


def test_cover_on_a_different_day_does_not_block_them():
    out = match(
        [entry("e1", "away", "slot-3")],
        existing_cover={TUE: {("maths_free", "slot-3")}},
    )
    assert "maths_free" in {s["substitute_teacher_id"] for s in out}


# ------------------------------------------------------------- shape
def test_only_the_absent_teachers_periods_need_cover():
    out = match([
        entry("e1", "away", "slot-3"),
        entry("e2", "maths_busy", "slot-5", cls="9A"),
    ])
    assert {s["timetable_entry_id"] for s in out} == {"e1"}


def test_periods_on_other_weekdays_are_left_alone():
    out = match([
        entry("e1", "away", "slot-3", dow=1),
        entry("e2", "away", "slot-7", dow=2),
    ], from_date=MON, to_date=MON)
    assert {s["timetable_entry_id"] for s in out} == {"e1"}


def test_a_multi_day_absence_covers_each_day_separately():
    out = match([
        entry("e1", "away", "slot-3", dow=1),
        entry("e2", "away", "slot-7", dow=2),
    ], from_date=MON, to_date=TUE)
    assert {s["date"] for s in out} == {MON.isoformat(), TUE.isoformat()}


@pytest.mark.parametrize("field", [
    "date", "timetable_entry_id", "class_name", "subject_name",
    "slot_index", "day_of_week", "rank", "rationale", "no_cover",
])
def test_every_suggestion_carries_what_the_board_renders(field):
    out = match([entry("e1", "away", "slot-3")])
    assert all(field in s for s in out)
