"""School events and the staff they tie up.

Annual Day does not appear on anybody's timetable, but it removes twelve
teachers from circulation for two days, and that is exactly the kind of
shortage the Action Board exists to see coming. Naming the specific teachers
rather than a headcount is what lets the rest of the system reason about it:
a teacher rehearsing on Friday is not a candidate to cover somebody's leave.

`calendar_events.teachers_required` is written here from the length of the
roster, so the forecast keeps reading the one column it always read.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin

router = APIRouter(prefix="/events", tags=["events"])


class EventCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    starts_on: dt.date
    ends_on: dt.date | None = None
    event_type: str | None = Field(default=None, max_length=60)
    notes: str | None = Field(default=None, max_length=500)
    teacher_ids: list[str] = Field(default_factory=list)

    @field_validator("ends_on")
    @classmethod
    def _order(cls, v: dt.date | None, info) -> dt.date | None:
        start = info.data.get("starts_on")
        if v and start and v < start:
            raise ValueError("The event cannot end before it starts.")
        return v


def _hydrate(events: list[dict]) -> list[dict]:
    """Attach each event's teacher roster in one round trip."""
    if not events:
        return []

    ids = [e["id"] for e in events]
    links = (
        admin().table("event_teachers")
        .select("event_id, teacher_id").in_("event_id", ids)
        .execute().data or []
    )
    teacher_ids = {link["teacher_id"] for link in links}

    names: dict[str, str] = {}
    if teacher_ids:
        rows = (
            admin().table("profiles").select("id, full_name, department_id")
            .in_("id", list(teacher_ids)).execute().data or []
        )
        names = {r["id"]: r["full_name"] for r in rows}

    by_event: dict[str, list[dict]] = {}
    for link in links:
        by_event.setdefault(link["event_id"], []).append({
            "teacher_id": link["teacher_id"],
            "full_name": names.get(link["teacher_id"], "Unknown"),
        })

    for e in events:
        roster = sorted(
            by_event.get(e["id"], []), key=lambda t: t["full_name"])
        e["teachers"] = roster
        # A single-day event stores null; the client should not have to know.
        e["ends_on"] = e.get("ends_on") or e["date"]
        e["days"] = (
            dt.date.fromisoformat(e["ends_on"])
            - dt.date.fromisoformat(e["date"])
        ).days + 1
    return events


@router.get("")
def list_events(
    upcoming_only: bool = False,
    user: CurrentUser = Depends(get_current_user),
) -> list[dict]:
    q = admin().table("calendar_events").select("*")
    if upcoming_only:
        # An event still running today is still upcoming, so compare against
        # the end date where there is one.
        q = q.gte("date", dt.date.today().isoformat())
    events = q.order("date").execute().data or []
    return _hydrate(events)


@router.post("", status_code=status.HTTP_201_CREATED)
def create_event(
    body: EventCreate, user: CurrentUser = Depends(require_admin)
) -> dict:
    sb = admin()

    roster: list[str] = []
    if body.teacher_ids:
        found = (
            sb.table("profiles").select("id")
            .in_("id", body.teacher_ids).execute().data or []
        )
        roster = [r["id"] for r in found]
        if set(body.teacher_ids) - set(roster):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "One of the selected teachers no longer exists.",
            )

    res = sb.table("calendar_events").insert({
        "name": body.name,
        "date": body.starts_on.isoformat(),
        "ends_on": (body.ends_on or body.starts_on).isoformat(),
        "event_type": body.event_type,
        "notes": body.notes,
        # Derived, never typed: the forecast's headcount is now just the
        # length of a roster somebody actually chose.
        "teachers_required": len(roster),
    }).execute()
    if not res.data:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Could not create the event")

    event = res.data[0]
    if roster:
        sb.table("event_teachers").insert(
            [{"event_id": event["id"], "teacher_id": t} for t in roster]
        ).execute()
    return _hydrate([event])[0]


@router.delete("/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_event(
    event_id: str, user: CurrentUser = Depends(require_admin)
) -> None:
    admin().table("calendar_events").delete().eq("id", event_id).execute()


@router.get("/busy")
def busy_teachers(
    on: dt.date | None = None,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """Teachers tied up by an event on a given day.

    The substitution matcher and the leave screen both want this: somebody
    running Sports Day is not available to cover a colleague's class.
    """
    day = on or dt.date.today()
    events = (
        admin().table("calendar_events").select("*")
        .lte("date", day.isoformat()).execute().data or []
    )
    running = [
        e for e in events
        if dt.date.fromisoformat(e.get("ends_on") or e["date"]) >= day
    ]
    hydrated = _hydrate(running)

    busy: dict[str, dict] = {}
    for e in hydrated:
        for t in e["teachers"]:
            busy[t["teacher_id"]] = {**t, "event": e["name"]}

    return {
        "date": day.isoformat(),
        "events": [{"id": e["id"], "name": e["name"]} for e in hydrated],
        "teachers": sorted(busy.values(), key=lambda t: t["full_name"]),
    }
