"""The staffing forecast.

Every number it produces is meant to decompose into arithmetic somebody can
say out loud, so it is worth pinning that arithmetic down.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.forecast import (  # noqa: E402
    Rates,
    cover_capacity,
    forecast,
    measure,
    poisson_tail,
    school_days,
)

MON = dt.date(2026, 8, 17)
SUN = dt.date(2026, 8, 23)

SCIENCE, MATHS = "dept-sci", "dept-maths"
TEACHERS = [
    {"id": "t1", "department_id": SCIENCE},
    {"id": "t2", "department_id": SCIENCE},
    {"id": "t3", "department_id": MATHS},
]


# ------------------------------------------------------------- school days
def test_sunday_is_skipped():
    days = list(school_days(MON, MON + dt.timedelta(days=7)))
    assert SUN not in days
    assert len(days) == 7


# ------------------------------------------------------------- probability
def test_poisson_tail_is_zero_for_no_expected_absences():
    assert poisson_tail(0, 0) == 0.0
    assert poisson_tail(-1, 3) == 0.0


def test_poisson_tail_falls_as_the_threshold_rises():
    assert poisson_tail(3.0, 0) > poisson_tail(3.0, 3) > poisson_tail(3.0, 10)


def test_poisson_tail_stays_a_probability():
    for lam in (0.1, 1, 5, 40):
        for k in (0, 1, 5):
            assert 0.0 <= poisson_tail(lam, k) <= 1.0


def test_poisson_tail_matches_the_hand_calculation():
    # P(X > 0) = 1 - e^-lam
    import math
    assert poisson_tail(2.0, 0) == pytest.approx(1 - math.exp(-2.0), abs=1e-9)


# ------------------------------------------------------------- measurement
def test_rates_are_measured_from_approved_leave_only():
    rows = [
        {"teacher_id": "t1", "from_date": MON.isoformat(),
         "to_date": MON.isoformat(), "status": "approved"},
        {"teacher_id": "t2", "from_date": MON.isoformat(),
         "to_date": MON.isoformat(), "status": "rejected"},
        {"teacher_id": "t3", "from_date": MON.isoformat(),
         "to_date": MON.isoformat(), "status": "pending_incharge"},
    ]
    rates = measure(rows, TEACHERS, MON, MON)
    assert rates.observed_absences == 1
    assert rates.overall_daily_rate == pytest.approx(1 / 3)


def test_a_multi_day_request_counts_once_per_school_day():
    rows = [{"teacher_id": "t1", "from_date": MON.isoformat(),
             "to_date": (MON + dt.timedelta(days=7)).isoformat(),
             "status": "approved"}]
    rates = measure(rows, TEACHERS, MON, MON + dt.timedelta(days=7))
    assert rates.observed_absences == 7  # the Sunday is not one of them


def test_a_thin_weekday_sample_does_not_become_a_trend():
    """One Monday absence is not evidence that Mondays are bad."""
    rows = [{"teacher_id": "t1", "from_date": MON.isoformat(),
             "to_date": MON.isoformat(), "status": "approved"}]
    rates = measure(rows, TEACHERS, MON, MON + dt.timedelta(days=13))
    assert rates.by_weekday[1] == 1.0


# ---------------------------------------------------------------- capacity
def test_free_periods_come_from_what_is_actually_taught():
    timetable = [{"teacher_id": "t1", "day_of_week": 1} for _ in range(4)]
    cap = cover_capacity(timetable, TEACHERS, slots_per_day=6)

    science_mon = cap[SCIENCE, 1]
    # t1 teaches 4 of 6, t2 teaches none: 2 + 6 free.
    assert science_mon["free_periods"] == 8
    assert science_mon["teachers"] == 2


def test_a_department_with_no_timetable_can_absorb_everyone():
    cap = cover_capacity([], TEACHERS, slots_per_day=6)
    assert cap[MATHS, 1]["absorbable_absences"] == 1  # its one teacher


# ---------------------------------------------------------------- forecast
def _forecast(**kw):
    return forecast(
        rates=kw.pop("rates", Rates(overall_daily_rate=0.02)),
        capacity=kw.pop("capacity", {}),
        departments=kw.pop("departments", {SCIENCE: "Science"}),
        events=kw.pop("events", []),
        horizon_days=kw.pop("horizon_days", 3),
        today=kw.pop("today", MON),
    )


def test_an_event_on_a_school_with_no_slack_does_not_crash():
    """Regression: a school where no teacher has a department yet leaves zero
    free periods, and the percentage-of-slack line divided by it — turning
    the whole endpoint into a 500 rather than a warning."""
    out = _forecast(events=[{
        "name": "Annual Day", "date": MON.isoformat(), "teachers_required": 12,
    }])

    card = next(c for c in out["cards"] if c.get("event") == "Annual Day")
    assert card["severity"] == "critical"
    assert "100% of all slack" in card["because"]


def test_an_event_needing_nobody_raises_nothing():
    out = _forecast(events=[{
        "name": "Staff photo", "date": MON.isoformat(), "teachers_required": 0,
    }])
    assert not [c for c in out["cards"] if c.get("event")]


def test_the_horizon_is_respected_and_excludes_sundays():
    out = _forecast(horizon_days=7)
    dates = [d["date"] for d in out["days"]]
    assert len(dates) == 7
    assert SUN.isoformat() not in dates


def test_every_day_reports_the_multipliers_it_used():
    out = _forecast()
    for day in out["days"]:
        assert "weekday_multiplier" in day
        assert "seasonal_multiplier" in day
        assert "expected_absences" in day


def test_a_recurring_shortfall_is_reported_once_not_daily():
    """A department with no slack every Monday is a staffing shape. Repeating
    it for each Monday in the horizon is the noise that gets boards ignored."""
    capacity = {
        (SCIENCE, dow): {
            "free_periods": 0, "avg_periods_per_teacher": 6.0,
            "absorbable_absences": 0, "teachers": 20,
        }
        for dow in range(1, 7)
    }
    out = _forecast(capacity=capacity, horizon_days=21,
                    rates=Rates(overall_daily_rate=0.05))

    recurring = [c for c in out["cards"] if c.get("recurring")]
    assert len(recurring) == 1
    assert recurring[0]["department"] == "Science"
    assert len(recurring[0]["weekdays"]) > 1


def test_cards_are_ordered_worst_first():
    capacity = {
        (SCIENCE, dow): {
            "free_periods": 0, "avg_periods_per_teacher": 6.0,
            "absorbable_absences": 0, "teachers": 20,
        }
        for dow in range(1, 7)
    }
    out = _forecast(capacity=capacity, horizon_days=14,
                    rates=Rates(overall_daily_rate=0.05),
                    events=[{"name": "Sports Day", "date": MON.isoformat(),
                             "teachers_required": 15}])

    severities = [c["severity"] for c in out["cards"]]
    assert severities == sorted(severities, key=lambda s: s != "critical")


def test_the_method_is_stated_in_the_response():
    """An administrator is being asked to act on this; it has to be able to
    explain itself."""
    assert "Poisson" in _forecast()["method"]
