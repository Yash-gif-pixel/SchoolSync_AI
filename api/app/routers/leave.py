"""Leave requests, HOD approval, and the substitution pipeline it triggers.

Approval is decentralised: a head of department reviews their own department's
requests, which keeps routine decisions off the admin's desk. The moment a
request is approved the substitution matcher runs and writes suggestions, so
the Action Board fills in without anyone asking it to.
"""

from __future__ import annotations

import datetime as dt
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.leave_rules import describe_clash, overlapping_leave
from ..services.substitution import dates_in_range, find_substitutes

router = APIRouter(prefix="/leave", tags=["leave"])

PAGE_SIZE = 1000


class LeaveCreate(BaseModel):
    from_date: dt.date
    to_date: dt.date
    reason: str | None = Field(default=None, max_length=500)
    teacher_id: str | None = None  # admin may file on someone's behalf

    @field_validator("to_date")
    @classmethod
    def _order(cls, v: dt.date, info):
        start = info.data.get("from_date")
        if start and v < start:
            raise ValueError("to_date cannot be before from_date")
        return v


class LeaveReview(BaseModel):
    approve: bool
    note: str | None = None


# --------------------------------------------------------------- helpers
def _active_timetable_rows() -> list[dict]:
    """The live timetable, flattened for the matcher. Paged: PostgREST caps a
    select at 1000 rows and a full week is 1440."""
    ver = (admin().table("timetable_versions").select("id")
           .eq("is_active", True).maybe_single().execute())
    if not ver or not ver.data:
        return []

    rows: list[dict] = []
    start = 0
    while True:
        page = (admin().table("timetable_entries")
                .select("id, slot_id, "
                        "teaching_assignments(teacher_id, classes(name), "
                        "  subjects(name)), "
                        "time_slots(day_of_week, slot_index)")
                .eq("version_id", ver.data["id"])
                .range(start, start + PAGE_SIZE - 1)
                .execute().data)
        rows.extend(page)
        if len(page) < PAGE_SIZE:
            break
        start += PAGE_SIZE

    out = []
    for r in rows:
        a = r.get("teaching_assignments") or {}
        s = r.get("time_slots") or {}
        out.append({
            "entry_id": r["id"],
            "slot_id": r["slot_id"],
            "teacher_id": a.get("teacher_id"),
            "class_name": (a.get("classes") or {}).get("name", "?"),
            "subject_name": (a.get("subjects") or {}).get("name", "?"),
            "day_of_week": s.get("day_of_week"),
            "slot_index": s.get("slot_index"),
        })
    return out


def _absences_by_date(start: dt.date, end: dt.date,
                      exclude_id: str | None = None) -> dict[dt.date, set[str]]:
    """Who else is already approved to be away on each day in the window."""
    rows = (admin().table("leave_requests")
            .select("id, teacher_id, from_date, to_date")
            .eq("status", "approved")
            .lte("from_date", end.isoformat())
            .gte("to_date", start.isoformat())
            .execute().data)

    out: dict[dt.date, set[str]] = defaultdict(set)
    for r in rows:
        if exclude_id and r["id"] == exclude_id:
            continue
        f = dt.date.fromisoformat(r["from_date"])
        t = dt.date.fromisoformat(r["to_date"])
        for d in dates_in_range(max(f, start), min(t, end)):
            out[d].add(r["teacher_id"])
    return out


def _event_commitments(
    start: dt.date, end: dt.date
) -> dict[dt.date, dict[str, str]]:
    """Who is tied up by a school event on each day in the window.

    Annual Day does not appear on anyone's timetable, so without this the
    matcher happily offers up eleven teachers who are all in the main hall.
    """
    events = (admin().table("calendar_events")
              .select("id, name, date, ends_on")
              .lte("date", end.isoformat())
              .execute().data or [])

    running = []
    for e in events:
        e_start = dt.date.fromisoformat(e["date"])
        e_end = dt.date.fromisoformat(e.get("ends_on") or e["date"])
        if e_end >= start:
            running.append((e, e_start, e_end))

    out: dict[dt.date, dict[str, str]] = defaultdict(dict)
    if not running:
        return out

    links = (admin().table("event_teachers")
             .select("event_id, teacher_id")
             .in_("event_id", [e["id"] for e, _, _ in running])
             .execute().data or [])
    by_event: dict[str, list[str]] = defaultdict(list)
    for link in links:
        by_event[link["event_id"]].append(link["teacher_id"])

    for e, e_start, e_end in running:
        for d in dates_in_range(max(e_start, start), min(e_end, end)):
            for tid in by_event.get(e["id"], []):
                out[d][tid] = e["name"]
    return out


def _run_matcher(leave: dict) -> list[dict]:
    """Generate and persist substitution suggestions for an approved leave."""
    start = dt.date.fromisoformat(leave["from_date"])
    end = dt.date.fromisoformat(leave["to_date"])

    timetable = _active_timetable_rows()
    if not timetable:
        return []

    teachers = (admin().table("profiles")
                .select("id, full_name, department_id")
                .eq("role", "teacher").execute().data)

    suggestions = find_substitutes(
        absent_teacher_id=leave["teacher_id"],
        from_date=start,
        to_date=end,
        timetable=timetable,
        teachers=teachers,
        other_absences=_absences_by_date(start, end, exclude_id=leave["id"]),
        event_commitments=_event_commitments(start, end),
    )

    # Replace any earlier run for this leave so re-approval is idempotent.
    admin().table("substitutions").delete().eq("leave_request_id", leave["id"]).execute()

    rows = [{
        "leave_request_id": leave["id"],
        "timetable_entry_id": s["timetable_entry_id"],
        "date": s["date"],
        "substitute_teacher_id": s["substitute_teacher_id"],
        "status": "suggested",
        "rank": s["rank"],
        "rationale": s["rationale"],
    } for s in suggestions if not s["no_cover"]]

    if rows:
        for i in range(0, len(rows), 500):
            admin().table("substitutions").insert(rows[i:i + 500]).execute()
    return suggestions


# ---------------------------------------------------------------- routes
@router.post("", status_code=status.HTTP_201_CREATED)
def create_leave(
    payload: LeaveCreate,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    teacher_id = payload.teacher_id or user.id
    if teacher_id != user.id and not user.is_admin:
        raise HTTPException(403, "You can only file leave for yourself.")

    # Double-booked leave would have the substitution matcher arranging cover
    # for the same periods twice, so a clash is refused rather than merged.
    clashes = overlapping_leave(
        admin(), teacher_id, payload.from_date, payload.to_date
    )
    if clashes:
        subject = "You have" if teacher_id == user.id else "This teacher has"
        raise HTTPException(409, describe_clash(clashes[0], subject=subject))

    row = admin().table("leave_requests").insert({
        "teacher_id": teacher_id,
        "from_date": payload.from_date.isoformat(),
        "to_date": payload.to_date.isoformat(),
        "reason": payload.reason,
        "status": "pending_incharge",
    }).execute().data[0]

    days = len(dates_in_range(payload.from_date, payload.to_date))
    return {**row, "school_days": days}


@router.get("/mine")
def my_leave(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    return (admin().table("leave_requests")
            .select("*, reviewer:reviewed_by(full_name)")
            .eq("teacher_id", user.id)
            .order("from_date", desc=True).limit(50).execute().data)


@router.get("/pending")
def pending_for_me(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    """Who reviews what:

      admin           everything
      vice principal  the heads of department
      HOD             their own department, heads excepted
      teacher         nothing

    The exception in the HOD line matters. Without it a request from one head
    would appear on every other head's desk in the same department, and a head
    who is the only approver there would see their own.
    """
    if not (user.is_approver or user.is_admin or user.is_vice_principal):
        return []

    q = (admin().table("leave_requests")
         .select("*, teacher:teacher_id(id, full_name, department_id, "
                 "  is_approver, departments(name))")
         .eq("status", "pending_incharge")
         .order("created_at", desc=True).limit(100))
    rows = q.execute().data

    if user.is_admin:
        return rows

    if user.is_vice_principal:
        return [
            r for r in rows
            if (r.get("teacher") or {}).get("is_approver")
            and (r.get("teacher") or {}).get("id") != user.id
        ]

    return [
        r for r in rows
        if (r.get("teacher") or {}).get("department_id") == user.department_id
        and not (r.get("teacher") or {}).get("is_approver")
    ]


@router.post("/{leave_id}/review")
def review_leave(
    leave_id: str,
    payload: LeaveReview,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    res = (admin().table("leave_requests")
           .select("*, teacher:teacher_id(id, full_name, department_id, "
                   "  is_approver)")
           .eq("id", leave_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Leave request not found")
    leave = res.data

    if leave["status"] != "pending_incharge":
        raise HTTPException(409, f"This request is already {leave['status']}.")

    teacher = leave.get("teacher") or {}
    requester_is_hod = bool(teacher.get("is_approver"))

    # A head of department's own request goes up, not sideways. Their peers in
    # the department do not outrank them, so it is the Vice Principal's call.
    if requester_is_hod:
        may_review = user.reviews_hod_leave
        refusal = ("A head of department's leave is reviewed by the Vice "
                   "Principal.")
    else:
        may_review = user.is_admin or user.is_vice_principal or (
            user.is_approver
            and teacher.get("department_id") == user.department_id
        )
        refusal = ("Only an admin, the Vice Principal, or the head of this "
                   "teacher's department can review it.")

    if not may_review:
        raise HTTPException(403, refusal)

    if teacher.get("id") == user.id and not user.is_admin:
        raise HTTPException(403, "You cannot approve your own leave.")

    # Creation already refuses a clash, but a pair of requests filed before
    # that check existed — or approved concurrently — must not both go live.
    # This is the guard that actually protects the substitution matcher.
    if payload.approve:
        clashes = [
            c for c in overlapping_leave(
                admin(),
                leave["teacher_id"],
                dt.date.fromisoformat(leave["from_date"]),
                dt.date.fromisoformat(leave["to_date"]),
                exclude_id=leave_id,
            )
            if c["status"] == "approved"
        ]
        if clashes:
            raise HTTPException(409, describe_clash(
                clashes[0],
                subject=f"{teacher.get('full_name', 'This teacher')} has",
            ))

    new_status = "approved" if payload.approve else "rejected"
    updated = admin().table("leave_requests").update({
        "status": new_status,
        "reviewed_by": user.id,
        "reviewed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }).eq("id", leave_id).execute().data[0]

    suggestions: list[dict] = []
    if payload.approve:
        suggestions = _run_matcher(updated)

    covered = len({s["timetable_entry_id"] for s in suggestions if not s["no_cover"]})
    uncovered = [s for s in suggestions if s["no_cover"]]

    return {
        "leave": updated,
        "status": new_status,
        "periods_affected": len({s["timetable_entry_id"] for s in suggestions}),
        "periods_with_cover": covered,
        "periods_without_cover": len(uncovered),
        "suggestions": suggestions,
    }


@router.post("/{leave_id}/rematch")
def rematch(leave_id: str, user: CurrentUser = Depends(require_admin)) -> dict:
    """Re-run the matcher, e.g. after the timetable changed."""
    res = (admin().table("leave_requests").select("*")
           .eq("id", leave_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Leave request not found")
    if res.data["status"] != "approved":
        raise HTTPException(409, "Only approved leave has periods to cover.")
    suggestions = _run_matcher(res.data)
    return {"suggestions": suggestions, "count": len(suggestions)}
