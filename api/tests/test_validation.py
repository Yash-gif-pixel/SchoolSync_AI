"""Validation rules, tested without touching Gemini or the database.

Cases are drawn from the three real sample forms, so a regression here means a
regression on the actual demo material.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.validation import validate  # noqa: E402

# Mirrors the built-in admission template from db/003_templates.sql.
ADMISSION_FIELDS = [
    {"key": "full_name", "label": "Student Name", "type": "text",
     "required": True, "maps_to": "full_name"},
    {"key": "date_of_birth", "label": "Date of Birth", "type": "date",
     "required": True, "maps_to": "date_of_birth"},
    {"key": "gender", "label": "Gender", "type": "choice",
     "required": False, "maps_to": "gender", "options": ["M", "F"]},
    {"key": "class_applying_for", "label": "Class Applying For", "type": "grade",
     "required": True, "maps_to": "__class"},
    {"key": "guardian_name", "label": "Guardian Name", "type": "text",
     "required": True, "maps_to": "guardian_name"},
    {"key": "guardian_phone", "label": "Guardian Phone", "type": "phone",
     "required": False, "maps_to": "guardian_phone"},
    {"key": "address", "label": "Address", "type": "longtext",
     "required": False, "maps_to": "address"},
    {"key": "previous_school", "label": "Previous School", "type": "text",
     "required": False, "maps_to": "previous_school"},
    {"key": "admission_date", "label": "Date of Admission", "type": "date",
     "required": False, "maps_to": "admission_date"},
]


def template(target: str = "student", fields=None) -> dict:
    return {
        "id": "tpl-1",
        "name": "Example Admission Form",
        "target": target,
        "fields": fields if fields is not None else ADMISSION_FIELDS,
    }


def field(name, value, *, present=True, conf=0.98, raw=None, note=None):
    return {
        "field": name,
        "value": value,
        "raw_text": raw if raw is not None else value,
        "present_on_form": present,
        "confidence": conf,
        "note": note,
    }


def form(**overrides):
    """A clean, valid admission form; override individual fields per test."""
    today = dt.date.today()
    base = {
        "full_name": field("full_name", "Aarav Sharma"),
        "date_of_birth": field("date_of_birth", f"{today.year - 14}-03-22", raw="22-03-2011"),
        "gender": field("gender", "M"),
        "class_applying_for": field("class_applying_for", "9"),
        "guardian_name": field("guardian_name", "Rajesh Sharma"),
        "guardian_phone": field("guardian_phone", "9866421801"),
        "address": field("address", "14, Sector 22"),
        "previous_school": field("previous_school", "St Xavier's"),
        "admission_date": field("admission_date", f"{today.year}-04-22", raw="22-04-2026"),
    }
    base.update(overrides)
    return {
        "matches_template": True,
        "document_quality": "good",
        "quality_note": None,
        "fields": list(base.values()),
    }


def codes(result, severity=None):
    return {
        i["code"] for i in result["issues"]
        if severity is None or i["severity"] == severity
    }


class TestCleanForm:
    def test_no_issues_and_auto_committable(self):
        r = validate(form(), template())
        assert r["issues"] == [], [i["message"] for i in r["issues"]]
        assert r["can_auto_commit"] is True
        assert r["needs_review"] is False


class TestGradeType:
    """A `grade` field is checked against the grades the school runs (1-10),
    however cleanly it was extracted."""

    @pytest.mark.parametrize("grade", [str(g) for g in range(1, 11)])
    def test_every_grade_the_school_runs_is_accepted(self, grade):
        dob = f"{dt.date.today().year - (int(grade) + 5)}-03-22"
        r = validate(form(
            class_applying_for=field("class_applying_for", grade),
            date_of_birth=field("date_of_birth", dob, raw="22-03-2011"),
        ), template())
        assert "grade_out_of_range" not in codes(r)

    @pytest.mark.parametrize("grade", ["0", "11", "12", "14"])
    def test_grades_outside_the_school_are_errors(self, grade):
        r = validate(form(class_applying_for=field("class_applying_for", grade)), template())
        assert "grade_out_of_range" in codes(r, "error")
        assert r["can_auto_commit"] is False

    def test_non_numeric_grade_is_an_error(self):
        r = validate(form(class_applying_for=field("class_applying_for", "nine")), template())
        assert "grade_invalid" in codes(r, "error")


class TestPhoneType:
    def test_placeholder_number_is_rejected(self):
        """Yash Singh's form: 1234568911 is well-formed but not a real mobile."""
        r = validate(form(guardian_phone=field("guardian_phone", "1234568911")), template())
        assert "phone_invalid" in codes(r, "error")

    def test_wrong_length_is_rejected(self):
        r = validate(form(guardian_phone=field("guardian_phone", "98664218")), template())
        assert "phone_invalid" in codes(r, "error")

    @pytest.mark.parametrize("num", ["9866421801", "7012345678", "6123456789"])
    def test_valid_indian_mobiles_pass(self, num):
        r = validate(form(guardian_phone=field("guardian_phone", num)), template())
        assert "phone_invalid" not in codes(r)

    def test_absent_phone_is_a_warning_not_an_error(self):
        """K. Radha's form has no phone line at all."""
        r = validate(form(
            guardian_phone=field("guardian_phone", None, present=False, conf=1.0)
        ), template())
        assert "missing_optional" in codes(r, "warning")
        assert codes(r, "error") == set()


class TestRequiredFields:
    @pytest.mark.parametrize(
        "name", ["full_name", "date_of_birth", "class_applying_for", "guardian_name"]
    )
    def test_missing_required_field_is_an_error(self, name):
        r = validate(form(**{name: field(name, None, conf=0.2)}), template())
        assert "missing_required" in codes(r, "error")

    def test_absent_address_is_only_a_warning(self):
        """Manjeet's form has no address line."""
        r = validate(form(address=field("address", None, present=False, conf=1.0)), template())
        assert "missing_optional" in codes(r, "warning")
        assert codes(r, "error") == set()

    def test_required_is_driven_by_the_template_not_the_field_name(self):
        """The same field is optional if the school's template says so."""
        relaxed = [
            {**f, "required": False} if f["key"] == "guardian_name" else f
            for f in ADMISSION_FIELDS
        ]
        r = validate(
            form(guardian_name=field("guardian_name", None, conf=0.2)),
            template(fields=relaxed),
        )
        assert "missing_required" not in codes(r)
        assert "missing_optional" in codes(r, "warning")


class TestDates:
    def test_impossible_age_is_an_error(self):
        r = validate(form(
            date_of_birth=field("date_of_birth", "1960-04-09", raw="09-04-1960")
        ), template())
        assert "age_implausible" in codes(r, "error")

    def test_future_date_of_birth_is_an_error(self):
        future = dt.date.today() + dt.timedelta(days=400)
        r = validate(form(
            date_of_birth=field("date_of_birth", future.isoformat(), raw="22-03-2028")
        ), template())
        assert "date_future" in codes(r, "error")

    def test_unparseable_date_is_an_error(self):
        r = validate(form(
            date_of_birth=field("date_of_birth", "not-a-date", raw="scribble")
        ), template())
        assert "date_invalid" in codes(r, "error")

    def test_age_far_from_grade_norm_is_warned(self):
        """Yash Singh: born 2007, applying for class 9 -> age 19."""
        r = validate(form(
            date_of_birth=field("date_of_birth", "2007-04-09", raw="09:04:2007"),
            class_applying_for=field("class_applying_for", "9"),
        ), template())
        assert "age_implausible" in codes(r, "warning")


class TestDayMonthOrder:
    """Day-month is the house convention, so a normal date gets no comment.
    The order is only questioned when it would explain an age that is already
    wrong — otherwise every Indian form carries a warning nobody reads."""

    def test_ordinary_ambiguous_looking_date_is_silent(self):
        year = dt.date.today().year - 14
        r = validate(form(
            date_of_birth=field("date_of_birth", f"{year}-03-05", raw="05/03/2011"),
            class_applying_for=field("class_applying_for", "9"),
        ), template())
        assert "date_ambiguous" not in codes(r)
        assert "age_implausible" not in codes(r)

    def test_never_both_age_and_swap_warnings(self):
        r = validate(form(
            date_of_birth=field("date_of_birth", "2007-04-09", raw="09/04/2007"),
            class_applying_for=field("class_applying_for", "9"),
        ), template())
        dob_codes = [i["code"] for i in r["issues"] if i["field"] == "date_of_birth"]
        assert not ("age_implausible" in dob_codes and "date_ambiguous" in dob_codes)

    def test_day_over_12_can_never_be_swapped(self):
        r = validate(form(
            date_of_birth=field("date_of_birth", "1999-03-22", raw="22/03/1999"),
            class_applying_for=field("class_applying_for", "9"),
        ), template())
        assert "date_ambiguous" not in codes(r)

    def test_strikethrough_note_still_reaches_the_reviewer(self):
        """Manjeet's DOB: 1979 struck out, 2014 written above."""
        age = dt.date.today().year - 2014
        r = validate(form(
            date_of_birth=field(
                "date_of_birth", "2014-03-10", raw="10|03|1979 2014", conf=0.80,
                note="1979 struck out, 2014 written above.",
            ),
            class_applying_for=field("class_applying_for", str(max(1, age - 5))),
        ), template())
        assert any("struck out" in i["message"] for i in r["issues"]), \
            [i["message"] for i in r["issues"]]


class TestChoiceAndEmailTypes:
    def test_value_outside_the_options_is_warned(self):
        r = validate(form(gender=field("gender", "Male")), template())
        assert "choice_unexpected" in codes(r, "warning")

    def test_listed_option_passes(self):
        r = validate(form(gender=field("gender", "F")), template())
        assert "choice_unexpected" not in codes(r)

    def test_bad_email_is_an_error(self):
        fields = ADMISSION_FIELDS + [
            {"key": "email", "label": "Email", "type": "email", "required": False}
        ]
        ex = form()
        ex["fields"].append(field("email", "not-an-email"))
        r = validate(ex, template(fields=fields))
        assert "email_invalid" in codes(r, "error")


class TestArbitraryTemplates:
    """The whole point of templates: a school's own form, with no admission
    semantics, still gets type-driven checks."""

    FEE_RECEIPT = [
        {"key": "receipt_no", "label": "Receipt No", "type": "number", "required": True},
        {"key": "paid_on", "label": "Date", "type": "date", "required": True},
        {"key": "amount", "label": "Amount", "type": "number", "required": True},
        {"key": "payer_phone", "label": "Phone", "type": "phone", "required": False},
    ]

    def _receipt(self, **over):
        base = {
            "receipt_no": field("receipt_no", "10432"),
            "paid_on": field("paid_on", "2026-04-10", raw="10/04/2026"),
            "amount": field("amount", "4500"),
            "payer_phone": field("payer_phone", "9866421801"),
        }
        base.update(over)
        return {
            "matches_template": True,
            "document_quality": "good",
            "quality_note": None,
            "fields": list(base.values()),
        }

    def test_clean_non_admission_document_passes(self):
        r = validate(self._receipt(), template("data_only", self.FEE_RECEIPT))
        assert r["issues"] == [], [i["message"] for i in r["issues"]]

    def test_type_rules_still_apply_without_admission_semantics(self):
        r = validate(
            self._receipt(
                amount=field("amount", "four thousand"),
                payer_phone=field("payer_phone", "12345"),
            ),
            template("data_only", self.FEE_RECEIPT),
        )
        assert "number_invalid" in codes(r, "error")
        assert "phone_invalid" in codes(r, "error")

    def test_no_age_or_grade_checks_run_for_data_only(self):
        r = validate(
            self._receipt(paid_on=field("paid_on", "1995-04-10", raw="10/04/1995")),
            template("data_only", self.FEE_RECEIPT),
        )
        assert "age_implausible" not in codes(r)
        assert "grade_out_of_range" not in codes(r)

    def test_leave_request_end_before_start_is_an_error(self):
        fields = [
            {"key": "from_d", "label": "From", "type": "date",
             "required": True, "maps_to": "from_date"},
            {"key": "to_d", "label": "To", "type": "date",
             "required": True, "maps_to": "to_date"},
            {"key": "why", "label": "Reason", "type": "longtext",
             "required": False, "maps_to": "reason"},
        ]
        ex = {
            "matches_template": True,
            "document_quality": "good",
            "quality_note": None,
            "fields": [
                field("from_d", "2026-05-10", raw="10/05/2026"),
                field("to_d", "2026-05-02", raw="02/05/2026"),
                field("why", "Medical"),
            ],
        }
        r = validate(ex, template("leave_request", fields))
        assert "date_range_invalid" in codes(r, "error")


class TestRobustness:
    def test_field_omitted_by_the_model_is_treated_as_absent(self):
        ex = form()
        ex["fields"] = [f for f in ex["fields"] if f["field"] != "previous_school"]
        r = validate(ex, template())
        assert any(f["field"] == "previous_school" for f in r["fields"])
        assert "missing_optional" in codes(r, "warning")

    def test_wrong_document_for_the_template_is_an_error(self):
        ex = form()
        ex["matches_template"] = False
        r = validate(ex, template())
        assert "wrong_document" in codes(r, "error")

    def test_extra_field_not_in_the_template_is_ignored(self):
        ex = form()
        ex["fields"].append(field("blood_group", "O+"))
        r = validate(ex, template())
        assert not any(i["field"] == "blood_group" for i in r["issues"])


class TestDeduplication:
    def test_one_issue_per_field_per_concern(self):
        year = dt.date.today().year - 14
        r = validate(form(
            date_of_birth=field(
                "date_of_birth", f"{year}-03-05", raw="05|03|2011", conf=0.60,
                note="Digits are smudged.",
            )
        ), template())
        pairs = [(i["field"], i["code"]) for i in r["issues"]]
        assert len(pairs) == len(set(pairs))

    def test_low_confidence_suppressed_when_field_already_flagged(self):
        r = validate(form(
            class_applying_for=field("class_applying_for", "12", conf=0.30),
        ), template())
        cls_codes = [i["code"] for i in r["issues"] if i["field"] == "class_applying_for"]
        assert cls_codes == ["grade_out_of_range"]

    def test_low_confidence_reported_when_nothing_else_flagged(self):
        r = validate(form(
            previous_school=field("previous_school", "Daffoden High", conf=0.55),
        ), template())
        assert "low_confidence" in codes(r, "warning")


class TestDocumentQuality:
    def test_poor_quality_adds_a_document_level_warning(self):
        f = form()
        f["document_quality"] = "poor"
        f["quality_note"] = "Heavy shadow across the page."
        r = validate(f, template())
        assert "poor_quality" in codes(r, "warning")
        assert any(i["field"] == "_document" for i in r["issues"])

    def test_counts_match_the_issue_list(self):
        r = validate(form(
            class_applying_for=field("class_applying_for", "12"),
            guardian_phone=field("guardian_phone", "1234568911"),
        ), template())
        assert r["error_count"] == len([i for i in r["issues"] if i["severity"] == "error"])
        assert r["warning_count"] == len([i for i in r["issues"] if i["severity"] == "warning"])
        assert r["error_count"] + r["warning_count"] == len(r["issues"])
