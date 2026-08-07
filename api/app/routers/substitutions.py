"""The Action Board: cover that needs an administrator's decision.

Proactive by design — the board is a queue of things needing action, not
something the admin has to go looking for. Suggestions arrive here the moment
an HOD approves leave.
"""

from __future__ import annotations

import datetime as dt
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin

router = APIRouter(prefix="/substitutions", tags=["substitutions"])

SELECT = (
    "id, date, status, rank, rationale, "
    "substitute:substitute_teacher_id(id, full_name, departments(name)), "
    "leave_requests(id, from_date, to_date, reason, "
    "  teacher:teacher_id(id, full_name, departments(name))), "
    "timetable_entries(id, "
    "  teaching_assignments(classes(name), subjects(name)), "
    "  time_slots(day_of_week, slot_index, start_time, end_time), "
    "  rooms(name))"
)


class ConfirmPayload(BaseModel):
    substitute_teacher_id: str | None = None  # override the suggestion


@router.get("/board")
def action_board(
    upcoming_only: bool = True,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """Suggested cover, grouped by the absence that caused it."""
    q = admin().table("substitutions").select(SELECT).order("date")
    if upcoming_only:
        q = q.gte("date", dt.date.today().isoformat())
    rows = q.limit(500).execute().data

    groups: dict[str, dict] = {}
    for r in rows:
        leave = r.get("leave_requests") or {}
        lid = leave.get("id") or "unknown"
        entry = r.get("timetable_entries") or {}
        a = entry.get("teaching_assignments") or {}
        slot = entry.get("time_slots") or {}

        g = groups.setdefault(lid, {
            "leave_id": lid,
            "absent_teacher": (leave.get("teacher") or {}).get("full_name", "?"),
            "absent_department": ((leave.get("teacher") or {})
                                  .get("departments") or {}).get("name"),
            "from_date": leave.get("from_date"),
            "to_date": leave.get("to_date"),
            "reason": leave.get("reason"),
            "periods": {},
        })

        key = f"{r['date']}#{entry.get('id')}"
        period = g["periods"].setdefault(key, {
            "date": r["date"],
            "timetable_entry_id": entry.get("id"),
            "class_name": (a.get("classes") or {}).get("name", "?"),
            "subject_name": (a.get("subjects") or {}).get("name", "?"),
            "slot_index": slot.get("slot_index"),
            "day_of_week": slot.get("day_of_week"),
            "start_time": slot.get("start_time"),
            "room": (entry.get("rooms") or {}).get("name"),
            "status": "suggested",
            "candidates": [],
        })

        sub = r.get("substitute") or {}
        period["candidates"].append({
            "substitution_id": r["id"],
            "teacher_id": sub.get("id"),
            "teacher_name": sub.get("full_name", "?"),
            "department": (sub.get("departments") or {}).get("name"),
            "rank": r.get("rank"),
            "rationale": r.get("rationale"),
            "status": r.get("status"),
        })
        if r.get("status") == "confirmed":
            period["status"] = "confirmed"
            period["confirmed_teacher"] = sub.get("full_name")

    out = []
    for g in groups.values():
        periods = sorted(
            g["periods"].values(),
            key=lambda p: (p["date"], p["slot_index"] or 0),
        )
        for p in periods:
            p["candidates"].sort(key=lambda c: c["rank"] or 99)
        g["periods"] = periods
        g["period_count"] = len(periods)
        g["unconfirmed"] = sum(1 for p in periods if p["status"] != "confirmed")
        out.append(g)

    out.sort(key=lambda g: (g["unconfirmed"] == 0, g["from_date"] or ""))

    return {
        "groups": out,
        "total_periods": sum(g["period_count"] for g in out),
        "needs_action": sum(g["unconfirmed"] for g in out),
    }


@router.get("/mine")
def my_cover(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    """Cover a teacher has been confirmed for."""
    return (admin().table("substitutions").select(SELECT)
            .eq("substitute_teacher_id", user.id)
            .eq("status", "confirmed")
            .gte("date", dt.date.today().isoformat())
            .order("date").limit(100).execute().data)


@router.post("/{substitution_id}/confirm")
def confirm(
    substitution_id: str,
    payload: ConfirmPayload | None = None,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    res = (admin().table("substitutions")
           .select("*, timetable_entries(id)")
           .eq("id", substitution_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Suggestion not found")
    row = res.data

    entry_id = (row.get("timetable_entries") or {}).get("id")
    chosen = (payload.substitute_teacher_id if payload else None) \
        or row["substitute_teacher_id"]
    if not chosen:
        raise HTTPException(422, "No substitute teacher to confirm.")

    # Confirming one candidate declines the rest for that period.
    siblings = (admin().table("substitutions").select("id")
                .eq("timetable_entry_id", entry_id)
                .eq("date", row["date"]).execute().data)
    for s in siblings:
        if s["id"] != substitution_id:
            admin().table("substitutions").update(
                {"status": "declined"}).eq("id", s["id"]).execute()

    updated = admin().table("substitutions").update({
        "status": "confirmed",
        "substitute_teacher_id": chosen,
    }).eq("id", substitution_id).execute().data[0]

    who = (admin().table("profiles").select("full_name")
           .eq("id", chosen).maybe_single().execute())
    name = who.data["full_name"] if who and who.data else "The substitute"

    return {
        "substitution": updated,
        "message": f"{name} confirmed to cover this period.",
        "declined_alternatives": max(0, len(siblings) - 1),
    }


@router.post("/{substitution_id}/decline", status_code=status.HTTP_200_OK)
def decline(substitution_id: str, user: CurrentUser = Depends(require_admin)) -> dict:
    res = (admin().table("substitutions").update({"status": "declined"})
           .eq("id", substitution_id).execute())
    if not res.data:
        raise HTTPException(404, "Suggestion not found")
    return res.data[0]


@router.get("/summary")
def summary(user: CurrentUser = Depends(get_current_user)) -> dict:
    """Small counts for the dashboard card."""
    today = dt.date.today().isoformat()
    rows = (admin().table("substitutions")
            .select("id, status, date, leave_request_id")
            .gte("date", today).limit(1000).execute().data)

    by_entry: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_entry[r["leave_request_id"]].append(r)

    pending = (admin().table("leave_requests").select("id", count="exact")
               .eq("status", "pending_incharge").limit(1).execute().count or 0)

    confirmed = sum(1 for r in rows if r["status"] == "confirmed")
    return {
        "pending_leave_requests": pending,
        "absences_with_cover_needed": len(by_entry),
        "confirmed_cover": confirmed,
        "suggestions_outstanding": sum(
            1 for r in rows if r["status"] == "suggested"),
    }
