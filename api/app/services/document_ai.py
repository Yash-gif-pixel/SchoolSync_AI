"""Gemini-backed document extraction, driven entirely by a template.

Two operations:

  discover_template  — look at a blank (or filled) form and propose the field
                       schema it implies, so a school can onboard its own
                       paperwork without anyone writing code.
  extract            — read a filled form against a saved template.

The model is not admission-form-specific and never was; the field list comes
from the template, and the response schema is built from it at run time.

Design notes:

* Structured output via a response schema, not OCR + regex. Tesseract and
  PaddleOCR do badly on handwritten Indian forms; a VLM reads corrections in
  context.
* Every field carries `present_on_form` separately from `confidence`, because
  "this line isn't on the paper" and "this line is here but unreadable" need
  different treatment in review.
* Self-reported confidence is directional, not calibrated. It says where a
  human should look. Objective checks live in validation.py.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache

from google import genai
from google.genai import types

from ..config import get_settings
from .templates import (
    DISCOVERY_PROMPT,
    DISCOVERY_SCHEMA,
    prompt_for,
    response_schema_for,
)

log = logging.getLogger(__name__)

# Free-tier quota is per model per day, and it is TIGHT — gemini-3.6-flash
# allows only 20 requests/day. One afternoon of testing exhausts it, and a
# demo that dies on a 429 is worse than a slightly weaker model.
#
# So: an ordered chain rather than a single pin. On a quota error we move to
# the next model, which has its own separate allowance. Models are pinned by
# version rather than using the `gemini-flash-latest` alias, because an alias
# can shift under a demo.
MODEL_CHAIN = [
    "gemini-3.5-flash",        # primary: strong on handwriting
    "gemini-3.6-flash",        # newest, but only 20/day free
    "gemini-3.1-flash-lite",   # lighter, larger allowance
    "gemini-2.0-flash",        # last resort, still handles vision + schemas
]

#: The model that served the most recent call, for reporting.
MODEL = MODEL_CHAIN[0]


class AllModelsExhausted(RuntimeError):
    """Every model in the chain returned a quota error."""


def _is_quota_error(e: Exception) -> bool:
    text = str(e)
    return "RESOURCE_EXHAUSTED" in text or "429" in text


@lru_cache
def _client() -> genai.Client:
    """Cached: a fresh Client per call gets garbage-collected mid-request,
    which closes its transport and raises 'client has been closed'."""
    key = get_settings().gemini_api_key
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set in api/.env")
    return genai.Client(api_key=key)


def _generate(image_bytes: bytes, mime_type: str, prompt: str, schema: dict) -> tuple[dict, str]:
    """Run the prompt, falling through the chain on quota errors.

    Returns (parsed_json, model_that_answered).
    """
    contents = [
        types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
        prompt,
    ]
    config = types.GenerateContentConfig(
        response_mime_type="application/json",
        response_schema=schema,
        temperature=0.0,
    )

    tried: list[str] = []
    for model in MODEL_CHAIN:
        try:
            resp = _client().models.generate_content(
                model=model, contents=contents, config=config
            )
            return json.loads(resp.text), model
        except Exception as e:
            if not _is_quota_error(e):
                raise
            tried.append(model)
            log.warning("Quota exhausted on %s, falling back", model)

    raise AllModelsExhausted(
        "Gemini free-tier quota is exhausted on every configured model "
        f"({', '.join(tried)}). It resets daily — or add billing to the "
        "Google AI Studio project for higher limits."
    )


def discover_template(image_bytes: bytes, mime_type: str = "image/jpeg") -> dict:
    """Propose a template from a photograph of a form.

    Returns {document_kind, suggested_name, suggested_target, fields[]}. The
    result is a proposal for a human to edit, never saved directly.
    """
    out, model = _generate(image_bytes, mime_type, DISCOVERY_PROMPT, DISCOVERY_SCHEMA)
    is_student = out.get("suggested_target") == "student"

    for f in out.get("fields", []):
        # maps_to is only meaningful for student templates; normalise the
        # empty-string case so the client sees a clean null.
        if not is_student or not (f.get("maps_to") or "").strip():
            f["maps_to"] = None

        options = [o for o in (f.get("options") or []) if o and o.strip()]
        if f.get("type") == "choice" and not options:
            # A choice with no allowed answers is an invalid template. The
            # prompt asks for them, but never hand back a proposal the admin
            # has to repair before it will save — fall back to free text and
            # let them switch it back if they want the constraint.
            f["type"] = "text"
            f["options"] = None
        else:
            f["options"] = options or None

    out["_model"] = model
    return out


def extract(image_bytes: bytes, template: dict, mime_type: str = "image/jpeg") -> dict:
    """Read a filled form against a saved template."""
    out, model = _generate(
        image_bytes,
        mime_type,
        prompt_for(template),
        response_schema_for(template["fields"]),
    )
    out["_model"] = model
    out["_template_id"] = template.get("id")
    out["_template_name"] = template.get("name")
    return out
