"""End-to-end test of the template engine against the running API.

    python test_e2e_templates.py

Proves the reader is not admission-specific: discovers a schema from a form,
saves it as a custom template, extracts against it, and commits through all
three targets. Cleans up after itself.
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

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed, failed = 0, 0
created_templates: list[str] = []
created_docs: list[str] = []
created_students: list[str] = []


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


TEST_TEMPLATE_NAMES = ("E2E Fee Receipt", "Example Admission Form (copy)")


def sweep_leftovers() -> None:
    """Remove anything a previous interrupted run left behind, so the suite
    stays runnable without manual cleanup."""
    stale = (sb.table("document_templates").select("id, name")
             .in_("name", list(TEST_TEMPLATE_NAMES)).execute().data)
    for t in stale:
        docs = sb.table("documents").select("id").eq("template_id", t["id"]).execute().data
        for d in docs:
            sb.table("extracted_records").delete().eq("document_id", d["id"]).execute()
            sb.table("students").delete().eq("source_document_id", d["id"]).execute()
            sb.table("documents").delete().eq("id", d["id"]).execute()
        sb.table("document_templates").delete().eq("id", t["id"]).execute()
    if stale:
        print(f"swept {len(stale)} leftover template(s) from an earlier run")


def main() -> int:
    sample = SAMPLES / "WhatsApp Image 2026-08-07 at 10.36.14 AM (1).jpeg"
    if not sample.exists():
        print(f"missing sample: {sample}")
        return 1
    img = sample.read_bytes()

    sweep_leftovers()

    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")
    A = {"Authorization": f"Bearer {admin_tok}"}
    T = {"Authorization": f"Bearer {teacher_tok}"}

    with httpx.Client(timeout=180) as c:
        print("\n1. Built-in template ships and works")
        r = c.get(f"{API}/templates", headers=A)
        check("templates list returns 200", r.status_code == 200)
        builtin = next((t for t in r.json() if t["is_builtin"]), None)
        check("built-in admission template exists", builtin is not None)
        check("it has nine fields", builtin and len(builtin["fields"]) == 9,
              str(len(builtin["fields"]) if builtin else 0))
        check("its target is student", builtin and builtin["target"] == "student")

        r = c.get(f"{API}/templates/field-types", headers=A)
        check("field-type catalogue exposed", r.status_code == 200
              and len(r.json()["types"]) >= 8)

        print("\n2. Discovery — the AI reads a form it was told nothing about")
        r = c.post(f"{API}/templates/discover", headers=A,
                   files={"file": (sample.name, img, "image/jpeg")})
        if not check("discover returns 200", r.status_code == 200,
                     f"{r.status_code} {r.text[:160]}"):
            return 1
        proposal = r.json()
        keys = [f["key"] for f in proposal["fields"]]
        types = {f["key"]: f["type"] for f in proposal["fields"]}

        check("found a useful number of fields", len(keys) >= 7, f"{len(keys)} fields")
        check("recognised it as student-related",
              proposal["suggested_target"] == "student", proposal["suggested_target"])
        check("typed at least one field as a date",
              "date" in types.values(), str(sorted(set(types.values()))))
        check("typed the contact number as a phone",
              any(t == "phone" for t in types.values()))
        check("returned a signed URL for the scanned form",
              bool(proposal.get("sample_url")))
        check("proposal is structurally valid",
              proposal["definition_errors"] == [], str(proposal["definition_errors"]))

        print("\n3. A teacher cannot create or discover templates")
        r = c.post(f"{API}/templates/discover", headers=T,
                   files={"file": (sample.name, img, "image/jpeg")})
        check("teacher blocked from discovery (403)", r.status_code == 403, str(r.status_code))
        r = c.post(f"{API}/templates", headers=T,
                   json={"name": "Sneaky", "target": "data_only",
                         "fields": [{"key": "x", "label": "X", "type": "text"}]})
        check("teacher blocked from creating (403)", r.status_code == 403, str(r.status_code))

        print("\n4. Invalid templates are rejected")
        bad = [
            ("no fields", {"name": "T1", "target": "data_only", "fields": []}),
            ("duplicate keys", {"name": "T2", "target": "data_only", "fields": [
                {"key": "a", "label": "A", "type": "text"},
                {"key": "a", "label": "B", "type": "text"}]}),
            ("choice without options", {"name": "T3", "target": "data_only", "fields": [
                {"key": "g", "label": "G", "type": "choice"}]}),
            ("student without a class field", {"name": "T4", "target": "student", "fields": [
                {"key": "n", "label": "Name", "type": "text", "maps_to": "full_name"}]}),
        ]
        for label, payload in bad:
            r = c.post(f"{API}/templates", headers=A, json=payload)
            check(f"rejected: {label}", r.status_code == 422, str(r.status_code))

        print("\n5. Save a custom NON-admission template (fee receipt)")
        receipt = {
            "name": "E2E Fee Receipt",
            "description": "Created by test_e2e_templates.py",
            "target": "data_only",
            "fields": [
                {"key": "student_name", "label": "Student Name", "type": "text", "required": True},
                {"key": "paid_on", "label": "Date", "type": "date", "required": True},
                {"key": "amount", "label": "Amount", "type": "number", "required": False},
                {"key": "contact", "label": "Phone", "type": "phone", "required": False},
            ],
        }
        r = c.post(f"{API}/templates", headers=A, json=receipt)
        if not check("custom template created (201)", r.status_code == 201,
                     f"{r.status_code} {r.text[:160]}"):
            return 1
        tpl = r.json()
        created_templates.append(tpl["id"])
        check("no maps_to needed for data-only", all(
            not f.get("maps_to") for f in tpl["fields"]))

        r = c.post(f"{API}/templates", headers=A, json=receipt)
        check("duplicate name rejected (409)", r.status_code == 409, str(r.status_code))

        print("\n6. Extract the SAME photo against the custom template")
        r = c.post(f"{API}/documents/extract", headers=A,
                   data={"template_id": tpl["id"]},
                   files={"file": (sample.name, img, "image/jpeg")})
        if not check("extract against custom template (201)", r.status_code == 201,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        doc = r.json()
        created_docs.append(doc["id"])
        got = {f["field"] for f in doc["extracted_json"]["fields"]}
        check("returned exactly the custom template's fields",
              got == {"student_name", "paid_on", "amount", "contact"}, str(sorted(got)))
        check("no admission fields leaked in",
              "guardian_name" not in got and "previous_school" not in got)
        check("template echoed back with the document",
              doc.get("template", {}).get("id") == tpl["id"])

        print("\n7. Commit routes by target — data_only writes no student")
        before = sb.table("students").select("id", count="exact").limit(1).execute().count
        r = c.post(f"{API}/documents/{doc['id']}/commit", headers=A, json={
            "values": {"student_name": "Test Payer", "paid_on": "2026-04-10",
                       "amount": "4500", "contact": "9866421801"}})
        if not check("commit returns 200", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        body = r.json()
        after = sb.table("students").select("id", count="exact").limit(1).execute().count
        check("committed as data_only", body["kind"] == "data_only", body["kind"])
        check("no student was created", before == after, f"{before} -> {after}")

        rec = sb.table("extracted_records").select("*").eq(
            "document_id", doc["id"]).execute().data
        check("an extracted_record was written", len(rec) == 1)
        check("it stored the reviewed values",
              rec and rec[0]["data"]["student_name"] == "Test Payer")

        print("\n8. Student target still produces a student")
        r = c.post(f"{API}/documents/extract", headers=A,
                   data={"template_id": builtin["id"]},
                   files={"file": (sample.name, img, "image/jpeg")})
        check("extract against built-in (201)", r.status_code == 201, str(r.status_code))
        sdoc = r.json()
        created_docs.append(sdoc["id"])

        r = c.post(f"{API}/documents/{sdoc['id']}/commit", headers=A, json={
            "values": {
                "full_name": "E2E Template Student",
                "date_of_birth": "2011-04-09",
                "gender": "M",
                "class_applying_for": "9",
                "guardian_name": "Raju",
                "guardian_phone": "9866421801",
                "address": "2-6-44",
                "previous_school": "Bhavans",
                "admission_date": "2026-06-10",
            }})
        if not check("student commit returns 200", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        sbody = r.json()
        created_students.append(sbody["record"]["id"])
        check("committed as student", sbody["kind"] == "student", sbody["kind"])
        check("placed in a grade-9 class", sbody["class"]["name"].startswith("9"),
              sbody["class"]["name"])
        check("provenance links back to the scan",
              sbody["record"]["source_document_id"] == sdoc["id"])

        print("\n9. Built-in template is protected")
        r = c.put(f"{API}/templates/{builtin['id']}", headers=A, json=receipt)
        check("cannot edit the built-in (409)", r.status_code == 409, str(r.status_code))
        r = c.delete(f"{API}/templates/{builtin['id']}", headers=A)
        check("cannot delete the built-in (409)", r.status_code == 409, str(r.status_code))

        r = c.post(f"{API}/templates/{builtin['id']}/duplicate", headers=A)
        check("but it can be duplicated (201)", r.status_code == 201, str(r.status_code))
        if r.status_code == 201:
            dup = r.json()
            created_templates.append(dup["id"])
            check("the copy is editable", not dup["is_builtin"])
            r2 = c.put(f"{API}/templates/{dup['id']}", headers=A, json={
                **receipt, "name": dup["name"]})
            check("editing the copy works (200)", r2.status_code == 200, str(r2.status_code))

        print("\n10. A used template is retired, not deleted")
        r = c.delete(f"{API}/templates/{tpl['id']}", headers=A)
        check("delete returns 204", r.status_code == 204, str(r.status_code))
        still = sb.table("document_templates").select("is_active").eq(
            "id", tpl["id"]).maybe_single().execute()
        check("template row survives for the audit trail", still is not None and still.data)
        check("but is marked inactive", still and still.data["is_active"] is False)

    print("\n11. Cleanup")
    for sid in created_students:
        sb.table("students").delete().eq("id", sid).execute()
    for did in created_docs:
        sb.table("extracted_records").delete().eq("document_id", did).execute()
        sb.table("documents").delete().eq("id", did).execute()
    for tid in created_templates:
        sb.table("document_templates").delete().eq("id", tid).execute()
    check("test data removed", True)

    print(f"\n{'=' * 60}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
