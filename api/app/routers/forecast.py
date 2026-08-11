"""Predictive staffing endpoint."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query

from ..auth import CurrentUser, get_current_user
from ..db import admin
from ..services.forecast import cover_capacity, forecast, measure

router = APIRouter(prefix="/forecast", tags=["forecast"])

PAGE_SIZE = 1000
HISTORY_DAYS = 90


def _timetable_loads() -> tuple[list[dict], int]:
    """Who teaches how much, per weekday, from the live timetable."""
    slots = [s for s in admin().table("time_slots").select("*").execute().data
             if not s["is_break"]]
    per_day = len({s["slot_index"] for s in slots}) or 6

    ver = (admin().table("timetable_versions").select("id")
           .eq("is_active", True).maybe_single().execute())
    if not ver or not ver.data:
        return [], per_day

    rows: list[dict] = []
    start = 0
    while True:
        page = (admin().table("timetable_entries")
                .select("teaching_assignments(teacher_id), "
                        "time_slots(day_of_week)")
                .eq("version_id", ver.data["id"])
                .range(start, start + PAGE_SIZE - 1)
                .execute().data)
        rows.extend(page)
        if len(page) < PAGE_SIZE:
            break
        start += PAGE_SIZE

    return [
        {
            "teacher_id": (r.get("teaching_assignments") or {}).get("teacher_id"),
            "day_of_week": (r.get("time_slots") or {}).get("day_of_week"),
        }
        for r in rows
        if (r.get("teaching_assignments") or {}).get("teacher_id")
    ], per_day


@router.get("/staffing")
def staffing(
    # 21 days by default so a fortnight's routine risk and the next big
    # calendar event both land inside the window.
    horizon_days: int = Query(default=21, ge=1, le=60),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    today = dt.date.today()
    window_start = today - dt.timedelta(days=HISTORY_DAYS)

    teachers = (admin().table("profiles")
                .select("id, full_name, department_id")
                .eq("role", "teacher").execute().data)

    departments = {
        d["id"]: d["name"]
        for d in admin().table("departments").select("id, name").execute().data
    }

    leave_rows = (admin().table("leave_requests")
                  .select("teacher_id, from_date, to_date, status")
                  .gte("from_date", window_start.isoformat())
                  .limit(2000).execute().data)

    horizon_end = today + dt.timedelta(days=horizon_days)
    raw_events = (admin().table("calendar_events")
                  .select("name, date, ends_on, event_type, teachers_required")
                  .lte("date", horizon_end.isoformat())
                  .execute().data)

    # A three-day Annual Day costs twelve teachers on all three days, not just
    # the first. The forecast groups by a single `date`, so a multi-day event
    # is expanded into one entry per day it actually runs.
    events = []
    for e in raw_events:
        start = dt.date.fromisoformat(e["date"])
        end = dt.date.fromisoformat(e.get("ends_on") or e["date"])
        day = max(start, today)
        while day <= min(end, horizon_end):
            events.append({**e, "date": day.isoformat()})
            day += dt.timedelta(days=1)

    timetable, slots_per_day = _timetable_loads()

    rates = measure(leave_rows, teachers, window_start, today)
    capacity = cover_capacity(timetable, teachers, slots_per_day)

    result = forecast(
        rates=rates,
        capacity=capacity,
        departments=departments,
        events=events,
        horizon_days=horizon_days,
        today=today,
    )
    result["has_timetable"] = bool(timetable)
    if not timetable:
        result["note"] = (
            "No timetable is published, so free-period capacity is unknown. "
            "Generate a timetable for a usable forecast."
        )
    return result
