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

# Free-tier quota is per model per day, and it is TIGHT — the newest flash
# model allows only 20 requests/day. One afternoon of testing exhausts it, and
# a demo that dies on a 429 is worse than a slightly weaker model.
#
# So: an ordered chain rather than a single pin. On a quota error we move to
# the next model, which has its own separate allowance. Models are pinned by
# version rather than using the `gemini-flash-latest` alias, because an alias
# can shift under a demo.
#
# Every entry must be a CURRENT vision model. Google retires tags — the 2.0
# generation was shut down, and a chain whose last resort is a dead tag has no
# last resort at all; it just spends a round trip discovering that. Overridable
# with GEMINI_MODELS (comma-separated) so the next retirement is a config
# change rather than a deploy.
DEFAULT_MODEL_CHAIN = [
    "gemini-3.5-flash",        # primary: strong on handwriting
    "gemini-3.6-flash",        # newer generation, tighter free allowance
    "gemini-3.1-flash-lite",   # lighter, larger allowance
    "gemini-2.5-flash",        # last resort, still current and reads images
]


def _model_chain() -> list[str]:
    override = get_settings().gemini_models
    return override or DEFAULT_MODEL_CHAIN


#: Kept as a module attribute because tests and the README refer to it.
MODEL_CHAIN = DEFAULT_MODEL_CHAIN


class AllModelsExhausted(RuntimeError):
    """No model in the chain could be reached."""


def _is_quota_error(e: Exception) -> bool:
    text = str(e)
    return "RESOURCE_EXHAUSTED" in text or "429" in text


def _is_missing_model(e: Exception) -> bool:
    """A tag this project knows about that Google no longer serves.

    Worth distinguishing from a quota error even though both fall through to
    the next model: a retired tag never comes back, so it is logged loudly
    enough to get the list edited, whereas a 429 resets at midnight.
    """
    text = str(e)
    return "NOT_FOUND" in text or "404" in text or "is not found for API version" in text


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

    chain = _model_chain()
    exhausted: list[str] = []
    retired: list[str] = []

    for model in chain:
        try:
            resp = _client().models.generate_content(
                model=model, contents=contents, config=config
            )
            return json.loads(resp.text), model
        except Exception as e:
            if _is_quota_error(e):
                exhausted.append(model)
                log.warning("Quota exhausted on %s, falling back", model)
            elif _is_missing_model(e):
                retired.append(model)
                log.error(
                    "Model %s no longer exists — remove it from the chain in "
                    "document_ai.py or set GEMINI_MODELS", model,
                )
            else:
                # A bad image, a malformed schema, a network failure: real
                # errors that the next model would fail on identically. Falling
                # through would turn one clear message into four round trips
                # and a misleading "quota exhausted".
                raise

    detail = []
    if exhausted:
        detail.append(
            f"quota exhausted on {', '.join(exhausted)} (it resets daily, or "
            f"add billing to the Google AI Studio project for higher limits)"
        )
    if retired:
        detail.append(
            f"{', '.join(retired)} no longer exist — update MODEL_CHAIN in "
            f"api/app/services/document_ai.py, or set GEMINI_MODELS"
        )
    raise AllModelsExhausted(
        "No Gemini model could read this document: " + "; ".join(detail) + "."
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
