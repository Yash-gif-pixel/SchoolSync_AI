"""Business-rule validation of an extracted document.

Extraction says what is written on the paper. Validation says whether that can
be true. The two fail differently and both matter:

    "2nd"  -- extracted perfectly at high confidence, and still invalid if the
              school has no class 2.

A model can be fluently confident about an impossible value, so review must not
key off confidence alone. Every rule here is deterministic and explainable.

Rules come from each field's declared TYPE in the template, not from its name,
so a school's own form gets the same checks without anyone writing code for it.
Cross-field rules that only make sense for a particular target (age against
class, for instance) run only when the template has that target.
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Literal

from .people import resolve_person

# Grades this school runs. Mirrored in app/lib/core/school.dart.
MIN_GRADE, MAX_GRADE = 1, 10

Severity = Literal["error", "warning"]

# Below this, a field goes to human review regardless of what else passes.
CONFIDENCE_THRESHOLD = 0.85

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class Issue(dict):
    def __init__(
        self,
        field: str,
        severity: Severity,
        code: str,
        message: str,
        suggestion: str | None = None,
    ):
        super().__init__(
            field=field, severity=severity, code=code,
            message=message, suggestion=suggestion,
        )


def _digits(s: str | None) -> str:
    return re.sub(r"\D", "", s or "")


def _parse_iso(value: str | None) -> dt.date | None:
    try:
        return dt.date.fromisoformat((value or "").strip())
    except (ValueError, AttributeError):
        return None


def _age_on(born: dt.date, on: dt.date) -> int:
    return on.year - born.year - ((on.month, on.day) < (born.month, born.day))


def _swap_day_month(d: dt.date) -> dt.date | None:
    """The same digits read month-day instead of day-month, if that's a real
    date and not the same date back again."""
    if d.day > 12 or d.day == d.month:
        return None
    try:
        return dt.date(d.year, d.day, d.month)
    except ValueError:
        return None


# --------------------------------------------------------- per-type rules
def _check_field(spec: dict, f: dict, issues: list[Issue]) -> None:
    """Rules implied by one field's declared type."""
    key = spec["key"]
    label = spec.get("label", key)
    value = f.get("value")
    ftype = spec.get("type", "text")

    if not value:
        if spec.get("required"):
            issues.append(Issue(
                key, "error", "missing_required",
                f"{label} is missing"
                + ("." if f.get("present_on_form") else " — not present on this form.")
                + " It is required.",
                "Type it in manually.",
            ))
        else:
            issues.append(Issue(
                key, "warning", "missing_optional",
                f"{label} "
                + ("was left blank on the form."
                   if f.get("present_on_form") else "is not present on this form."),
            ))
        return

    if ftype == "phone":
        d = _digits(value)
        if len(d) != 10:
            issues.append(Issue(
                key, "error", "phone_invalid",
                f"{label}: {len(d)} digits — an Indian mobile number has 10.",
            ))
        elif d[0] not in "6789":
            issues.append(Issue(
                key, "error", "phone_invalid",
                f"{label}: starts with {d[0]} — Indian mobile numbers start "
                f"with 6, 7, 8 or 9.",
                "Looks like placeholder data rather than a real number.",
            ))

    elif ftype == "grade":
        if not value.isdigit():
            issues.append(Issue(
                key, "error", "grade_invalid", f"{label}: '{value}' is not a number."
            ))
        elif not (MIN_GRADE <= int(value) <= MAX_GRADE):
            issues.append(Issue(
                key, "error", "grade_out_of_range",
                f"Class {value} does not exist at this school "
                f"(grades {MIN_GRADE}–{MAX_GRADE} only).",
                f"Correct it to a grade between {MIN_GRADE} and {MAX_GRADE}, "
                f"or reject this application.",
            ))

    elif ftype == "number":
        if not value.replace(".", "", 1).lstrip("-").isdigit():
            issues.append(Issue(
                key, "error", "number_invalid", f"{label}: '{value}' is not a number."
            ))

    elif ftype == "email":
        if not EMAIL_RE.match(value.strip()):
            issues.append(Issue(
                key, "error", "email_invalid",
                f"{label}: '{value}' is not a valid email address.",
            ))

    elif ftype == "choice":
        options = spec.get("options") or []
        if options and value.strip() not in options:
            issues.append(Issue(
                key, "warning", "choice_unexpected",
                f"{label}: '{value}' is not one of {', '.join(options)}.",
                "Pick the closest option, or add it to the template.",
            ))

    elif ftype == "date":
        d = _parse_iso(value)
        if d is None:
            issues.append(Issue(
                key, "error", "date_invalid",
                f"{label}: '{value}' could not be read as a date.",
            ))
        elif d.year < 1900 or d.year > dt.date.today().year + 20:
            issues.append(Issue(
                key, "error", "date_invalid",
                f"{label}: {d:%d %b %Y} is outside any sensible range.",
            ))


# ----------------------------------------------- target-specific cross-checks
def _check_student(specs: dict, values: dict, fields: dict, issues: list[Issue]) -> None:
    """Rules that only make sense when the document enrols a pupil."""
    today = dt.date.today()

    dob_key = next((k for k, s in specs.items() if s.get("maps_to") == "date_of_birth"), None)
    grade_key = next((k for k, s in specs.items() if s.get("maps_to") == "__class"), None)
    adm_key = next((k for k, s in specs.items() if s.get("maps_to") == "admission_date"), None)

    dob = _parse_iso(values.get(dob_key)) if dob_key else None
    admission = _parse_iso(values.get(adm_key)) if adm_key else None
    grade_raw = values.get(grade_key) if grade_key else None
    grade = int(grade_raw) if (grade_raw or "").isdigit() else None

    if not dob or not dob_key:
        return

    if dob > today:
        issues.append(Issue(dob_key, "error", "date_future", "Date of birth is in the future."))
        return

    age = _age_on(dob, admission or today)
    if age < 3 or age > 25:
        issues.append(Issue(
            dob_key, "error", "age_implausible",
            f"Implies age {age}, outside any plausible school range.",
        ))
        return

    if grade is None:
        return

    # Indian norm: a child is roughly grade + 5 years old.
    expected = grade + 5
    if abs(age - expected) <= 2:
        return

    # Day-month is the house convention, so 10/03/2014 is simply 10 March and
    # deserves no comment. Warning on every such date fires on nearly every
    # Indian form and trains reviewers to click through. Raise it only when the
    # age is already wrong AND swapping would fix it — then the swap is a
    # likely explanation worth offering.
    swapped = _swap_day_month(dob)
    swapped_age = _age_on(swapped, admission or today) if swapped else None
    if swapped_age is not None and abs(swapped_age - expected) <= 2:
        issues.append(Issue(
            dob_key, "warning", "date_ambiguous",
            f"Read as {dob:%d %b %Y} (day-month), giving age {age}, which is "
            f"unusual for class {grade}. Read as month-day it would be "
            f"{swapped:%d %b %Y}, age {swapped_age}.",
            "Check the photo and correct it if the order is reversed.",
        ))
    else:
        issues.append(Issue(
            dob_key, "warning", "age_implausible",
            f"Age {age} is unusual for class {grade} (typically around {expected}).",
            "Check whether the year of birth was misread.",
        ))


def _check_leave(
    specs: dict,
    values: dict,
    issues: list[Issue],
    context: dict | None = None,
) -> None:
    from_key = next((k for k, s in specs.items() if s.get("maps_to") == "from_date"), None)
    to_key = next((k for k, s in specs.items() if s.get("maps_to") == "to_date"), None)
    who_key = next((k for k, s in specs.items() if s.get("maps_to") == "__teacher"), None)

    if from_key and to_key:
        start, end = _parse_iso(values.get(from_key)), _parse_iso(values.get(to_key))
        if start and end and end < start:
            issues.append(Issue(
                to_key, "error", "date_range_invalid",
                f"Leave ends {end:%d %b %Y}, before it starts ({start:%d %b %Y}).",
            ))
        if start and start < dt.date.today() - dt.timedelta(days=90):
            issues.append(Issue(
                from_key, "warning", "date_stale",
                f"This leave started {start:%d %b %Y}, over three months ago.",
                "Check the year was read correctly.",
            ))

    # Whose leave is it? Resolve the written name against the staff list here,
    # so the reviewer finds out on screen rather than on a failed commit.
    staff = (context or {}).get("teachers")
    if who_key and staff is not None:
        written = values.get(who_key)
        match = resolve_person(written, staff)
        if not written:
            pass  # already reported as a missing required field
        elif not match.ok:
            names = ", ".join(c["full_name"] for c in match.candidates)
            if match.reason == "ambiguous":
                issues.append(Issue(
                    who_key, "error", "teacher_ambiguous",
                    f"'{written}' matches more than one member of staff: {names}.",
                    "Type the full name exactly as it appears in the staff list.",
                ))
            else:
                issues.append(Issue(
                    who_key, "error", "teacher_unknown",
                    f"No member of staff called '{written}'."
                    + (f" Did you mean {names}?" if names else ""),
                    "Correct the spelling, or check the note is for this school.",
                ))
        elif match.reason == "unique_partial":
            issues.append(Issue(
                who_key, "warning", "teacher_inferred",
                f"'{written}' read as {match.resolved_name}.",
                "Confirm this is the right person before approving.",
            ))


# --------------------------------------------------------------- entry point
def validate(extraction: dict, template: dict, context: dict | None = None) -> dict:
    """Annotate an extraction with issues and a review verdict.

    `context` carries anything a rule needs from the database — currently
    `teachers`, so a leave note's name can be resolved against real staff.
    Passed in rather than queried so this module stays pure and testable.
    """
    specs = {f["key"]: f for f in template.get("fields", [])}
    fields = {f["field"]: f for f in extraction.get("fields", []) if f.get("field") in specs}
    values = {k: (f.get("value") or None) for k, f in fields.items()}
    issues: list[Issue] = []

    # A field the model omitted entirely is treated as absent, so a truncated
    # response still produces a truthful review screen rather than silence.
    for key, spec in specs.items():
        if key not in fields:
            fields[key] = {
                "field": key, "value": None, "raw_text": None,
                "present_on_form": False, "confidence": 0.0,
                "note": "The extractor returned nothing for this field.",
            }
            extraction.setdefault("fields", []).append(fields[key])

    for key, spec in specs.items():
        _check_field(spec, fields[key], issues)

    target = template.get("target", "data_only")
    if target == "student":
        _check_student(specs, values, fields, issues)
    elif target == "leave_request":
        _check_leave(specs, values, issues, context)

    if not extraction.get("matches_template", True):
        issues.append(Issue(
            "_document", "error", "wrong_document",
            f"This does not look like a {template.get('name', 'matching document')}.",
            "Pick a different template, or rephotograph the right form.",
        ))

    flagged = {i["field"] for i in issues}

    # Low confidence, and anything the model itself called out. Only for fields
    # nothing else has flagged, so each concern appears once — a screen full of
    # duplicate warnings gets accepted blindly.
    for key, f in fields.items():
        if key in flagged or not f.get("present_on_form"):
            continue
        note = f.get("note")
        if f.get("value") and f.get("confidence", 1.0) < CONFIDENCE_THRESHOLD:
            issues.append(Issue(
                key, "warning", "low_confidence",
                f"Low confidence ({f['confidence']:.0%})" + (f" — {note}" if note else ""),
                "Check this against the photo.",
            ))
        elif note:
            issues.append(Issue(key, "warning", "model_note", note))

    if extraction.get("document_quality") == "poor":
        issues.append(Issue(
            "_document", "warning", "poor_quality",
            f"Poor image quality — {extraction.get('quality_note') or 'check every field'}.",
            "Consider rephotographing the form.",
        ))

    # Belt and braces: collapse any exact (field, code) repeats.
    seen: set[tuple[str, str]] = set()
    deduped: list[Issue] = []
    for i in issues:
        pair = (i["field"], i["code"])
        if pair not in seen:
            seen.add(pair)
            deduped.append(i)
    issues = deduped

    errors = [i for i in issues if i["severity"] == "error"]
    return {
        **extraction,
        "issues": issues,
        "error_count": len(errors),
        "warning_count": len(issues) - len(errors),
        # Auto-commit only when nothing at all was flagged; any warning still
        # deserves a human glance before a record is created.
        "can_auto_commit": not issues,
        "needs_review": bool(issues),
    }
