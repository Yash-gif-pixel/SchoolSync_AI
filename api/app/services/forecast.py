"""Predictive staffing: will we have enough teachers, and when won't we?

Deliberately NOT Prophet. Three reasons:

* It needs years of seasonality to beat a naive baseline. This school has
  90 days of history, so Prophet would be fitting noise.
* It drags in a Stan toolchain, pushing the container past 1 GB and making
  free-tier builds slow.
* It cannot be explained. An administrator is being asked to act on this
  number, and "the model said so" is not a reason to call someone in.

Instead, every figure here decomposes into arithmetic you can say out loud:

    expected absences = base rate x weekday effect x seasonal effect x headcount

Rates are measured from the school's own leave history rather than assumed.
The probability of a shortage is Poisson — the standard model for counting
rare independent events, and a single line to justify.
"""

from __future__ import annotations

import datetime as dt
import math
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

NON_SCHOOL_WEEKDAY = 7
WEEKDAY_NAMES = {
    1: "Monday", 2: "Tuesday", 3: "Wednesday",
    4: "Thursday", 5: "Friday", 6: "Saturday",
}

# Below this many observations a multiplier is noise, so fall back to 1.0
# rather than reporting a spurious trend.
MIN_OBSERVATIONS = 8

# Cover has two tiers, and they fail differently:
#
#   in-department  — a Science teacher covers Science. Good cover.
#   school-wide    — anyone free covers it. The lesson still happens, but
#                    it is supervision rather than teaching.
#
# So running out of in-department slack is a WARNING (quality drops), and
# running out of school-wide slack is CRITICAL (the period has nobody).
CRITICAL_PROBABILITY = 0.30
WARNING_PROBABILITY = 0.25

# An event is flagged when covering it would eat this share of the school's
# entire free capacity for the day.
EVENT_SLACK_SHARE = 0.5


@dataclass
class Rates:
    """Everything measured from history, kept separate so it can be shown."""
    overall_daily_rate: float                      # P(a given teacher is away)
    by_department: dict[str, float] = field(default_factory=dict)
    by_weekday: dict[int, float] = field(default_factory=dict)   # multipliers
    by_month: dict[int, float] = field(default_factory=dict)     # multipliers
    observed_days: int = 0
    observed_absences: int = 0

    def as_dict(self) -> dict:
        return {
            "overall_daily_rate": round(self.overall_daily_rate, 4),
            "by_department": {k: round(v, 4) for k, v in self.by_department.items()},
            "by_weekday": {
                WEEKDAY_NAMES.get(k, str(k)): round(v, 2)
                for k, v in sorted(self.by_weekday.items())
            },
            "by_month": {k: round(v, 2) for k, v in sorted(self.by_month.items())},
            "observed_days": self.observed_days,
            "observed_absences": self.observed_absences,
        }


def school_days(start: dt.date, end: dt.date):
    d = start
    while d <= end:
        if d.isoweekday() != NON_SCHOOL_WEEKDAY:
            yield d
        d += dt.timedelta(days=1)


# ------------------------------------------------------------- measurement
def measure(
    leave_rows: list[dict],
    teachers: list[dict],
    window_start: dt.date,
    window_end: dt.date,
) -> Rates:
    """Derive absence rates from what actually happened."""
    dept_of = {t["id"]: t.get("department_id") for t in teachers}
    dept_size: dict[str, int] = defaultdict(int)
    for t in teachers:
        if t.get("department_id"):
            dept_size[t["department_id"]] += 1

    # Expand each leave request into the individual days it covers.
    absences_by_day: dict[dt.date, set[str]] = defaultdict(set)
    for r in leave_rows:
        if r.get("status") != "approved":
            continue
        f = dt.date.fromisoformat(r["from_date"])
        t = dt.date.fromisoformat(r["to_date"])
        for d in school_days(max(f, window_start), min(t, window_end)):
            absences_by_day[d].add(r["teacher_id"])

    all_days = list(school_days(window_start, window_end))
    n_days = len(all_days)
    n_teachers = len(teachers) or 1
    total_absences = sum(len(v) for v in absences_by_day.values())

    overall = total_absences / (n_days * n_teachers) if n_days else 0.0

    # --- per department -------------------------------------------------
    dept_absences: dict[str, int] = defaultdict(int)
    for _day, who in absences_by_day.items():
        for tid in who:
            d = dept_of.get(tid)
            if d:
                dept_absences[d] += 1

    by_department = {
        dept: (dept_absences.get(dept, 0) / (n_days * size)) if n_days and size else 0.0
        for dept, size in dept_size.items()
    }

    # --- weekday effect, as a multiplier on the overall rate -------------
    per_weekday_absences: dict[int, int] = defaultdict(int)
    per_weekday_days: dict[int, int] = defaultdict(int)
    for d in all_days:
        per_weekday_days[d.isoweekday()] += 1
        per_weekday_absences[d.isoweekday()] += len(absences_by_day.get(d, ()))

    by_weekday: dict[int, float] = {}
    for dow, days in per_weekday_days.items():
        if days == 0 or overall == 0:
            by_weekday[dow] = 1.0
            continue
        rate = per_weekday_absences[dow] / (days * n_teachers)
        by_weekday[dow] = (
            round(rate / overall, 3)
            if per_weekday_absences[dow] >= MIN_OBSERVATIONS else 1.0
        )

    # --- month effect ----------------------------------------------------
    per_month_absences: dict[int, int] = defaultdict(int)
    per_month_days: dict[int, int] = defaultdict(int)
    for d in all_days:
        per_month_days[d.month] += 1
        per_month_absences[d.month] += len(absences_by_day.get(d, ()))

    by_month: dict[int, float] = {}
    for month, days in per_month_days.items():
        if days == 0 or overall == 0:
            by_month[month] = 1.0
            continue
        rate = per_month_absences[month] / (days * n_teachers)
        by_month[month] = (
            round(rate / overall, 3)
            if per_month_absences[month] >= MIN_OBSERVATIONS else 1.0
        )

    return Rates(
        overall_daily_rate=overall,
        by_department=by_department,
        by_weekday=by_weekday,
        by_month=by_month,
        observed_days=n_days,
        observed_absences=total_absences,
    )


# --------------------------------------------------------------- capacity
def cover_capacity(
    timetable: list[dict],
    teachers: list[dict],
    slots_per_day: int,
) -> dict[tuple[str, int], dict]:
    """How many absences each department can absorb on each weekday.

    Straight from the live timetable: a teacher's free periods are the slots
    they are not already teaching, so this is measured, not assumed.
    """
    dept_of = {t["id"]: t.get("department_id") for t in teachers}

    taught: dict[tuple[str, int], int] = defaultdict(int)
    for row in timetable:
        taught[row["teacher_id"], row["day_of_week"]] += 1

    out: dict[tuple[str, int], dict] = {}
    dept_teachers: dict[str, list[str]] = defaultdict(list)
    for t in teachers:
        if t.get("department_id"):
            dept_teachers[t["department_id"]].append(t["id"])

    for dept, ids in dept_teachers.items():
        for dow in range(1, 7):
            loads = [taught.get((tid, dow), 0) for tid in ids]
            free = sum(slots_per_day - x for x in loads)
            busy = sum(loads)
            avg_load = (busy / len(ids)) if ids else 0
            # Absorbing one absence means covering that teacher's periods.
            absorbable = int(free // avg_load) if avg_load > 0 else len(ids)
            out[dept, dow] = {
                "free_periods": free,
                "avg_periods_per_teacher": round(avg_load, 1),
                "absorbable_absences": absorbable,
                "teachers": len(ids),
            }
    return out


# ------------------------------------------------------------- probability
def poisson_tail(lam: float, k: int) -> float:
    """P(X > k) for X ~ Poisson(lam) — the chance more than k are away.

    Poisson because absences are rare, independent-ish counts. One line to
    justify, and no black box.
    """
    if lam <= 0:
        return 0.0
    if k < 0:
        return 1.0
    # Sum the head, subtract from 1. Horizon is small so this is exact enough.
    term = math.exp(-lam)
    cumulative = term
    for i in range(1, k + 1):
        term *= lam / i
        cumulative += term
    return max(0.0, min(1.0, 1.0 - cumulative))


# --------------------------------------------------------------- forecast
def forecast(
    *,
    rates: Rates,
    capacity: dict[tuple[str, int], dict],
    departments: dict[str, str],
    events: list[dict],
    horizon_days: int = 21,
    today: dt.date | None = None,
) -> dict[str, Any]:
    """Day-by-day expected absences and the risk of running short."""
    today = today or dt.date.today()
    events_by_date: dict[dt.date, list[dict]] = defaultdict(list)
    for e in events:
        events_by_date[dt.date.fromisoformat(e["date"])].append(e)

    days_out: list[dict] = []
    cards: list[dict] = []
    # (department, weekday) -> the recurring no-slack finding, collapsed at
    # the end into one card per department rather than one per date.
    structural: dict[tuple[str, int], dict] = {}

    for day in list(school_days(today, today + dt.timedelta(days=horizon_days)))[:horizon_days]:
        dow = day.isoweekday()
        w_mult = rates.by_weekday.get(dow, 1.0)
        m_mult = rates.by_month.get(day.month, 1.0)
        day_events = events_by_date.get(day, [])
        event_load = sum(e.get("teachers_required", 0) or 0 for e in day_events)

        # --- school-wide slack for the day -------------------------------
        day_caps = [c for (d, w), c in capacity.items() if w == dow]
        school_free = sum(c["free_periods"] for c in day_caps)
        loads = [c["avg_periods_per_teacher"] for c in day_caps if c["avg_periods_per_teacher"]]
        avg_load = (sum(loads) / len(loads)) if loads else 1.0
        # Staff pulled onto an event are teaching neither their own periods
        # nor anyone else's, so the event consumes slack first.
        event_periods = int(round(event_load * avg_load))
        usable_free = max(0, school_free - event_periods)
        school_absorbable = int(usable_free // avg_load) if avg_load > 0 else 0

        total_expected = 0.0
        dept_rows: list[dict] = []

        for dept_id, dept_name in departments.items():
            cap = capacity.get((dept_id, dow))
            if not cap or cap["teachers"] == 0:
                continue

            base = rates.by_department.get(dept_id, rates.overall_daily_rate)
            lam = base * w_mult * m_mult * cap["teachers"]
            total_expected += lam

            absorbable = cap["absorbable_absences"]
            p_short = poisson_tail(lam, absorbable)

            dept_rows.append({
                "department_id": dept_id,
                "department": dept_name,
                "expected_absences": round(lam, 2),
                "absorbable": absorbable,
                "free_periods": cap["free_periods"],
                "teachers": cap["teachers"],
                "shortage_probability": round(p_short, 3),
            })

            # A department with no slack at all is worth saying out loud
            # regardless of probability: it is a structural fact, not a risk
            # estimate. Any absence there is covered by another subject.
            #
            # But it is true of EVERY Friday, not this Friday, so it is
            # collected and reported once as a pattern. Repeating it per date
            # is the noise that trains people to ignore the board.
            if absorbable == 0 and lam >= 0.15:
                key = (dept_id, dow)
                structural.setdefault(key, {
                    "department": dept_name,
                    "weekday": WEEKDAY_NAMES.get(dow, ""),
                    "dow": dow,
                    "teachers": cap["teachers"],
                    "free_periods": cap["free_periods"],
                    "expected": round(lam, 2),
                    "first_date": day.isoformat(),
                })
            elif p_short >= WARNING_PROBABILITY:
                cards.append({
                    "severity": "warning",
                    "date": day.isoformat(),
                    "weekday": WEEKDAY_NAMES.get(dow, ""),
                    "department": dept_name,
                    "probability": round(p_short, 3),
                    "expected_absences": round(lam, 2),
                    "absorbable": absorbable,
                    "headline": f"{round(p_short * 100)}% chance {dept_name} runs "
                                f"short on {WEEKDAY_NAMES.get(dow, '')} "
                                f"{day.strftime('%d %b')}",
                    "because": (
                        f"{cap['teachers']} staff with {cap['free_periods']} free "
                        f"periods between them absorb {absorbable} absence(s). "
                        f"{WEEKDAY_NAMES.get(dow, '')} runs {w_mult:.2f}x the "
                        f"average rate, giving {lam:.1f} expected away."
                    ),
                })

        # --- can the school as a whole cope? ------------------------------
        p_school = poisson_tail(total_expected, school_absorbable)
        if p_school >= CRITICAL_PROBABILITY:
            cards.append({
                "severity": "critical",
                "date": day.isoformat(),
                "weekday": WEEKDAY_NAMES.get(dow, ""),
                "department": None,
                "probability": round(p_school, 3),
                "expected_absences": round(total_expected, 2),
                "absorbable": school_absorbable,
                "headline": f"{round(p_school * 100)}% chance of uncovered periods "
                            f"school-wide",
                "because": (
                    f"{total_expected:.1f} teachers expected away against "
                    f"{usable_free} free periods across the school — enough for "
                    f"{school_absorbable}. Nobody would be free for the rest."
                ),
            })

        # --- events consume slack before the day even starts ---------------
        for e in day_events:
            required = e.get("teachers_required", 0) or 0
            if required <= 0:
                continue
            needed = int(round(required * avg_load))
            if needed > school_free * EVENT_SLACK_SHARE:
                # A school with no free periods at all is a real state — no
                # teacher has a department yet, or the timetable is published
                # but nobody is on it — and dividing by it turned the whole
                # forecast endpoint into a 500. Say "all of it" instead.
                share = (round(needed / school_free * 100) if school_free
                         else 100)
                cards.append({
                    "severity": "critical",
                    "date": day.isoformat(),
                    "weekday": WEEKDAY_NAMES.get(dow, ""),
                    "department": None,
                    "event": e["name"],
                    "probability": None,
                    "headline": f"{e['name']} pulls {required} teachers off timetable",
                    "because": (
                        f"Covering their lessons needs about {needed} periods "
                        f"against {school_free} free across the whole school that "
                        f"day — {share}% of all slack. "
                        f"Arrange cover in advance, not on the day."
                    ),
                })

        days_out.append({
            "date": day.isoformat(),
            "weekday": WEEKDAY_NAMES.get(dow, ""),
            "expected_absences": round(total_expected, 2),
            "weekday_multiplier": round(w_mult, 2),
            "seasonal_multiplier": round(m_mult, 2),
            "event_teachers": event_load,
            "events": [e["name"] for e in day_events],
            "departments": sorted(
                dept_rows, key=lambda r: -r["shortage_probability"])[:3],
        })

    # --- collapse the recurring findings, one card per department ---------
    by_dept: dict[str, list[dict]] = defaultdict(list)
    for (dept_id, _dow), row in structural.items():
        by_dept[dept_id].append(row)

    for _dept_id, rows in by_dept.items():
        rows.sort(key=lambda r: r["dow"])
        name = rows[0]["department"]
        days_list = [r["weekday"] for r in rows]
        pretty = (
            days_list[0] if len(days_list) == 1
            else " and ".join([", ".join(days_list[:-1]), days_list[-1]])
        )
        worst = min(rows, key=lambda r: r["free_periods"])
        cards.append({
            "severity": "warning",
            "date": min(r["first_date"] for r in rows),
            "weekday": None,
            "department": name,
            "recurring": True,
            "weekdays": days_list,
            "probability": None,
            "expected_absences": worst["expected"],
            "absorbable": 0,
            "headline": f"{name} has no spare capacity on {pretty}",
            "because": (
                f"{worst['teachers']} staff share only {worst['free_periods']} "
                f"free periods on the tightest of those days, so the department "
                f"can absorb no absences at all. Any absence is covered by a "
                f"teacher from another subject. This repeats every week — it is "
                f"a staffing shape, not a one-off."
            ),
        })

    order = {"critical": 0, "warning": 1}
    cards.sort(key=lambda c: (order.get(c["severity"], 2), c["date"]))

    return {
        "generated_for": today.isoformat(),
        "horizon_days": horizon_days,
        "rates": rates.as_dict(),
        "days": days_out,
        "cards": cards,
        "critical_count": sum(1 for c in cards if c["severity"] == "critical"),
        "warning_count": sum(1 for c in cards if c["severity"] == "warning"),
        "method": (
            "expected absences = department base rate x weekday effect x "
            "seasonal effect x headcount. Shortage probability is Poisson "
            "against the free periods the live timetable actually leaves."
        ),
    }
