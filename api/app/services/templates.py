"""Document templates: the field list a school defines for its own forms.

A template is the single source of truth for one document type. Extraction
builds its Gemini response schema from it at run time, validation derives its
rules from each field's declared type, and commit routes the result by the
template's target. Nothing about "admission form" is hardcoded any more.
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------- types
# Each type carries an extraction instruction and implies validation rules.
FIELD_TYPES: dict[str, dict[str, str]] = {
    "text": {
        "label": "Text",
        "hint": "Copy as written, correcting only obvious letter shapes.",
    },
    "longtext": {
        "label": "Long text",
        "hint": "May run over several lines; join them with single spaces.",
    },
    "date": {
        "label": "Date",
        "hint": (
            "Return ISO YYYY-MM-DD. Dates on these forms are written "
            "DAY-MONTH-YEAR, so 10/03/2014 is 10 March 2014. That is the house "
            "convention, not a guess: do not lower confidence merely because "
            "the day is 12 or less."
        ),
    },
    "number": {"label": "Number", "hint": "Digits only."},
    "phone": {
        "label": "Phone",
        "hint": "Digits only, no spaces or punctuation.",
    },
    "email": {"label": "Email", "hint": "Lowercase, no spaces."},
    "choice": {
        "label": "Choice",
        "hint": "Must be exactly one of the listed options.",
    },
    "grade": {
        "label": "Class / grade",
        "hint": "Digits only: '8th' -> '8', 'IX' -> '9'. Report what is "
                "written even if it looks wrong for the school.",
    },
}

TARGETS = {
    "student": "Creates a student record",
    "leave_request": "Creates a leave request",
    "data_only": "Stored as extracted data, no domain record",
}

# Columns a template may write to, per target. `__class` is special: it is a
# grade number that gets resolved to a class_id at commit time.
TARGET_COLUMNS: dict[str, set[str]] = {
    "student": {
        "full_name", "date_of_birth", "gender", "guardian_name",
        "guardian_phone", "address", "previous_school", "admission_date",
        "roll_no", "photo_url", "__class",
    },
    "leave_request": {"from_date", "to_date", "reason", "__teacher"},
    "data_only": set(),
}


# ------------------------------------------------------- definition checks
def validate_definition(fields: Any, target: str) -> list[str]:
    """Structural problems with a template's field list, as plain sentences."""
    errors: list[str] = []

    if not isinstance(fields, list) or not fields:
        return ["A template needs at least one field."]

    if target not in TARGETS:
        errors.append(f"Unknown target '{target}'.")

    seen: set[str] = set()
    for i, f in enumerate(fields, 1):
        where = f"Field {i}"
        if not isinstance(f, dict):
            errors.append(f"{where} is not an object.")
            continue

        key = (f.get("key") or "").strip()
        if not key:
            errors.append(f"{where} has no key.")
        elif not key.replace("_", "").isalnum():
            errors.append(f"{where}: key '{key}' may only contain letters, digits and underscores.")
        elif key in seen:
            errors.append(f"Duplicate key '{key}'.")
        else:
            seen.add(key)

        if not (f.get("label") or "").strip():
            errors.append(f"{where} ('{key}') has no label.")

        ftype = f.get("type")
        if ftype not in FIELD_TYPES:
            errors.append(f"{where} ('{key}') has unknown type '{ftype}'.")

        if ftype == "choice" and not f.get("options"):
            errors.append(f"{where} ('{key}') is a choice field but lists no options.")

        maps_to = f.get("maps_to")
        if maps_to:
            allowed = TARGET_COLUMNS.get(target, set())
            if maps_to not in allowed:
                errors.append(
                    f"{where} ('{key}') maps to '{maps_to}', which is not a "
                    f"field of a {target} record."
                )

    mapped = {f.get("maps_to") for f in fields if isinstance(f, dict)}
    required_by_target = {
        "student": (
            ("full_name", "a student needs a name"),
            ("__class", "a student must be placed in a class"),
        ),
        "leave_request": (
            ("from_date", "leave needs a start date"),
            ("to_date", "leave needs an end date"),
        ),
    }
    for needed, why in required_by_target.get(target, ()):
        if needed not in mapped:
            errors.append(
                f"No field maps to {needed} — {why}. "
                f"Set one field's destination accordingly."
            )

    return errors


# ------------------------------------------------------- extraction schema
def response_schema_for(fields: list[dict]) -> dict:
    """The JSON schema Gemini must fill in for this template."""
    return {
        "type": "object",
        "properties": {
            "matches_template": {
                "type": "boolean",
                "description": "False if this image is not the kind of document the template describes.",
            },
            "document_quality": {"type": "string", "enum": ["good", "fair", "poor"]},
            "quality_note": {"type": "string", "nullable": True},
            "fields": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "field": {"type": "string", "enum": [f["key"] for f in fields]},
                        "value": {"type": "string", "nullable": True},
                        "raw_text": {"type": "string", "nullable": True},
                        "present_on_form": {"type": "boolean"},
                        "confidence": {"type": "number"},
                        "note": {"type": "string", "nullable": True},
                    },
                    "required": [
                        "field", "value", "raw_text",
                        "present_on_form", "confidence", "note",
                    ],
                },
            },
        },
        "required": ["matches_template", "document_quality", "quality_note", "fields"],
    }


def prompt_for(template: dict) -> str:
    """Extraction instructions assembled from the template's own field list."""
    lines: list[str] = []
    for f in template["fields"]:
        bits = [f"- {f['key']} — \"{f['label']}\" ({FIELD_TYPES[f['type']]['label']})"]
        bits.append(f"    {FIELD_TYPES[f['type']]['hint']}")
        if f["type"] == "choice" and f.get("options"):
            bits.append(f"    Options: {', '.join(f['options'])}")
        if f.get("description"):
            bits.append(f"    {f['description']}")
        lines.append("\n".join(bits))
    field_block = "\n".join(lines)

    return f"""\
You are reading a filled-in "{template['name']}" from an Indian school.

Extract exactly these fields, returning one entry per field even when the
field is absent from the page:

{field_block}

Rules:

1. ONLY read the form that is the main subject of the photo. These pages are
   often photographed in an open notebook, so a DIFFERENT form on the facing
   page may be partly visible at the edge, and writing from the reverse side
   often bleeds through. Ignore both. Never merge values across pages.

2. Distinguish two different kinds of "no value":
   - The field's label is not on this form at all
       -> present_on_form = false, value = null, confidence = 1.0
   - The label is there but the answer is blank, smudged or illegible
       -> present_on_form = true, value = null, low confidence, explain in note

3. Corrections: if a value is struck through and rewritten, take the
   CORRECTION, not the original, and say so in note.

4. Put the normalised value in `value` and what is literally written in
   `raw_text`.

5. Set confidence per field on how legible THAT field is. A neat field on a
   badly lit page can still score high. An overwritten or guessed value must
   score below 0.6.

6. Set matches_template to false if this is clearly not a {template['name']}.

Report what is on the paper. Do not correct implausible values and do not
invent anything that is not written."""


# ------------------------------------------------------------- discovery
DISCOVERY_SCHEMA = {
    "type": "object",
    "properties": {
        "document_kind": {"type": "string"},
        "suggested_name": {"type": "string"},
        "suggested_target": {
            "type": "string",
            "enum": ["student", "leave_request", "data_only"],
        },
        "fields": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "key": {"type": "string"},
                    "label": {"type": "string"},
                    "type": {"type": "string", "enum": list(FIELD_TYPES)},
                    "required": {"type": "boolean"},
                    "maps_to": {"type": "string", "nullable": True},
                    # Required in the schema so a `choice` field never comes
                    # back without its allowed answers — a choice with no
                    # options is an invalid template the admin would have to
                    # repair by hand.
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                        "nullable": True,
                    },
                },
                "required": ["key", "label", "type", "required", "maps_to", "options"],
            },
        },
    },
    "required": ["document_kind", "suggested_name", "suggested_target", "fields"],
}

DISCOVERY_PROMPT = f"""\
Look at this school document. Do not assume what kind of document it is.

Identify every field it asks for — the printed or handwritten LABELS, not the
answers. The page may be blank, or already filled in; either way describe the
FIELDS, never the values.

For each field give:
  key       snake_case identifier, letters/digits/underscores only
  label     the label as it appears on the page, spelling and all
  type      one of: {', '.join(FIELD_TYPES)}
  required  true only if the document is unusable without it
  maps_to   see below, or null
  options   ONLY for type "choice": the allowed answers. Never leave this
            empty for a choice field — a choice with no options is unusable.
            Use the answers printed on the form if it lists them; otherwise
            the conventional set (Gender -> ["M", "F"]). Null for every
            other type.

Type guidance:
  - a class or standard the pupil is entering  -> grade
  - any date                                    -> date
  - a contact number                            -> phone
  - something with a small fixed set of answers -> choice
  - a multi-line address or remarks             -> longtext

Then choose suggested_target:
  student        the document enrols or registers a pupil
  leave_request  the document requests leave or absence
  data_only      anything else (mark sheet, fee receipt, transfer certificate)

maps_to only applies when suggested_target is "student"; otherwise null.
Allowed values, or null if nothing fits:
  full_name, date_of_birth, gender, guardian_name, guardian_phone,
  address, previous_school, admission_date, roll_no,
  __class   (use for the class/grade being applied for)

Ignore page furniture: headings, school name, logos, signature lines,
"for office use" boxes, and any form visible on a facing page."""
