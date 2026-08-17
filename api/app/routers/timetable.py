"""Timetable generation and retrieval.

Generation is admin-only and writes a new *version* rather than overwriting
the live one, so a bad solve never destroys a working timetable. Exactly one
version is active at a time.
"""

from __future__ import annotations

from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.jobs import jobs
from ..services.timetable import DEFAULT_TIME_LIMIT, preflight, solve

router = APIRouter(prefix="/timetable", tags=["timetable"])

#: One kind of job so far; named so the registry can refuse two at once.
SOLVE_JOB = "timetable.generate"

# Which lab a subject needs. Anything else that requires_lab falls back to a
# science lab.
LAB_TYPE_BY_SUBJECT_CODE = {"CS": "computer_lab", "SCI": "science_lab"}


# --------------------------------------------------------------- loading
def load_school() -> dict:
    """Everything the solver needs, in one shape."""
    sb = admin()

    slots = [s for s in sb.table("time_slots").select("*").execute().data
             if not s["is_break"]]
    classes = sb.table("classes").select("id, name, grade, section, home_room_id").execute().data
    rooms = sb.table("rooms").select("id, name, type").execute().data
    subjects = {s["id"]: s for s in sb.table("subjects").select("id, name, code").execute().data}
    teachers = (sb.table("profiles").select("id, full_name, department_id")
                .eq("role", "teacher").execute().data)

    raw = sb.table("teaching_assignments").select("*").execute().data
    assignments = []
    for a in raw:
        sub = subjects.get(a["subject_id"], {})
        assignments.append({
            **a,
            "subject_name": sub.get("name", "?"),
            "subject_code": sub.get("code", "?"),
            "lab_type": LAB_TYPE_BY_SUBJECT_CODE.get(sub.get("code"), "science_lab")
            if a["requires_lab"] else None,
        })

    labs_by_type: dict[str, list[str]] = defaultdict(list)
    for r in rooms:
        if r["type"] in ("science_lab", "computer_lab"):
            labs_by_type[r["type"]].append(r["id"])

    return {
        "slots": slots,
        "classes": classes,
        "teachers": teachers,
        "assignments": assignments,
        "subjects": subjects,
        "labs_by_type": dict(labs_by_type),
        "lab_capacity": {k: len(v) for k, v in labs_by_type.items()},
        "home_room_by_class": {c["id"]: c["home_room_id"] for c in classes},
        "class_by_id": {c["id"]: c for c in classes},
        "teacher_by_id": {t["id"]: t for t in teachers},
        "unavailable": {},
    }


# ------------------------------------------------------------- generate
class GenerateOptions(BaseModel):
    time_limit: float = Field(default=DEFAULT_TIME_LIMIT, ge=1, le=120)
    optimise_gaps: bool = True
    label: str | None = None
    activate: bool = True


class NothingToSchedule(ValueError):
    """The school has no teaching assignments, so there is nothing to solve."""


def _generate(opts: GenerateOptions) -> dict:
    """Solve, store the result as a new version, and publish it if it is whole.

    Synchronous and self-contained: it is called both straight from a request
    and from a worker thread, and must behave identically either way. It
    raises a domain error rather than an HTTPException for the same reason —
    on the job path there is no request left to turn a status code into.
    """
    data = load_school()

    if not data["assignments"]:
        raise NothingToSchedule("There are no teaching assignments to schedule.")

    result = solve(data, time_limit=opts.time_limit, optimise_gaps=opts.optimise_gaps)

    version = admin().table("timetable_versions").insert({
        "label": opts.label or f"Generated ({result.stats.get('solver_status', '')})",
        "status": "infeasible" if result.status == "infeasible" else "draft",
        "solver_stats": result.stats,
        "diagnostics": [d.as_dict() for d in result.diagnostics],
    }).execute().data[0]

    if result.entries:
        rows = [{**e, "version_id": version["id"]} for e in result.entries]
        for i in range(0, len(rows), 500):
            admin().table("timetable_entries").insert(rows[i:i + 500]).execute()

    # Only publish a timetable that actually placed the whole curriculum.
    activated = False
    if opts.activate and result.placed_everything and result.entries:
        admin().table("timetable_versions").update({"is_active": False}) \
            .eq("is_active", True).execute()
        admin().table("timetable_versions").update(
            {"is_active": True, "status": "active"}
        ).eq("id", version["id"]).execute()
        activated = True

    return {
        "version_id": version["id"],
        "status": result.status,
        "activated": activated,
        "placed_everything": result.placed_everything,
        "stats": result.stats,
        "diagnostics": [d.as_dict() for d in result.diagnostics],
        "error_count": sum(1 for d in result.diagnostics if d.severity == "error"),
        "warning_count": sum(1 for d in result.diagnostics if d.severity == "warning"),
    }


def _refuse_if_solving() -> None:
    live = jobs.running(SOLVE_JOB)
    if live:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"A timetable is already being generated (job {live.id}). Two "
            f"solves on one machine take each other's cores and both miss "
            f"their time budget. Wait for it, or poll "
            f"/timetable/jobs/{live.id}.",
        )


@router.post("/generate", status_code=status.HTTP_201_CREATED)
async def generate(
    opts: GenerateOptions | None = None,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Solve and wait for the answer.

    Straightforward, and fine from a script or over a LAN. Over the public
    internet a 45-second request is at the mercy of whatever proxy sits in
    front of it, so the web client uses POST /timetable/jobs instead and polls.

    `async def` with the work pushed to a thread, rather than a plain `def`:
    both keep the event loop free, but this way the solve is explicit about
    where it runs and shares one code path with the job runner.
    """
    _refuse_if_solving()
    try:
        return await run_in_threadpool(_generate, opts or GenerateOptions())
    except NothingToSchedule as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e))


# ------------------------------------------------------------------- jobs
@router.post("/jobs", status_code=status.HTTP_202_ACCEPTED)
async def start_generation(
    opts: GenerateOptions | None = None,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Start a solve and return at once with something to poll.

    202, not 201: nothing has been created yet. The timetable version appears
    only when the job finishes, and its id is in the job's result.
    """
    _refuse_if_solving()
    opts = opts or GenerateOptions()
    job = await jobs.submit(SOLVE_JOB, lambda: _generate(opts), user.id)
    return {
        **job.as_dict(),
        "poll": f"/timetable/jobs/{job.id}",
        # Not a promise, but callers need something to size a progress bar
        # with, and "unknown" makes for a worse waiting experience than a
        # number that is roughly right.
        "expected_seconds": round(opts.time_limit),
    }


@router.get("/jobs")
def list_jobs(user: CurrentUser = Depends(require_admin)) -> list[dict]:
    """Recent solves, newest first. Results omitted — they are large."""
    return [j.as_dict(include_result=False)
            for j in jobs.recent(SOLVE_JOB)]


@router.get("/jobs/{job_id}")
def get_job(job_id: str, user: CurrentUser = Depends(require_admin)) -> dict:
    """Poll one solve. `result` is null until `status` is "done".

    A job the process has forgotten is a 404, and so is one from before a
    restart — the registry is in memory. A client that gets a 404 while
    polling should look at /timetable/versions, where a solve that did finish
    will have left its version behind.
    """
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            "No such job. It may have finished long enough ago to be "
            "forgotten, or the server may have restarted — check "
            "/timetable/versions for the result.",
        )
    return job.as_dict()


@router.get("/preflight")
def run_preflight(user: CurrentUser = Depends(get_current_user)) -> dict:
    """The arithmetic checks alone — instant, no search."""
    issues = preflight(load_school())
    return {
        "diagnostics": [d.as_dict() for d in issues],
        "error_count": sum(1 for d in issues if d.severity == "error"),
        "warning_count": sum(1 for d in issues if d.severity == "warning"),
        "solvable": not any(d.severity == "error" for d in issues),
    }


# --------------------------------------------------------------- reading
# PostgREST caps a select at 1000 rows. A full week is 40 classes x 36 slots =
# 1440, so an unpaged read silently drops a third of the timetable — and the
# missing periods look like free slots rather than an error.
PAGE_SIZE = 1000

GRID_SELECT = (
    "id, slot_id, room_id, "
    "teaching_assignments(id, periods_per_week, requires_lab, "
    "  classes(id, name, grade, section), "
    "  subjects(id, name, code), "
    "  profiles(id, full_name)), "
    "time_slots(id, day_of_week, slot_index, start_time, end_time), "
    "rooms(id, name, type)"
)


def _grid_rows(version_id: str) -> list[dict]:
    out: list[dict] = []
    start = 0
    while True:
        page = (admin().table("timetable_entries")
                .select(GRID_SELECT)
                .eq("version_id", version_id)
                .range(start, start + PAGE_SIZE - 1)
                .execute().data)
        out.extend(page)
        if len(page) < PAGE_SIZE:
            return out
        start += PAGE_SIZE


@router.get("/versions")
def list_versions(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    return (admin().table("timetable_versions").select("*")
            .order("created_at", desc=True).limit(20).execute().data)


@router.get("/active")
def active_version(user: CurrentUser = Depends(get_current_user)) -> dict:
    res = (admin().table("timetable_versions").select("*")
           .eq("is_active", True).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "No timetable has been published yet.")
    v = res.data
    return {"version": v, "entries": _grid_rows(v["id"])}


@router.get("/versions/{version_id}")
def get_version(version_id: str, user: CurrentUser = Depends(get_current_user)) -> dict:
    res = (admin().table("timetable_versions").select("*")
           .eq("id", version_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Version not found")
    return {"version": res.data, "entries": _grid_rows(version_id)}


@router.post("/versions/{version_id}/activate")
def activate(version_id: str, user: CurrentUser = Depends(require_admin)) -> dict:
    res = (admin().table("timetable_versions").select("*")
           .eq("id", version_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Version not found")
    if res.data["status"] == "infeasible":
        raise HTTPException(409, "This version produced no usable timetable.")

    admin().table("timetable_versions").update({"is_active": False}) \
        .eq("is_active", True).execute()
    row = admin().table("timetable_versions").update(
        {"is_active": True, "status": "active"}
    ).eq("id", version_id).execute().data[0]
    return row


@router.get("/teacher/{teacher_id}")
def teacher_timetable(
    teacher_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """One teacher's week from the live timetable."""
    res = (admin().table("timetable_versions").select("id")
           .eq("is_active", True).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "No timetable has been published yet.")

    rows = _grid_rows(res.data["id"])
    mine = [
        r for r in rows
        if (r.get("teaching_assignments") or {}).get("profiles", {}).get("id") == teacher_id
    ]
    return {"version_id": res.data["id"], "entries": mine, "period_count": len(mine)}


@router.get("/me")
def my_timetable(user: CurrentUser = Depends(get_current_user)) -> dict:
    return teacher_timetable(user.id, user)


@router.get("/class/{class_id}")
def class_timetable(
    class_id: str,
    version_id: str | None = Query(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    if version_id is None:
        res = (admin().table("timetable_versions").select("id")
               .eq("is_active", True).maybe_single().execute())
        if not res or not res.data:
            raise HTTPException(404, "No timetable has been published yet.")
        version_id = res.data["id"]

    rows = _grid_rows(version_id)
    mine = [
        r for r in rows
        if (r.get("teaching_assignments") or {}).get("classes", {}).get("id") == class_id
    ]
    return {"version_id": version_id, "entries": mine, "period_count": len(mine)}
