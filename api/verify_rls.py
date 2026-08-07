"""Prove RLS actually works, using real logins rather than trusting the policy text.

A teacher must see only their own leave requests and only their own classes'
students. An admin must see everything.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from supabase import create_client

load_dotenv(Path(__file__).with_name(".env"))
URL = os.environ["SUPABASE_URL"]
ANON = os.environ["SUPABASE_ANON_KEY"]
SERVICE = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
PASSWORD = "Demo@12345"

admin_sb = create_client(URL, SERVICE)
failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{'  -- ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


# --- ground truth via service_role (bypasses RLS) ---------------------
total_students = admin_sb.table("students").select("id", count="exact").limit(1).execute().count
total_leaves = admin_sb.table("leave_requests").select("id", count="exact").limit(1).execute().count
print(f"ground truth (service_role): {total_students} students, {total_leaves} leave requests\n")

leaves = admin_sb.table("leave_requests").select("teacher_id").limit(400).execute().data
counts: dict[str, int] = {}
for r in leaves:
    counts[r["teacher_id"]] = counts.get(r["teacher_id"], 0) + 1

def all_auth_users() -> dict[str, str]:
    """list_users() pages at 50; the school has more staff than that."""
    out: dict[str, str] = {}
    page = 1
    while True:
        batch = admin_sb.auth.admin.list_users(page=page, per_page=200)
        if not batch:
            return out
        for u in batch:
            out[u.id] = u.email
        if len(batch) < 200:
            return out
        page += 1


users = all_auth_users()
profiles = {
    p["id"]: p
    for p in admin_sb.table("profiles")
    .select("id, full_name, is_approver, department_id, role")
    .eq("role", "teacher").execute().data
}


def pick(approver: bool) -> str:
    """Teacher with the most leave on record, matching the approver flag."""
    pool = [tid for tid in counts if profiles.get(tid, {}).get("is_approver") is approver]
    return max(pool, key=lambda t: counts[t])


def own_class_ids(tid: str) -> list[str]:
    return [
        r["class_id"]
        for r in admin_sb.table("teaching_assignments")
        .select("class_id").eq("teacher_id", tid).execute().data
    ]


def test_teacher(tid: str) -> None:
    prof = profiles[tid]
    email = users[tid]
    own_leaves = counts[tid]
    class_ids = own_class_ids(tid)
    expected_students = (
        admin_sb.table("students").select("id", count="exact")
        .in_("class_id", class_ids).limit(1).execute().count
    )
    kind = "HOD / approver" if prof["is_approver"] else "PLAIN TEACHER"

    print(f"\nsigned in as {kind}: {prof['full_name']} <{email}>")
    print(f"  own leaves={own_leaves}  classes={len(set(class_ids))}  "
          f"students in those classes={expected_students}")

    t = create_client(URL, ANON)
    t.auth.sign_in_with_password({"email": email, "password": PASSWORD})

    seen = t.table("leave_requests").select("id, teacher_id").execute().data
    foreign = [r for r in seen if r["teacher_id"] != tid]

    if prof["is_approver"]:
        dept_ids = [
            p["id"] for p in profiles.values()
            if p["department_id"] == prof["department_id"]
        ]
        outside = [r for r in seen if r["teacher_id"] not in dept_ids]
        check("HOD sees own + own-department leave only",
              len(outside) == 0 and len(seen) < total_leaves,
              f"{len(seen)} of {total_leaves} visible, {len(outside)} from other departments")
    else:
        check("plain teacher sees ONLY own leave requests",
              len(foreign) == 0 and len(seen) == own_leaves,
              f"saw {len(seen)} (own={own_leaves}), {len(foreign)} belonging to others")

    seen_students = t.table("students").select("id", count="exact").limit(1).execute().count
    check(f"{kind}: sees only own classes' students",
          seen_students == expected_students,
          f"saw {seen_students}, expected {expected_students}, school total {total_students}")

    denied = False
    try:
        r = t.table("students").insert({"full_name": "RLS Probe", "roll_no": 999}).execute()
        denied = not r.data
    except Exception:
        denied = True
    check(f"{kind}: CANNOT insert students (admin-only)", denied)


test_teacher(pick(approver=False))   # the strict case
test_teacher(pick(approver=True))    # the decentralised-approval case

# --- as admin ----------------------------------------------------------
print("\nsigned in as ADMIN:")
a = create_client(URL, ANON)
a.auth.sign_in_with_password({"email": "admin@school.test", "password": PASSWORD})

a_students = a.table("students").select("id", count="exact").limit(1).execute().count
a_leaves = a.table("leave_requests").select("id", count="exact").limit(1).execute().count
check("admin sees all students", a_students == total_students, f"{a_students}/{total_students}")
check("admin sees all leave requests", a_leaves == total_leaves, f"{a_leaves}/{total_leaves}")

print("\n" + "=" * 60)
if failures:
    print(f"FAILED: {len(failures)} check(s): {'; '.join(failures)}")
    sys.exit(1)
print("ALL RLS CHECKS PASSED")
