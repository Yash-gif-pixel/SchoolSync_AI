"""Template definition checks and the schema/prompt built from them."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.templates import (  # noqa: E402
    FIELD_TYPES,
    prompt_for,
    response_schema_for,
    validate_definition,
)

STUDENT_FIELDS = [
    {"key": "full_name", "label": "Name", "type": "text", "required": True,
     "maps_to": "full_name"},
    {"key": "klass", "label": "Class", "type": "grade", "required": True,
     "maps_to": "__class"},
]


class TestValidateDefinition:
    def test_a_minimal_student_template_is_valid(self):
        assert validate_definition(STUDENT_FIELDS, "student") == []

    def test_empty_field_list_is_rejected(self):
        assert validate_definition([], "student")
        assert validate_definition(None, "student")

    def test_duplicate_keys_are_rejected(self):
        fields = STUDENT_FIELDS + [
            {"key": "full_name", "label": "Again", "type": "text", "required": False}
        ]
        assert any("Duplicate" in e for e in validate_definition(fields, "student"))

    def test_unknown_type_is_rejected(self):
        fields = [{"key": "x", "label": "X", "type": "wizardry", "required": False}]
        assert any("unknown type" in e for e in validate_definition(fields, "data_only"))

    def test_missing_label_is_rejected(self):
        fields = [{"key": "x", "label": "  ", "type": "text", "required": False}]
        assert any("no label" in e for e in validate_definition(fields, "data_only"))

    def test_key_must_be_identifier_like(self):
        fields = [{"key": "not a key!", "label": "X", "type": "text", "required": False}]
        assert any("letters, digits" in e for e in validate_definition(fields, "data_only"))

    def test_choice_without_options_is_rejected(self):
        fields = [{"key": "g", "label": "Gender", "type": "choice", "required": False}]
        assert any("no options" in e for e in validate_definition(fields, "data_only"))

    def test_student_template_needs_a_name_and_a_class(self):
        errors = validate_definition(
            [{"key": "full_name", "label": "Name", "type": "text",
              "required": True, "maps_to": "full_name"}],
            "student",
        )
        assert any("__class" in e for e in errors)

    def test_maps_to_must_be_a_real_column_for_the_target(self):
        fields = STUDENT_FIELDS + [
            {"key": "x", "label": "X", "type": "text", "required": False,
             "maps_to": "not_a_column"}
        ]
        assert any("not a field of a student" in e for e in validate_definition(fields, "student"))

    def test_data_only_templates_need_no_mapping(self):
        fields = [
            {"key": "receipt_no", "label": "Receipt No", "type": "number", "required": True},
            {"key": "amount", "label": "Amount", "type": "number", "required": True},
        ]
        assert validate_definition(fields, "data_only") == []

    def test_unknown_target_is_rejected(self):
        assert any("Unknown target" in e for e in validate_definition(STUDENT_FIELDS, "spaceship"))


class TestResponseSchema:
    def test_field_enum_matches_the_template_keys(self):
        schema = response_schema_for(STUDENT_FIELDS)
        enum = schema["properties"]["fields"]["items"]["properties"]["field"]["enum"]
        assert enum == ["full_name", "klass"]

    def test_every_per_field_property_is_required(self):
        item = response_schema_for(STUDENT_FIELDS)["properties"]["fields"]["items"]
        assert set(item["required"]) == {
            "field", "value", "raw_text", "present_on_form", "confidence", "note"
        }

    def test_present_on_form_is_separate_from_confidence(self):
        """The distinction the review UI depends on."""
        props = response_schema_for(STUDENT_FIELDS)["properties"]["fields"]["items"]["properties"]
        assert props["present_on_form"]["type"] == "boolean"
        assert props["confidence"]["type"] == "number"

    def test_schema_grows_with_the_template(self):
        many = [
            {"key": f"f{i}", "label": f"F{i}", "type": "text", "required": False}
            for i in range(25)
        ]
        enum = response_schema_for(many)["properties"]["fields"]["items"]["properties"]["field"]["enum"]
        assert len(enum) == 25


class TestPrompt:
    def _prompt(self, fields, name="Fee Receipt"):
        return prompt_for({"name": name, "fields": fields})

    @staticmethod
    def _flat(text: str) -> str:
        """Collapse whitespace so assertions don't depend on line wrapping."""
        return " ".join(text.split()).lower()

    def test_lists_every_field_with_its_label(self):
        p = self._prompt(STUDENT_FIELDS)
        assert "full_name" in p and "Class" in p

    def test_names_the_template(self):
        assert "Fee Receipt" in self._prompt(STUDENT_FIELDS)

    def test_date_fields_carry_the_day_month_convention(self):
        p = self._flat(self._prompt([
            {"key": "d", "label": "Date", "type": "date", "required": True}
        ]))
        assert "10 march 2014" in p
        assert "do not lower confidence" in p

    def test_choice_options_are_listed(self):
        p = self._prompt([
            {"key": "g", "label": "Gender", "type": "choice",
             "required": False, "options": ["M", "F"]}
        ])
        assert "Options: M, F" in p

    def test_field_description_is_passed_through(self):
        p = self._prompt([
            {"key": "x", "label": "X", "type": "text", "required": False,
             "description": "Written in the top-right box."}
        ])
        assert "top-right box" in p

    def test_facing_page_and_bleed_through_warning_is_always_present(self):
        """Every sample photo has a facing page visible; without this the
        model merges values across two different forms."""
        p = self._flat(self._prompt(STUDENT_FIELDS))
        assert "facing page" in p
        assert "bleed" in p
        assert "never merge values across pages" in p

    @pytest.mark.parametrize("ftype", list(FIELD_TYPES))
    def test_every_type_produces_a_usable_instruction(self, ftype):
        fields = [{"key": "x", "label": "X", "type": ftype, "required": False}]
        if ftype == "choice":
            fields[0]["options"] = ["a", "b"]
        p = self._prompt(fields)
        assert FIELD_TYPES[ftype]["hint"][:20] in p
