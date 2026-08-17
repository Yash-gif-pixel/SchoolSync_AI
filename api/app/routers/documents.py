"""Document reader endpoints: upload -> extract -> review -> commit.

Commit is deliberately separate from extraction. Nothing the model produces
reaches a domain table until a human has looked at it and pressed a button, and
the values committed are the ones on screen at that moment — not the ones the
model originally returned.

Where a commit lands is decided by the template's target, so the same pipeline
handles admission forms, leave notes and anything else a school scans.
"""

from __future__ import annotations

import datetime as dt
import statistics
import uuid
from typing import Any

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import BaseModel

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.document_ai import extract as run_extraction
from ..services.leave_rules import describe_clash, overlapping_leave
from ..services.people import resolve_person
from ..services.storage import signed_url
from ..services.validation import validate

router = APIRouter(prefix="/documents", tags=["documents"])

BUCKET = "documents"
ALLOWED_MIME = {"image/jpeg", "image/png", "image/webp", "image/heic"}
MAX_BYTES = 12 * 1024 * 1024


# --------------------------------------------------------------- helpers
def _mean_confidence(fields: list[dict]) -> float:
    vals = [f["confidence"] for f in fields if f.get("present_on_form")]
    return round(statistics.fmean(vals), 3) if vals else 0.0


def _with_url(row: dict) -> dict:
    return {**row, "image_url": signed_url(BUCKET, row.get("storage_path"))}


def _load_template(template_id: str | None) -> dict:
    q = admin().table("document_templates").select("*")
    if template_id:
        res = q.eq("id", template_id).maybe_single().execute()
        if not res or not res.data:
            raise HTTPException(404, "Template not found")
        return res.data
    # Default to the built-in admission form when the caller doesn't choose.
    res = q.eq("is_builtin", True).limit(1).execute()
    if not res.data:
        raise HTTPException(
            500, "No templates exist. Apply db/003_templates.sql."
        )
    return res.data[0]


def _spec_by_maps_to(template: dict, target_column: str) -> dict | None:
    for f in template.get("fields", []):
        if f.get("maps_to") == target_column:
            return f
    return None


def _validation_context(template: dict) -> dict:
    """Database facts the validation rules need. Fetched only when a template
    actually references them, so an admission form does not pay for it."""
    ctx: dict = {}
    if _spec_by_maps_to(template, "__teacher"):
        ctx["teachers"] = (admin().table("profiles").select("id, full_name")
                           .eq("role", "teacher").execute().data)
    return ctx


# --------------------------------------------------------------- extract
@router.post("/extract", status_code=status.HTTP_201_CREATED)
async def extract_document(
    file: UploadFile = File(...),
    template_id: str | None = Form(default=None),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """Upload one form, read it against a template, and store the result.

    Writes nothing to a domain table — that happens on commit.
    """
    data = await file.read()
    if not data:
        raise HTTPException(400, "Empty file")
    if len(data) > MAX_BYTES:
        raise HTTPException(413, f"File is {len(data) // 1024 // 1024} MB; limit is 12 MB")

    mime = file.content_type or "image/jpeg"
    if mime not in ALLOWED_MIME:
        raise HTTPException(415, f"Unsupported type {mime}. Use JPEG, PNG, WebP or HEIC.")

    template = _load_template(template_id)

    ext = {"image/jpeg": "jpg", "image/png": "png",
           "image/webp": "webp", "image/heic": "heic"}[mime]
    path = f"scans/{uuid.uuid4()}.{ext}"
    admin().storage.from_(BUCKET).upload(path, data, {"content-type": mime, "upsert": "false"})

    doc = admin().table("documents").insert({
        "storage_path": path,
        "status": "uploaded",
        "template_id": template["id"],
        "uploaded_by": user.id,
    }).execute().data[0]

    try:
        raw = run_extraction(data, template, mime)
    except Exception as e:
        admin().table("documents").update({
            "status": "failed", "error": f"{type(e).__name__}: {e}",
        }).eq("id", doc["id"]).execute()
        raise HTTPException(502, f"Extraction failed: {type(e).__name__}: {e}")

    result = validate(raw, template, context=_validation_context(template))

    updated = admin().table("documents").update({
        "status": "needs_review" if result["needs_review"] else "extracted",
        "extracted_json": result,
        "confidence": _mean_confidence(result["fields"]),
        "model": raw.get("_model"),
    }).eq("id", doc["id"]).execute().data[0]

    return {**_with_url(updated), "template": template}


# ------------------------------------------------------------------ read
@router.get("")
def list_documents(
    status_filter: str | None = None,
    template_id: str | None = None,
    limit: int = 50,
    user: CurrentUser = Depends(get_current_user),
) -> list[dict]:
    q = (admin().table("documents")
         .select("*, document_templates(id, name, target, fields)")
         .order("created_at", desc=True)
         .limit(limit))
    if status_filter:
        q = q.eq("status", status_filter)
    if template_id:
        q = q.eq("template_id", template_id)
    return q.execute().data


@router.get("/{doc_id}")
def get_document(doc_id: str, user: CurrentUser = Depends(get_current_user)) -> dict:
    res = (admin().table("documents")
           .select("*, document_templates(id, name, target, fields, description)")
           .eq("id", doc_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Document not found")
    row = res.data
    return {**_with_url(row), "template": row.get("document_templates")}


# ---------------------------------------------------------------- commit
class CommitPayload(BaseModel):
    """The reviewed values, keyed by template field, as shown on screen when
    the reviewer pressed commit."""
    values: dict[str, Any]


def _place_in_class(grade: int) -> dict:
    """Put the student in the least-full section of their grade."""
    classes = (admin().table("classes").select("id, name, section")
               .eq("grade", grade).execute().data)
    if not classes:
        raise HTTPException(422, f"This school has no class for grade {grade}.")
    counts = []
    for c in classes:
        n = (admin().table("students").select("id", count="exact")
             .eq("class_id", c["id"]).limit(1).execute().count or 0)
        counts.append((n, c))
    counts.sort(key=lambda t: (t[0], t[1]["section"]))
    return counts[0][1]


def _commit_student(template: dict, values: dict, doc_id: str) -> dict:
    name_spec = _spec_by_maps_to(template, "full_name")
    class_spec = _spec_by_maps_to(template, "__class")
    if not name_spec or not class_spec:
        raise HTTPException(
            422, "This template does not map a name and a class, so it cannot "
                 "create a student."
        )

    full_name = (values.get(name_spec["key"]) or "").strip()
    if not full_name:
        raise HTTPException(422, "Student name is required.")

    raw_grade = str(values.get(class_spec["key"]) or "").strip()
    if not raw_grade.isdigit():
        raise HTTPException(422, f"Class '{raw_grade}' is not a number.")
    cls = _place_in_class(int(raw_grade))

    highest = (admin().table("students").select("roll_no")
               .eq("class_id", cls["id"])
               .order("roll_no", desc=True).limit(1).execute().data)
    next_roll = (highest[0]["roll_no"] + 1) if highest and highest[0]["roll_no"] else 1

    row: dict[str, Any] = {
        "full_name": full_name,
        "class_id": cls["id"],
        "roll_no": next_roll,
        "source_document_id": doc_id,
    }
    for f in template["fields"]:
        col = f.get("maps_to")
        if not col or col.startswith("__") or col == "full_name":
            continue
        v = values.get(f["key"])
        row[col] = (v.strip() or None) if isinstance(v, str) else v

    student = admin().table("students").insert(row).execute().data[0]
    return {
        "kind": "student",
        "record": student,
        "class": cls,
        "message": f"{student['full_name']} admitted to {cls['name']}, roll no {next_roll}.",
    }


def _commit_leave(template: dict, values: dict, doc_id: str, user: CurrentUser) -> dict:
    row: dict[str, Any] = {
        "status": "pending_incharge",
        "source_document_id": doc_id,
    }
    for f in template["fields"]:
        col = f.get("maps_to")
        if col in {"from_date", "to_date", "reason"}:
            row[col] = values.get(f["key"]) or None

    if not row.get("from_date") or not row.get("to_date"):
        raise HTTPException(422, "A leave request needs both a start and an end date.")

    # Whose leave is it? A scanned note names its owner, so filing it against
    # whoever happens to be signed in would attribute an admin's upload to the
    # admin. Only fall back to the uploader when the template has no name field
    # — i.e. a teacher scanning their own note.
    who_spec = _spec_by_maps_to(template, "__teacher")
    if who_spec:
        written = values.get(who_spec["key"])
        staff = (admin().table("profiles").select("id, full_name")
                 .eq("role", "teacher").execute().data)
        match = resolve_person(written, staff)
        if not match.ok:
            names = ", ".join(c["full_name"] for c in match.candidates)
            raise HTTPException(422, {
                "message": f"Could not tell whose leave this is: '{written}'.",
                "candidates": match.candidates,
                "hint": f"Did you mean {names}?" if names else
                        "Type the full name as it appears in the staff list.",
            })
        row["teacher_id"] = match.resolved_id
        owner = match.resolved_name
    else:
        row["teacher_id"] = user.id
        owner = user.full_name

    # A scanned note is a second door into the leave table, and it must refuse
    # a clash exactly as the leave form does. Without this the database's own
    # exclusion constraint fires instead and the reviewer gets a bare 500.
    clashes = overlapping_leave(
        admin(),
        row["teacher_id"],
        dt.date.fromisoformat(row["from_date"]),
        dt.date.fromisoformat(row["to_date"]),
    )
    if clashes:
        raise HTTPException(409, describe_clash(
            clashes[0], subject=f"{owner} has",
        ))

    leave = admin().table("leave_requests").insert(row).execute().data[0]
    same_day = leave["from_date"] == leave["to_date"]
    when = (leave["from_date"] if same_day
            else f"{leave['from_date']} to {leave['to_date']}")
    return {
        "kind": "leave_request",
        "record": leave,
        "teacher": owner,
        "message": f"Leave request created for {owner}, {when}. "
                   f"Awaiting approval from their head of department.",
    }


def _commit_data(template: dict, values: dict, doc_id: str, user: CurrentUser) -> dict:
    rec = admin().table("extracted_records").insert({
        "template_id": template["id"],
        "document_id": doc_id,
        "data": values,
        "created_by": user.id,
    }).execute().data[0]
    return {
        "kind": "data_only",
        "record": rec,
        "message": f"{len(values)} fields saved from this {template['name']}.",
    }


@router.post("/{doc_id}/commit")
def commit_document(
    doc_id: str,
    payload: CommitPayload,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Create the record the template targets, from reviewed values. Admin only."""
    res = (admin().table("documents")
           .select("*, document_templates(*)")
           .eq("id", doc_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Document not found")
    doc = res.data
    if doc["status"] == "committed":
        raise HTTPException(409, "This document has already been committed.")

    template = doc.get("document_templates")
    if not template:
        raise HTTPException(422, "This document has no template, so it cannot be committed.")

    values = payload.values
    target = template.get("target", "data_only")
    if target == "student":
        out = _commit_student(template, values, doc_id)
    elif target == "leave_request":
        out = _commit_leave(template, values, doc_id, user)
    else:
        out = _commit_data(template, values, doc_id, user)

    admin().table("documents").update({
        "status": "committed", "committed_at": "now()",
    }).eq("id", doc_id).execute()

    return out


@router.delete("/{doc_id}", status_code=status.HTTP_204_NO_CONTENT)
def discard_document(doc_id: str, user: CurrentUser = Depends(require_admin)) -> None:
    res = (admin().table("documents").select("storage_path")
           .eq("id", doc_id).maybe_single().execute())
    if res and res.data:
        try:
            admin().storage.from_(BUCKET).remove([res.data["storage_path"]])
        except Exception:
            pass  # the row matters more than the orphaned object
    admin().table("documents").delete().eq("id", doc_id).execute()
