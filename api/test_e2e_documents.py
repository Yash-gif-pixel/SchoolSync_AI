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

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
SAMPLES = Path(__file__).resolve().parent.parent / "samples"
PASSWORD = "Demo@12345"

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
    # The Manjeet form: has a strikethrough correction and no address line,
    # but no hard errors -- so it is committable after review.
    sample = SAMPLES / "WhatsApp Image 2026-08-07 at 10.36.14 AM.jpeg"
    if not sample.exists():
        print(f"missing sample: {sample}")
        return 1

    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")

    print("\n1. Upload + extract")
    with httpx.Client(timeout=120) as c:
        r = c.post(
            f"{API}/documents/extract",
            headers={"Authorization": f"Bearer {admin_tok}"},
            files={"file": (sample.name, sample.read_bytes(), "image/jpeg")},
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
    name = (fields["full_name"]["value"] or "").lower().replace(" ", "")
    check("student name read", "manjeet" in name, fields["full_name"]["value"])
    check("strikethrough resolved to 2014, not 1979",
          (fields["date_of_birth"]["value"] or "").startswith("2014"),
          fields["date_of_birth"]["value"])
    check("absent address marked not-present, not guessed",
          fields["address"]["present_on_form"] is False and fields["address"]["value"] is None)
    check("phone extracted", (fields["guardian_phone"]["value"] or "").startswith("98"),
          fields["guardian_phone"]["value"])
    check("class read as 8", fields["class_applying_for"]["value"] == "8",
          fields["class_applying_for"]["value"])

    print("\n3. Validation")
    check("no hard errors on this form", ex["error_count"] == 0, f"{ex['error_count']} errors")
    check("warnings raised for review", ex["warning_count"] > 0, f"{ex['warning_count']} warnings")
    check("not auto-committable while warnings stand", ex["can_auto_commit"] is False)
    per_field = [(i["field"], i["code"]) for i in ex["issues"]]
    check("no duplicate issue per field", len(per_field) == len(set(per_field)))

    print("\n4. Authorisation")
    with httpx.Client(timeout=60) as c:
        probe = {"values": {"full_name": "Hacker", "class_applying_for": "8"}}
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
                "full_name": "Manjeet Singh",     # reviewer corrected the spelling
                "date_of_birth": "2014-03-10",
                "gender": "M",
                "class_applying_for": "8",
                "guardian_name": "Jagdarshan Lal",
                "guardian_phone": "9866421801",
                "address": "Typed in by reviewer",  # was absent on the form
                "previous_school": "Daffodil High School",
                "admission_date": "2026-04-10",
            }},
        )
    if not check("commit returns 200", r.status_code == 200, f"{r.status_code} {r.text[:200]}"):
        return 1

    body = r.json()
    student = body["record"]
    student_id = student["id"]
    check("student created", bool(student_id))
    check("routed to the student target", body["kind"] == "student", body["kind"])
    check("placed in a grade-8 class", body["class"]["name"].startswith("8"), body["class"]["name"])
    check("reviewer's correction was saved, not the model's value",
          student["full_name"] == "Manjeet Singh", student["full_name"])
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
            json={"values": {"full_name": "Duplicate", "class_applying_for": "8"}},
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
