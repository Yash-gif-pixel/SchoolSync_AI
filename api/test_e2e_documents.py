"""End-to-end test of the document reader against the running API.

    python test_e2e_documents.py

Uploads a real sample form, checks extraction + validation came back sane,
commits it as a student, and confirms the row landed in the right class.
Cleans up after itself so it can be run repeatedly.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

sys.path.insert(0, str(Path(__file__).parent))

from sample_forms import ADMISSION_ANSWERS, admission_sample  # noqa: E402

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"

# The scan these assertions were written about: a strikethrough correction on
# the date of birth and no address line, but no hard errors -- so it is
# committable after review. It is a real child's paperwork and therefore
# gitignored, so on any other machine sample_forms generates a stand-in that
# reproduces both of those features. See sample_forms.py.
ORIGINAL_SCAN = "WhatsApp Image 2026-08-07 at 10.36.14 AM.jpeg"

sb_admin = create_client(
    os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"]
)

passed, failed = 0, 0


def check(label: str, ok: bool, detail: str = "") -> bool:
    global passed, failed
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{'  -- ' + detail if detail else ''}")
    if ok:
        passed += 1
    else:
        failed += 1
    return ok


def token_for(email: str) -> str:
    r = httpx.post(
        f"{os.environ['SUPABASE_URL']}/auth/v1/token?grant_type=password",
        headers={"apikey": os.environ["SUPABASE_ANON_KEY"]},
        json={"email": email, "password": PASSWORD},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def main() -> int:
    name, image, mime = admission_sample(prefer=ORIGINAL_SCAN)
    print(f"\nreading: {name}")

    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")

    print("\n1. Upload + extract")
    with httpx.Client(timeout=120) as c:
        r = c.post(
            f"{API}/documents/extract",
            headers={"Authorization": f"Bearer {admin_tok}"},
            files={"file": (name, image, mime)},
        )
    if not check("extract returns 201", r.status_code == 201, f"got {r.status_code} {r.text[:200]}"):
        return 1

    doc = r.json()
    ex = doc["extracted_json"]
    fields = {f["field"]: f for f in ex["fields"]}
    doc_id = doc["id"]

    check("document row persisted", bool(doc_id))
    check("status is needs_review", doc["status"] == "needs_review", doc["status"])
    check("signed image URL returned", bool(doc.get("image_url")))
    check("mean confidence recorded", isinstance(doc.get("confidence"), (int, float)),
          str(doc.get("confidence")))

    print("\n2. Extraction quality")
    # Expectations come from sample_forms rather than repeated literals, so the
    # real scan and the generated stand-in are checked against one description
    # of what is on the paper.
    want = ADMISSION_ANSWERS
    good_year = want["date_of_birth"][:4]
    struck_year = want["struck_date_of_birth"][:4]

    read_name = (fields["full_name"]["value"] or "").lower().replace(" ", "")
    surname = want["full_name"].split()[0].lower()
    check("student name read", surname in read_name, fields["full_name"]["value"])
    check(f"strikethrough resolved to {good_year}, not {struck_year}",
          (fields["date_of_birth"]["value"] or "").startswith(good_year),
          fields["date_of_birth"]["value"])
    check("absent address marked not-present, not guessed",
          fields["address"]["present_on_form"] is False and fields["address"]["value"] is None)
    check("phone extracted",
          (fields["guardian_phone"]["value"] or "").startswith(want["guardian_phone"][:2]),
          fields["guardian_phone"]["value"])
    check(f"class read as {want['class_applying_for']}",
          fields["class_applying_for"]["value"] == want["class_applying_for"],
          fields["class_applying_for"]["value"])

    print("\n3. Validation")
    check("no hard errors on this form", ex["error_count"] == 0, f"{ex['error_count']} errors")
    check("warnings raised for review", ex["warning_count"] > 0, f"{ex['warning_count']} warnings")
    check("not auto-committable while warnings stand", ex["can_auto_commit"] is False)
    per_field = [(i["field"], i["code"]) for i in ex["issues"]]
    check("no duplicate issue per field", len(per_field) == len(set(per_field)))

    print("\n4. Authorisation")
    with httpx.Client(timeout=60) as c:
        probe = {"values": {"full_name": "Hacker",
                            "class_applying_for": want["class_applying_for"]}}
        r_teacher = c.post(
            f"{API}/documents/{doc_id}/commit",
            headers={"Authorization": f"Bearer {teacher_tok}"},
            json=probe,
        )
        r_anon = c.post(f"{API}/documents/{doc_id}/commit", json=probe)
    check("teacher cannot commit (403)", r_teacher.status_code == 403, str(r_teacher.status_code))
    check("anonymous cannot commit (401)", r_anon.status_code == 401, str(r_anon.status_code))

    print("\n5. Reviewed commit")
    with httpx.Client(timeout=60) as c:
        r = c.post(
            f"{API}/documents/{doc_id}/commit",
            headers={"Authorization": f"Bearer {admin_tok}"},
            json={"values": {
                # The reviewer's values, not the model's: a corrected spelling
                # and an address typed in by hand, since the form has no line
                # for one.
                "full_name": want["full_name"],
                "date_of_birth": want["date_of_birth"],
                "gender": want["gender"],
                "class_applying_for": want["class_applying_for"],
                "guardian_name": want["guardian_name"],
                "guardian_phone": want["guardian_phone"],
                "address": "Typed in by reviewer",
                "previous_school": want["previous_school"],
                "admission_date": want["admission_date"],
            }},
        )
    if not check("commit returns 200", r.status_code == 200, f"{r.status_code} {r.text[:200]}"):
        return 1

    body = r.json()
    student = body["record"]
    student_id = student["id"]
    check("student created", bool(student_id))
    check("routed to the student target", body["kind"] == "student", body["kind"])
    check(f"placed in a grade-{want['class_applying_for']} class",
          body["class"]["name"].startswith(want["class_applying_for"]),
          body["class"]["name"])
    check("reviewer's correction was saved, not the model's value",
          student["full_name"] == want["full_name"], student["full_name"])
    check("manually typed address saved",
          student["address"] == "Typed in by reviewer")
    check("provenance links back to the scan",
          student["source_document_id"] == doc_id)

    print("\n6. Post-commit state")
    fresh = sb_admin.table("documents").select("status").eq("id", doc_id).single().execute().data
    check("document marked committed", fresh["status"] == "committed", fresh["status"])

    with httpx.Client(timeout=60) as c:
        r2 = c.post(
            f"{API}/documents/{doc_id}/commit",
            headers={"Authorization": f"Bearer {admin_tok}"},
            json={"values": {"full_name": "Duplicate",
                             "class_applying_for": want["class_applying_for"]}},
        )
    check("double-commit rejected (409)", r2.status_code == 409, str(r2.status_code))

    print("\n7. Cleanup")
    sb_admin.table("students").delete().eq("id", student_id).execute()
    sb_admin.table("documents").delete().eq("id", doc_id).execute()
    check("test data removed", True)

    print(f"\n{'=' * 60}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
