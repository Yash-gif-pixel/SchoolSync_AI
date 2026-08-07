"""Matching a handwritten name to a member of staff.

The failure that matters here is not "didn't match" — it is "matched the wrong
person and filed their sick leave". Every test below is really asking whether
the resolver stays conservative when it should.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.people import normalise, resolve_person  # noqa: E402

STAFF = [
    {"id": "1", "full_name": "Nisha Nair"},
    {"id": "2", "full_name": "Ishaan Reddy"},
    {"id": "3", "full_name": "Isha Singh"},
    {"id": "4", "full_name": "Priya Sharma"},
    {"id": "5", "full_name": "Rahul Verma"},
]


class TestNormalise:
    def test_lowercases_and_trims(self):
        assert normalise("  Nisha   NAIR ") == "nisha nair"

    @pytest.mark.parametrize(
        "written", ["Mrs. Nisha Nair", "Dr Nisha Nair", "Smt. Nisha Nair",
                    "Ms Nisha Nair"]
    )
    def test_strips_honorifics(self, written):
        assert normalise(written) == "nisha nair"

    def test_strips_accents_and_punctuation(self):
        assert normalise("Nishá  Nair,") == "nisha nair"

    def test_empty_input(self):
        assert normalise(None) == ""
        assert normalise("   ") == ""


class TestExactAndPartial:
    def test_exact_name_resolves(self):
        m = resolve_person("Nisha Nair", STAFF)
        assert m.ok and m.resolved_id == "1" and m.reason == "exact"

    def test_case_and_spacing_are_ignored(self):
        assert resolve_person("  nisha   nair ", STAFF).resolved_id == "1"

    def test_honorific_on_the_note_is_ignored(self):
        assert resolve_person("Mrs. Nisha Nair", STAFF).resolved_id == "1"

    def test_first_name_alone_resolves_when_unambiguous(self):
        m = resolve_person("Priya", STAFF)
        assert m.ok and m.resolved_id == "4" and m.reason == "unique_partial"

    def test_extra_words_are_tolerated(self):
        m = resolve_person("Nisha Nair (Science Dept)", STAFF)
        assert m.ok and m.resolved_id == "1"


class TestRefusesToGuess:
    """The important half. A wrong confident match files the wrong person's
    leave, which is worse than asking a human."""

    def test_a_similar_but_different_name_is_not_matched(self):
        """"Isha" must not become "Ishaan". Tokens match whole words, so a
        shared prefix is never treated as the same name."""
        m = resolve_person("Isha", STAFF)
        assert m.resolved_name != "Ishaan Reddy"
        # It does land on Isha Singh, but only as a partial — which the
        # review screen surfaces as "read as Isha Singh, confirm this".
        assert m.reason == "unique_partial"

    def test_a_first_name_two_people_share_is_refused(self):
        staff = STAFF + [{"id": "6", "full_name": "Isha Kapoor"}]
        m = resolve_person("Isha", staff)
        assert not m.ok
        assert m.reason == "ambiguous"
        assert {c["full_name"] for c in m.candidates} == {"Isha Singh", "Isha Kapoor"}

    def test_two_people_share_a_name(self):
        staff = STAFF + [{"id": "6", "full_name": "Nisha Nair"}]
        m = resolve_person("Nisha Nair", staff)
        assert not m.ok
        assert m.reason == "ambiguous"
        assert len(m.candidates) == 2

    def test_unknown_name_is_refused(self):
        m = resolve_person("Wilhelmina Fortescue", STAFF)
        assert not m.ok and m.reason == "none"

    def test_a_typo_is_suggested_never_chosen(self):
        m = resolve_person("Nisha Nar", STAFF)
        assert not m.ok, "a near miss must not resolve on its own"
        assert any(c["full_name"] == "Nisha Nair" for c in m.candidates), \
            "but it should say who was meant"

    def test_empty_is_refused_without_crashing(self):
        for value in (None, "", "   "):
            m = resolve_person(value, STAFF)
            assert not m.ok and m.candidates == []

    def test_no_staff_at_all(self):
        assert not resolve_person("Nisha Nair", []).ok

    def test_wildly_different_name_offers_nothing(self):
        m = resolve_person("Zzzzzzzzzzq", STAFF)
        assert not m.ok
        assert m.candidates == [], "no suggestion is better than a bad one"
