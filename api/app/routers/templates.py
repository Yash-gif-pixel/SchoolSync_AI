"""Template management: discover a form's schema, then curate it.

Discovery is a proposal, never a save. A school photographs its own blank form,
the model reads the labels off it, and an admin edits the result before it
becomes a template. Nothing the model invents reaches the database unreviewed.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from pydantic import BaseModel, Field

from ..auth import CurrentUser, get_current_user, require_admin
from ..db import admin
from ..services.document_ai import discover_template
from ..services.storage import signed_url
from ..services.templates import FIELD_TYPES, TARGET_COLUMNS, TARGETS, validate_definition

router = APIRouter(prefix="/templates", tags=["templates"])

BUCKET = "documents"
ALLOWED_MIME = {"image/jpeg", "image/png", "image/webp", "image/heic"}
MAX_BYTES = 12 * 1024 * 1024


class TemplateField(BaseModel):
    key: str
    label: str
    type: str
    required: bool = False
    maps_to: str | None = None
    description: str | None = None
    options: list[str] | None = None


class TemplatePayload(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str | None = None
    target: str = "data_only"
    fields: list[TemplateField]
    sample_path: str | None = None
    is_active: bool = True


@router.get("/field-types")
def field_types(user: CurrentUser = Depends(get_current_user)) -> dict:
    """Everything the template editor needs to render its dropdowns."""
    return {
        "types": [
            {"value": k, "label": v["label"], "hint": v["hint"]}
            for k, v in FIELD_TYPES.items()
        ],
        "targets": [{"value": k, "label": v} for k, v in TARGETS.items()],
        "target_columns": {k: sorted(v) for k, v in TARGET_COLUMNS.items()},
    }


@router.get("")
def list_templates(
    include_inactive: bool = False,
    user: CurrentUser = Depends(get_current_user),
) -> list[dict]:
    q = admin().table("document_templates").select("*").order("created_at")
    if not include_inactive:
        q = q.eq("is_active", True)
    return q.execute().data


@router.get("/{template_id}")
def get_template(template_id: str, user: CurrentUser = Depends(get_current_user)) -> dict:
    res = (admin().table("document_templates").select("*")
           .eq("id", template_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Template not found")
    return res.data


@router.post("/discover")
async def discover(
    file: UploadFile = File(...),
    user: CurrentUser = Depends(require_admin),
) -> dict:
    """Read a form and propose a template for it. Saves nothing."""
    data = await file.read()
    if not data:
        raise HTTPException(400, "Empty file")
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "File exceeds the 12 MB limit")

    mime = file.content_type or "image/jpeg"
    if mime not in ALLOWED_MIME:
        raise HTTPException(415, f"Unsupported type {mime}. Use JPEG, PNG, WebP or HEIC.")

    ext = {"image/jpeg": "jpg", "image/png": "png",
           "image/webp": "webp", "image/heic": "heic"}[mime]
    path = f"templates/{uuid.uuid4()}.{ext}"
    admin().storage.from_(BUCKET).upload(path, data, {"content-type": mime, "upsert": "false"})

    try:
        proposal = discover_template(data, mime)
    except Exception as e:
        raise HTTPException(502, f"Could not read the form: {type(e).__name__}: {e}")

    if not proposal.get("fields"):
        raise HTTPException(
            422, "No fields could be identified on that image. "
                 "Try a clearer photo, or build the template by hand."
        )

    proposal["sample_path"] = path
    proposal["sample_url"] = signed_url(BUCKET, path)

    # Surface problems now so the editor can show them before saving.
    proposal["definition_errors"] = validate_definition(
        proposal["fields"], proposal.get("suggested_target", "data_only")
    )
    return proposal


@router.post("", status_code=status.HTTP_201_CREATED)
def create_template(
    payload: TemplatePayload,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    fields = [f.model_dump(exclude_none=True) for f in payload.fields]
    errors = validate_definition(fields, payload.target)
    if errors:
        raise HTTPException(422, {"message": "Template is not valid", "errors": errors})

    existing = (admin().table("document_templates").select("id")
                .eq("name", payload.name).execute().data)
    if existing:
        raise HTTPException(409, f"A template called '{payload.name}' already exists.")

    return admin().table("document_templates").insert({
        "name": payload.name,
        "description": payload.description,
        "target": payload.target,
        "fields": fields,
        "sample_path": payload.sample_path,
        "is_active": payload.is_active,
        "created_by": user.id,
    }).execute().data[0]


@router.put("/{template_id}")
def update_template(
    template_id: str,
    payload: TemplatePayload,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    res = (admin().table("document_templates").select("*")
           .eq("id", template_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Template not found")
    if res.data["is_builtin"]:
        raise HTTPException(
            409, "The built-in template cannot be edited. Duplicate it first."
        )

    fields = [f.model_dump(exclude_none=True) for f in payload.fields]
    errors = validate_definition(fields, payload.target)
    if errors:
        raise HTTPException(422, {"message": "Template is not valid", "errors": errors})

    return admin().table("document_templates").update({
        "name": payload.name,
        "description": payload.description,
        "target": payload.target,
        "fields": fields,
        "is_active": payload.is_active,
        "updated_at": "now()",
    }).eq("id", template_id).execute().data[0]


@router.post("/{template_id}/duplicate", status_code=status.HTTP_201_CREATED)
def duplicate_template(
    template_id: str,
    user: CurrentUser = Depends(require_admin),
) -> dict:
    res = (admin().table("document_templates").select("*")
           .eq("id", template_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Template not found")
    src = res.data

    base = f"{src['name']} (copy)"
    name, n = base, 1
    while admin().table("document_templates").select("id").eq("name", name).execute().data:
        n += 1
        name = f"{base} {n}"

    return admin().table("document_templates").insert({
        "name": name,
        "description": src["description"],
        "target": src["target"],
        "fields": src["fields"],
        "sample_path": src["sample_path"],
        "created_by": user.id,
    }).execute().data[0]


@router.delete("/{template_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_template(template_id: str, user: CurrentUser = Depends(require_admin)) -> None:
    res = (admin().table("document_templates").select("is_builtin")
           .eq("id", template_id).maybe_single().execute())
    if not res or not res.data:
        raise HTTPException(404, "Template not found")
    if res.data["is_builtin"]:
        raise HTTPException(409, "The built-in template cannot be deleted.")

    used = (admin().table("documents").select("id", count="exact")
            .eq("template_id", template_id).limit(1).execute().count or 0)
    if used:
        # Keep the audit trail: documents reference the template they were
        # read against, so retire it rather than breaking that link.
        admin().table("document_templates").update(
            {"is_active": False, "updated_at": "now()"}
        ).eq("id", template_id).execute()
        return

    admin().table("document_templates").delete().eq("id", template_id).execute()
