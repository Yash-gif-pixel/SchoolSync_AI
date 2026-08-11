"""Exams, their calendars, and the seating plan for each day.

The shape here mirrors how a school actually runs an exam season:

    exam        "Half-Yearly Examination 2026"  — a roster of grades
      sitting   Tue 01/09, Mathematics, grades 1 and 2
      sitting   Thu 03/09, Science, grades 1 and 2
      sitting   Tue 08/09, English, grade 9

Seating is planned per sitting. That is what keeps the room rule honest: on
Tuesday only Tuesday's grades leave their classrooms, and every other grade
has a normal school day.

Reading is open to any signed-in user — an invigilator needs to find their
room. Writing is admin only, enforced here and again by RLS.
"""

from __future__ import annotations

import datetime as dt
import time

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.exam_schedule import review_schedule
from ..services.seating import plan_seating

router = APIRouter(tags=["exams"])

# PostgREST caps a select at 1000 rows and the school has more students than
# that. Paging is not optional — it is the difference between a full hall and
# a silently truncated one.
PAGE_SIZE = 1000


def _page(table: str, columns: str, **eq) -> list[dict]:
    out: list[dict] = []
    start = 0
    while True:
        q = admin().table(table).select(columns)
        for k, v in eq.items():
            q = q.eq(k, v)
        rows = q.range(start, start + PAGE_SIZE - 1).execute().data or []
        out.extend(rows)
        if len(rows) < PAGE_SIZE:
            return out
        start += PAGE_SIZE


def _grades_validator(v: list[int]) -> list[int]:
    bad = [g for g in v if not 1 <= g <= 12]
    if bad:
        raise ValueError(f"grades must be between 1 and 12, got {bad}")
    return sorted(set(v))


class ExamCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    notes: str | None = Field(default=None, max_length=500)
    grades: list[int] = Field(min_length=1)

    _v = field_validator("grades")(classmethod(lambda cls, v: _grades_validator(v)))


class ExamUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    notes: str | None = Field(default=None, max_length=500)
    grades: list[int] | None = None

    _v = field_validator("grades")(
        classmethod(lambda cls, v: v if v is None else _grades_validator(v)))


class SittingCreate(BaseModel):
    sits_on: dt.date
    paper: str | None = Field(default=None, max_length=120)
    starts_at: dt.time | None = None
    grades: list[int] = Field(min_length=1)

    _v = field_validator("grades")(classmethod(lambda cls, v: _grades_validator(v)))


# ---------------------------------------------------------------------
# exams
# ---------------------------------------------------------------------

def _load_sittings(exam_id: str) -> list[dict]:
    sb = admin()
    sittings = (
        sb.table("exam_sittings").select("*")
        .eq("exam_id", exam_id).order("sits_on").execute().data or []
    )
    if not sittings:
        return []

    ids = [s["id"] for s in sittings]
    links = (
        sb.table("exam_sitting_grades").select("sitting_id, grade")
        .in_("sitting_id", ids).execute().data or []
    )
    plans = (
        sb.table("seating_plans").select("id, sitting_id, stats")
        .in_("sitting_id", ids).eq("is_active", True).execute().data or []
    )

    by_sitting: dict[str, list[int]] = {}
    for link in links:
        by_sitting.setdefault(link["sitting_id"], []).append(link["grade"])
    plan_by_sitting = {p["sitting_id"]: p for p in plans}

    for s in sittings:
        s["grades"] = sorted(by_sitting.get(s["id"], []))
        s["plan"] = plan_by_sitting.get(s["id"])
    return sittings


@router.get("/exams")
def list_exams(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    sb = admin()
    exams = (
        sb.table("exams").select("*").order("created_at", desc=True)
        .execute().data or []
    )
    if not exams:
        return []

    ids = [e["id"] for e in exams]
    roster = (
        sb.table("exam_grades").select("exam_id, grade")
        .in_("exam_id", ids).execute().data or []
    )
    by_exam: dict[str, list[int]] = {}
    for g in roster:
        by_exam.setdefault(g["exam_id"], []).append(g["grade"])

    for e in exams:
        e["grades"] = sorted(by_exam.get(e["id"], []))
        e["sittings"] = _load_sittings(e["id"])
    return exams


@router.post("/exams", status_code=status.HTTP_201_CREATED)
def create_exam(
    body: ExamCreate, user: CurrentUser = Depends(require_admin)
) -> dict:
    sb = admin()
    res = sb.table("exams").insert({
        "name": body.name,
        "notes": body.notes,
        "created_by": user.id,
    }).execute()
    if not res.data:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Could not create the exam")

    exam = res.data[0]
    sb.table("exam_grades").insert(
        [{"exam_id": exam["id"], "grade": g} for g in body.grades]
    ).execute()
    exam["grades"] = body.grades
    exam["sittings"] = []
    return exam


@router.patch("/exams/{exam_id}")
def update_exam(
    exam_id: str, body: ExamUpdate,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    sb = admin()
    fields = {
        k: v for k, v in (
            ("name", body.name),
            ("notes", body.notes),
        ) if v is not None
    }
    if fields:
        sb.table("exams").update(fields).eq("id", exam_id).execute()

    if body.grades is not None:
        sb.table("exam_grades").delete().eq("exam_id", exam_id).execute()
        sb.table("exam_grades").insert(
            [{"exam_id": exam_id, "grade": g} for g in body.grades]
        ).execute()

    exam = (
        sb.table("exams").select("*").eq("id", exam_id)
        .maybe_single().execute()
    )
    if not exam or not exam.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such exam")
    out = exam.data
    out["grades"] = sorted(
        r["grade"] for r in
        (sb.table("exam_grades").select("grade")
         .eq("exam_id", exam_id).execute().data or [])
    )
    out["sittings"] = _load_sittings(exam_id)
    return out


@router.delete("/exams/{exam_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_exam(
    exam_id: str, user: CurrentUser = Depends(require_admin)
) -> None:
    admin().table("exams").delete().eq("id", exam_id).execute()


# ---------------------------------------------------------------------
# the calendar
# ---------------------------------------------------------------------

@router.get("/exams/{exam_id}/schedule")
def get_schedule(
    exam_id: str, user: CurrentUser = Depends(get_current_user)
) -> dict:
    sb = admin()
    exam = (
        sb.table("exams").select("*").eq("id", exam_id)
        .maybe_single().execute()
    )
    if not exam or not exam.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such exam")

    roster = sorted(
        r["grade"] for r in
        (sb.table("exam_grades").select("grade")
         .eq("exam_id", exam_id).execute().data or [])
    )
    sittings = _load_sittings(exam_id)
    review = review_schedule(sittings=sittings, roster=roster)

    return {
        "exam": {**exam.data, "grades": roster},
        "sittings": sittings,
        "diagnostics": [d.as_dict() for d in review],
    }


@router.post("/exams/{exam_id}/sittings", status_code=status.HTTP_201_CREATED)
def add_sitting(
    exam_id: str, body: SittingCreate,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    sb = admin()
    exam = (
        sb.table("exams").select("id").eq("id", exam_id)
        .maybe_single().execute()
    )
    if not exam or not exam.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such exam")

    res = sb.table("exam_sittings").insert({
        "exam_id": exam_id,
        "sits_on": body.sits_on.isoformat(),
        "paper": body.paper,
        "starts_at": body.starts_at.isoformat() if body.starts_at else None,
    }).execute()
    if not res.data:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Could not add the sitting")

    sitting = res.data[0]
    sb.table("exam_sitting_grades").insert(
        [{"sitting_id": sitting["id"], "grade": g} for g in body.grades]
    ).execute()
    sitting["grades"] = body.grades
    sitting["plan"] = None
    return sitting


@router.delete("/sittings/{sitting_id}",
               status_code=status.HTTP_204_NO_CONTENT)
def delete_sitting(
    sitting_id: str, user: CurrentUser = Depends(require_admin)
) -> None:
    admin().table("exam_sittings").delete().eq("id", sitting_id).execute()


# ---------------------------------------------------------------------
# seating, per sitting
# ---------------------------------------------------------------------

def _sitting_or_404(sitting_id: str) -> dict:
    sb = admin()
    s = (
        sb.table("exam_sittings").select("*").eq("id", sitting_id)
        .maybe_single().execute()
    )
    if not s or not s.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such sitting")
    sitting = s.data
    sitting["grades"] = sorted(
        r["grade"] for r in
        (sb.table("exam_sitting_grades").select("grade")
         .eq("sitting_id", sitting_id).execute().data or [])
    )
    return sitting


@router.post("/sittings/{sitting_id}/seating",
             status_code=status.HTTP_201_CREATED)
def generate_seating(
    sitting_id: str, user: CurrentUser = Depends(require_admin)
) -> dict:
    t0 = time.perf_counter()
    sb = admin()
    sitting = _sitting_or_404(sitting_id)

    if not sitting["grades"]:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "No grades are sitting on this day.",
        )

    classes = _page("classes", "id, grade, section, name, home_room_id")
    students = _page("students", "id, class_id, full_name, roll_no")
    rooms = _page("rooms", "id, name, type, block, floor_no, room_no, "
                           "seat_rows, seat_cols")

    result = plan_seating(
        grades=sitting["grades"], classes=classes,
        students=students, rooms=rooms,
    )

    errors = [d for d in result.diagnostics if d.severity == "error"]
    if errors and not result.seats:
        return {
            "plan": None,
            "stats": result.stats,
            "diagnostics": [d.as_dict() for d in result.diagnostics],
        }

    result.stats["wall_seconds"] = round(time.perf_counter() - t0, 3)
    result.stats["sits_on"] = sitting["sits_on"]

    sb.table("seating_plans").delete().eq("sitting_id", sitting_id).execute()
    plan = sb.table("seating_plans").insert({
        "sitting_id": sitting_id,
        "is_active": True,
        "stats": result.stats,
        "diagnostics": [d.as_dict() for d in result.diagnostics],
    }).execute().data[0]

    rows = [{"plan_id": plan["id"], **s.as_dict()} for s in result.seats]
    for i in range(0, len(rows), PAGE_SIZE):
        sb.table("seat_allocations").insert(rows[i:i + PAGE_SIZE]).execute()

    return {
        "plan": plan,
        "stats": result.stats,
        "diagnostics": [d.as_dict() for d in result.diagnostics],
    }


@router.get("/sittings/{sitting_id}/seating")
def get_seating(
    sitting_id: str, user: CurrentUser = Depends(get_current_user)
) -> dict:
    sb = admin()
    plan = (
        sb.table("seating_plans").select("*")
        .eq("sitting_id", sitting_id).eq("is_active", True)
        .maybe_single().execute()
    )
    if not plan or not plan.data:
        return {"plan": None, "rooms": []}

    allocations = _page(
        "seat_allocations",
        "student_id, room_id, seat_row, seat_col",
        plan_id=plan.data["id"],
    )
    students = {s["id"]: s for s in _page(
        "students", "id, full_name, roll_no, class_id")}
    classes = {c["id"]: c for c in _page("classes", "id, name, grade, section")}
    rooms = {r["id"]: r for r in _page(
        "rooms", "id, name, block, floor_no, room_no, seat_rows, seat_cols")}

    by_room: dict[str, list[dict]] = {}
    for a in allocations:
        stu = students.get(a["student_id"]) or {}
        cls = classes.get(stu.get("class_id")) or {}
        by_room.setdefault(a["room_id"], []).append({
            "student_id": a["student_id"],
            "student_name": stu.get("full_name"),
            "roll_no": stu.get("roll_no"),
            "class_name": cls.get("name"),
            "seat_row": a["seat_row"],
            "seat_col": a["seat_col"],
        })

    out = []
    for rid, seats in by_room.items():
        room = rooms.get(rid) or {}
        seats.sort(key=lambda s: (s["seat_row"], s["seat_col"]))
        out.append({
            "room_id": rid,
            "room_name": room.get("name"),
            "block": room.get("block"),
            "floor_no": room.get("floor_no"),
            "seat_rows": room.get("seat_rows"),
            "seat_cols": room.get("seat_cols"),
            "classes": sorted(
                {s["class_name"] for s in seats if s["class_name"]}),
            "seats": seats,
        })
    out.sort(key=lambda r: (r["block"] or "", r["floor_no"] or 0,
                            r["room_name"] or ""))

    return {"plan": plan.data, "rooms": out}
