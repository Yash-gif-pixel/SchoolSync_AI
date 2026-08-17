"""Who is in the school: the student roll and the staff list.

Flat lists rather than pre-grouped ones. The dashboard groups students by
class and staff by department, but the events picker wants one searchable list
of everybody — serving the flat shape means one endpoint instead of two that
drift apart.

Paged, because the roll is larger than PostgREST's 1000-row ceiling and a
directory that silently stops at a thousand names is worse than none.
"""

from __future__ import annotations

from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Response,
    UploadFile,
    status,
)
from pydantic import BaseModel

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.images import NotAnImage, portrait_jpeg
from ..services.storage import signed_url, signed_urls

router = APIRouter(prefix="/directory", tags=["directory"])

PAGE_SIZE = 1000

# See db/011_student_photos.sql for why this is not the documents bucket.
PHOTO_BUCKET = "student-photos"
PHOTO_MIME = {"image/jpeg", "image/png", "image/webp", "image/heic"}

# Generous, because it is a phone photo before we shrink it. The bucket
# enforces its own limit too; this one exists to reject the upload before
# reading megabytes of it into memory.
MAX_PHOTO_BYTES = 12 * 1024 * 1024

# Which flag each post writes, and whether the school may have more than one
# holder of it. Principal and Vice Principal are unique school-wide — the
# database enforces that with a partial unique index, so appointing a new one
# MUST stand the old one down in the same breath or the insert simply fails.
POSTS = {
    "principal":      {"column": "is_principal",      "scope": "school"},
    "vice_principal": {"column": "is_vice_principal", "scope": "school"},
    "hod":            {"column": "is_approver",       "scope": "department"},
}


class Appointment(BaseModel):
    role: str
    appointed: bool = True


def _page(table: str, columns: str, order: str) -> list[dict]:
    out: list[dict] = []
    start = 0
    while True:
        rows = (
            admin().table(table).select(columns).order(order)
            .range(start, start + PAGE_SIZE - 1).execute().data or []
        )
        out.extend(rows)
        if len(rows) < PAGE_SIZE:
            return out
        start += PAGE_SIZE


@router.get("/students")
def students(user: CurrentUser = Depends(require_admin)) -> dict:
    """Every student on roll, with the class they belong to."""
    rows = _page(
        "students",
        "id, full_name, roll_no, guardian_name, guardian_phone, class_id, "
        "photo_url",
        "full_name",
    )
    classes = {
        c["id"]: c for c in
        (admin().table("classes").select("id, name, grade, section")
         .execute().data or [])
    }

    # Signed in one batch. Signing 1,800 portraits one at a time would take
    # longer than everything else on this endpoint put together.
    photos = signed_urls(PHOTO_BUCKET, [s.get("photo_url") for s in rows])

    out = []
    for s in rows:
        cls = classes.get(s.get("class_id")) or {}
        out.append({
            **s,
            # The stored value is a bucket path and is no use to a browser;
            # hand back something it can actually load.
            "photo_url": photos.get(s.get("photo_url")),
            "class_name": cls.get("name"),
            "grade": cls.get("grade"),
            "section": cls.get("section"),
        })
    # Roll order within a class is how a register reads.
    out.sort(key=lambda s: (
        s.get("grade") or 99, s.get("section") or "", s.get("roll_no") or 0))

    return {
        "students": out,
        "classes": sorted(
            classes.values(), key=lambda c: (c["grade"], c["section"])),
    }


# ------------------------------------------------------------ photographs
def _student_or_404(student_id: str) -> dict:
    res = (admin().table("students").select("id, full_name, photo_url")
           .eq("id", student_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such student")
    return res.data


@router.post("/students/{student_id}/photo")
async def set_student_photo(
    student_id: str,
    file: UploadFile = File(...),
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Attach a portrait to a student.

    Admin only. A photograph of a child is the most sensitive thing in this
    database, and a teacher having a class does not make them the person who
    curates its pictures.

    The upload is normalised before it is stored — squared, turned upright and
    stripped of EXIF, which on a phone photo includes where it was taken. See
    services/images.py.
    """
    student = _student_or_404(student_id)

    data = await file.read()
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty file")
    if len(data) > MAX_PHOTO_BYTES:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            f"That photo is {len(data) // 1024 // 1024} MB; the limit is "
            f"{MAX_PHOTO_BYTES // 1024 // 1024} MB.",
        )

    mime = file.content_type or "image/jpeg"
    if mime not in PHOTO_MIME:
        raise HTTPException(
            status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            f"Unsupported type {mime}. Use JPEG, PNG or WebP.",
        )

    try:
        thumbnail = portrait_jpeg(data)
    except NotAnImage as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e))

    # A fixed path per student, overwritten in place. Versioned names would
    # accumulate every rejected attempt forever, and nothing would ever point
    # at them again.
    path = f"{student_id}.jpg"
    admin().storage.from_(PHOTO_BUCKET).upload(
        path, thumbnail, {"content-type": "image/jpeg", "upsert": "true"}
    )

    admin().table("students").update({"photo_url": path}) \
        .eq("id", student_id).execute()

    return {
        "student_id": student_id,
        "full_name": student["full_name"],
        "photo_url": signed_url(PHOTO_BUCKET, path),
        "bytes": len(thumbnail),
        "message": f"Photo saved for {student['full_name']}.",
    }


@router.delete("/students/{student_id}/photo",
               status_code=status.HTTP_204_NO_CONTENT)
def clear_student_photo(
    student_id: str,
    user: CurrentUser = Depends(require_admin),
) -> Response:
    """Remove a student's portrait and fall back to their initials."""
    student = _student_or_404(student_id)

    if student.get("photo_url"):
        try:
            admin().storage.from_(PHOTO_BUCKET).remove([student["photo_url"]])
        except Exception:
            pass  # clearing the column matters more than an orphaned object

    admin().table("students").update({"photo_url": None}) \
        .eq("id", student_id).execute()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/staff")
def staff(user: CurrentUser = Depends(get_current_user)) -> list[dict]:
    """Everyone on the payroll, with their department and responsibilities.

    Readable by any signed-in user — a teacher needs to know who their head of
    department is. Contact details are deliberately not included.
    """
    people = _page(
        "profiles",
        "id, full_name, role, department_id, is_approver, is_vice_principal, "
        "is_principal, employee_code",
        "full_name",
    )
    departments = {
        d["id"]: d["name"] for d in
        (admin().table("departments").select("id, name").execute().data or [])
    }
    return [
        {
            "id": p["id"],
            "full_name": p["full_name"],
            "role": p["role"],
            "employee_code": p.get("employee_code"),
            "department_id": p.get("department_id"),
            "department": departments.get(p.get("department_id")),
            "is_approver": bool(p.get("is_approver")),
            "is_vice_principal": bool(p.get("is_vice_principal")),
            "is_principal": bool(p.get("is_principal")),
        }
        for p in people
    ]


@router.post("/staff/{profile_id}/appoint")
def appoint(
    profile_id: str,
    body: Appointment,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Appoint or stand down a member of staff.

    Roles: `principal`, `vice_principal`, `hod`.

    Each post is exclusive within its scope, so appointing somebody always
    means replacing whoever held it. That is done here rather than left to the
    admin as two separate clicks: a half-finished swap would either leave the
    school with two principals or, because of the unique index, fail outright
    and look like a bug.
    """
    post = POSTS.get(body.role)
    if not post:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"Unknown role '{body.role}'. Expected one of "
            f"{', '.join(sorted(POSTS))}.",
        )

    sb = admin()
    column = post["column"]

    person = (
        sb.table("profiles")
        .select("id, full_name, role, department_id")
        .eq("id", profile_id).maybe_single().execute()
    )
    if not person or not person.data:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such staff member")
    person = person.data

    if body.appointed:
        if person["role"] == "admin":
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "The administrator account is office staff and cannot hold a "
                "teaching post. Appoint a member of teaching staff.",
            )
        if post["scope"] == "department" and not person.get("department_id"):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"{person['full_name']} is not in a department, so there is "
                f"nothing to be head of.",
            )

        # Stand the incumbent down first — see the docstring.
        stand_down = sb.table("profiles").update({column: False}) \
            .eq(column, True).neq("id", profile_id)
        if post["scope"] == "department":
            stand_down = stand_down.eq(
                "department_id", person["department_id"])
        replaced = stand_down.execute().data or []
    else:
        replaced = []

    sb.table("profiles").update({column: body.appointed}) \
        .eq("id", profile_id).execute()

    return {
        "id": profile_id,
        "full_name": person["full_name"],
        "role": body.role,
        "appointed": body.appointed,
        "replaced": [r["full_name"] for r in replaced],
    }
