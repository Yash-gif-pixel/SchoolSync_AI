"""Attendance, built around the arithmetic of a real classroom.

In a class of 45, roughly 42 are present. Reading 45 names to find 3 absentees
is the wrong shape of work. So the roster arrives with everyone already marked
present and the teacher taps only the empty desks — which is why this endpoint
returns a roster rather than an empty form, and why marking is a single bulk
write rather than one request per pupil.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from ..auth import CurrentUser, get_current_user
from ..db import admin

router = APIRouter(prefix="/attendance", tags=["attendance"])

PAGE_SIZE = 1000


class Mark(BaseModel):
    student_id: str
    status: str  # present | absent | late


class MarkPayload(BaseModel):
    class_id: str
    slot_id: str
    date: dt.date
    marks: list[Mark]


def _teaches(user: CurrentUser, class_id: str) -> bool:
    if user.is_admin:
        return True
    rows = (admin().table("teaching_assignments").select("id")
            .eq("teacher_id", user.id).eq("class_id", class_id)
            .limit(1).execute().data)
    return bool(rows)


def _covering(user: CurrentUser, class_id: str, slot_id: str,
              day: dt.date) -> bool:
    """Is this teacher standing in for somebody, here, now?

    Scoped to the exact period on purpose. Asking only "do they cover this
    class" would hand a teacher who covered 8D once in September the power to
    mark 8D's register for the rest of the year.
    """
    subs = (admin().table("substitutions")
            .select("timetable_entries!inner(slot_id, "
                    "  teaching_assignments!inner(class_id))")
            .eq("substitute_teacher_id", user.id)
            .eq("status", "confirmed")
            .eq("date", day.isoformat())
            .eq("timetable_entries.slot_id", slot_id)
            .eq("timetable_entries.teaching_assignments.class_id", class_id)
            .limit(1).execute().data)
    return bool(subs)


def _may_mark(user: CurrentUser, class_id: str, slot_id: str,
              day: dt.date) -> bool:
    """Their own class, or one they are confirmed to be covering today.

    Without the second half a substitute walks into the room and the app
    refuses them the register — the cover exists on the Action Board and
    nowhere a teacher can act on it.
    """
    return _teaches(user, class_id) or _covering(user, class_id, slot_id, day)


@router.get("/today")
def my_periods_today(
    date: dt.date | None = Query(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """The signed-in teacher's periods for a day, with attendance state."""
    day = date or dt.date.today()
    dow = day.isoweekday()
    if dow == 7:
        return {"date": day.isoformat(), "is_school_day": False, "periods": []}

    ver = (admin().table("timetable_versions").select("id")
           .eq("is_active", True).maybe_single().execute())
    if not ver or not ver.data:
        return {"date": day.isoformat(), "is_school_day": True, "periods": [],
                "note": "No timetable has been published yet."}

    rows = (admin().table("timetable_entries")
            .select("id, slot_id, "
                    "teaching_assignments!inner(teacher_id, "
                    "  classes(id, name), subjects(name)), "
                    "time_slots!inner(day_of_week, slot_index, start_time, end_time), "
                    "rooms(name)")
            .eq("version_id", ver.data["id"])
            .eq("teaching_assignments.teacher_id", user.id)
            .eq("time_slots.day_of_week", dow)
            .execute().data)

    periods = []
    for r in rows:
        a = r.get("teaching_assignments") or {}
        s = r.get("time_slots") or {}
        cls = a.get("classes") or {}

        done = (admin().table("attendance").select("id", count="exact")
                .eq("class_id", cls.get("id")).eq("slot_id", r["slot_id"])
                .eq("date", day.isoformat()).limit(1).execute().count or 0)

        periods.append({
            "timetable_entry_id": r["id"],
            "slot_id": r["slot_id"],
            "slot_index": s.get("slot_index"),
            "start_time": s.get("start_time"),
            "end_time": s.get("end_time"),
            "class_id": cls.get("id"),
            "class_name": cls.get("name"),
            "subject_name": (a.get("subjects") or {}).get("name"),
            "room": (r.get("rooms") or {}).get("name"),
            "marked": done > 0,
            "marked_count": done,
            "covering_for": None,
        })

    # Cover this teacher is confirmed for today belongs on the same list.
    # Without it the register is reachable but unfindable.
    covers = (admin().table("substitutions")
              .select("timetable_entries!inner(id, slot_id, "
                      "  teaching_assignments!inner(teacher_id, "
                      "    classes(id, name), subjects(name)), "
                      "  time_slots!inner(slot_index, start_time, end_time), "
                      "  rooms(name))")
              .eq("substitute_teacher_id", user.id)
              .eq("status", "confirmed")
              .eq("date", day.isoformat())
              .execute().data or [])

    owners: dict[str, str] = {}
    for c in covers:
        e = c.get("timetable_entries") or {}
        a = e.get("teaching_assignments") or {}
        tid = a.get("teacher_id")
        if tid and tid not in owners:
            who = (admin().table("profiles").select("full_name")
                   .eq("id", tid).maybe_single().execute())
            owners[tid] = (who.data["full_name"] if who and who.data
                           else "a colleague")

        s_ = e.get("time_slots") or {}
        cls = a.get("classes") or {}
        done = (admin().table("attendance").select("id", count="exact")
                .eq("class_id", cls.get("id")).eq("slot_id", e.get("slot_id"))
                .eq("date", day.isoformat()).limit(1).execute().count or 0)

        periods.append({
            "timetable_entry_id": e.get("id"),
            "slot_id": e.get("slot_id"),
            "slot_index": s_.get("slot_index"),
            "start_time": s_.get("start_time"),
            "end_time": s_.get("end_time"),
            "class_id": cls.get("id"),
            "class_name": cls.get("name"),
            "subject_name": (a.get("subjects") or {}).get("name"),
            "room": (e.get("rooms") or {}).get("name"),
            "marked": done > 0,
            "marked_count": done,
            "covering_for": owners.get(tid),
        })

    periods.sort(key=lambda p: p["slot_index"] or 0)
    return {
        "date": day.isoformat(),
        "is_school_day": True,
        "periods": periods,
        "outstanding": sum(1 for p in periods if not p["marked"]),
    }


@router.get("/roster")
def roster(
    class_id: str,
    slot_id: str,
    date: dt.date | None = Query(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """The class list, pre-marked present.

    Any existing marks for this period override the default, so reopening a
    period shows what was actually recorded rather than resetting it.
    """
    day = date or dt.date.today()
    if not _may_mark(user, class_id, slot_id, day):
        raise HTTPException(
            403, "You do not teach this class, and are not covering it today.")

    students: list[dict] = []
    start = 0
    while True:
        page = (admin().table("students")
                .select("id, full_name, roll_no, photo_url")
                .eq("class_id", class_id)
                .order("roll_no")
                .range(start, start + PAGE_SIZE - 1)
                .execute().data)
        students.extend(page)
        if len(page) < PAGE_SIZE:
            break
        start += PAGE_SIZE

    existing = {
        r["student_id"]: r["status"]
        for r in (admin().table("attendance")
                  .select("student_id, status")
                  .eq("class_id", class_id).eq("slot_id", slot_id)
                  .eq("date", day.isoformat()).execute().data)
    }

    cls = (admin().table("classes").select("name")
           .eq("id", class_id).maybe_single().execute())

    return {
        "class_id": class_id,
        "class_name": cls.data["name"] if cls and cls.data else "?",
        "slot_id": slot_id,
        "date": day.isoformat(),
        "already_marked": bool(existing),
        "students": [
            {**s, "status": existing.get(s["id"], "present")}
            for s in students
        ],
    }


@router.post("/mark")
def mark(
    payload: MarkPayload,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """One write for the whole class."""
    if not _may_mark(user, payload.class_id, payload.slot_id, payload.date):
        raise HTTPException(
            403, "You do not teach this class, and are not covering it today.")

    valid = {"present", "absent", "late"}
    bad = [m.status for m in payload.marks if m.status not in valid]
    if bad:
        raise HTTPException(422, f"Unknown status: {', '.join(set(bad))}")

    rows = [{
        "student_id": m.student_id,
        "class_id": payload.class_id,
        "slot_id": payload.slot_id,
        "date": payload.date.isoformat(),
        "status": m.status,
        "marked_by": user.id,
    } for m in payload.marks]

    if not rows:
        raise HTTPException(422, "No marks supplied.")

    # Re-marking a period should correct it, not fail on the unique index.
    for i in range(0, len(rows), 500):
        (admin().table("attendance")
         .upsert(rows[i:i + 500], on_conflict="student_id,date,slot_id")
         .execute())

    absent = sum(1 for m in payload.marks if m.status == "absent")
    late = sum(1 for m in payload.marks if m.status == "late")
    return {
        "marked": len(rows),
        "present": len(rows) - absent - late,
        "absent": absent,
        "late": late,
        "message": f"{len(rows) - absent - late} present, {absent} absent"
                   + (f", {late} late" if late else "") + ".",
    }


@router.get("/summary")
def summary(
    date: dt.date | None = Query(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """School-wide attendance for a day, for the admin dashboard."""
    day = date or dt.date.today()
    rows = (admin().table("attendance").select("status", count="exact")
            .eq("date", day.isoformat()).limit(1).execute())
    total = rows.count or 0

    absent = (admin().table("attendance").select("id", count="exact")
              .eq("date", day.isoformat()).eq("status", "absent")
              .limit(1).execute().count or 0)
    late = (admin().table("attendance").select("id", count="exact")
            .eq("date", day.isoformat()).eq("status", "late")
            .limit(1).execute().count or 0)

    return {
        "date": day.isoformat(),
        "marks": total,
        "absent": absent,
        "late": late,
        "present": total - absent - late,
        "attendance_rate": round((total - absent) / total * 100, 1) if total else None,
    }
