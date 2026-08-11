"""End-to-end test of attendance, leave approval and substitution matching.

    python test_e2e_phase3.py

Walks the demo path: a teacher files leave, their HOD approves it, the matcher
produces ranked cover, the admin confirms one. Cleans up after itself.
"""

from __future__ import annotations

import datetime as dt
import os
import sys
from collections import defaultdict
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed = failed = 0
created_leaves: list[str] = []


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


def next_weekday() -> dt.date:
    """The next Mon-Sat at least a day away."""
    d = dt.date.today() + dt.timedelta(days=1)
    while d.isoweekday() == 7:
        d += dt.timedelta(days=1)
    return d


def main() -> int:
    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")
    hod_tok = token_for("hod@school.test")
    A = {"Authorization": f"Bearer {admin_tok}"}
    T = {"Authorization": f"Bearer {teacher_tok}"}
    H = {"Authorization": f"Bearer {hod_tok}"}

    teacher = httpx.get(f"{API}/me", headers=T, timeout=30).json()
    hod = httpx.get(f"{API}/me", headers=H, timeout=30).json()
    print(f"\nteacher : {teacher['full_name']} ({teacher['id'][:8]})")
    print(f"HOD     : {hod['full_name']}  approver={hod['is_approver']}")
    check("teacher and HOD share a department",
          teacher["department_id"] == hod["department_id"])
    check("the plain teacher is not an approver", teacher["is_approver"] is False)

    with httpx.Client(timeout=120) as c:
        # ---------------------------------------------------- attendance
        print("\n1. Attendance — default to present")
        r = c.get(f"{API}/attendance/today", headers=T)
        if not check("today's periods load", r.status_code == 200, str(r.status_code)):
            return 1
        today = r.json()
        if not today.get("periods"):
            print("  (no periods for this teacher today — using any class they teach)")
            ta = sb.table("teaching_assignments").select("class_id").eq(
                "teacher_id", teacher["id"]).limit(1).execute().data
            class_id = ta[0]["class_id"]
            slot_id = sb.table("time_slots").select("id").eq(
                "is_break", False).limit(1).execute().data[0]["id"]
        else:
            p = today["periods"][0]
            class_id, slot_id = p["class_id"], p["slot_id"]
            check("periods carry a marked flag", "marked" in p)

        # This period may already have been marked — by a demo, or an earlier
        # run. Clear it so the default-to-present behaviour is actually what
        # gets tested rather than whatever was left behind.
        sb.table("attendance").delete().eq("class_id", class_id).eq(
            "slot_id", slot_id).eq("date", dt.date.today().isoformat()).execute()

        r = c.get(f"{API}/attendance/roster", headers=T,
                  params={"class_id": class_id, "slot_id": slot_id})
        if not check("roster loads", r.status_code == 200, str(r.status_code)):
            return 1
        roster = r.json()
        students = roster["students"]
        check("roster has the whole class", len(students) > 0, f"{len(students)} pupils")
        check("EVERY pupil pre-marked present",
              all(s["status"] == "present" for s in students),
              "the point of the design")
        check("pupils come back in roll order",
              [s["roll_no"] for s in students] == sorted(s["roll_no"] for s in students))

        marks = [{"student_id": s["id"], "status": "present"} for s in students]
        marks[0]["status"] = "absent"
        marks[1]["status"] = "absent"
        marks[2]["status"] = "late"
        r = c.post(f"{API}/attendance/mark", headers=T, json={
            "class_id": class_id, "slot_id": slot_id,
            "date": dt.date.today().isoformat(), "marks": marks})
        if not check("one bulk write marks the class", r.status_code == 200,
                     f"{r.status_code} {r.text[:160]}"):
            return 1
        body = r.json()
        check("counts are right", body["absent"] == 2 and body["late"] == 1,
              f"{body['present']}P {body['absent']}A {body['late']}L")

        r = c.get(f"{API}/attendance/roster", headers=T,
                  params={"class_id": class_id, "slot_id": slot_id})
        again = r.json()
        check("reopening shows what was recorded, not the default",
              sum(1 for s in again["students"] if s["status"] == "absent") == 2)
        check("it knows the period was already marked", again["already_marked"] is True)

        marks[0]["status"] = "present"
        r = c.post(f"{API}/attendance/mark", headers=T, json={
            "class_id": class_id, "slot_id": slot_id,
            "date": dt.date.today().isoformat(), "marks": marks})
        check("re-marking corrects rather than failing", r.status_code == 200,
              str(r.status_code))
        check("the correction stuck", r.json()["absent"] == 1, str(r.json()["absent"]))

        other = sb.table("classes").select("id").not_.in_(
            "id", [class_id]).limit(1).execute().data[0]["id"]
        r = c.get(f"{API}/attendance/roster", headers=T,
                  params={"class_id": other, "slot_id": slot_id})
        check("cannot open a class they don't teach (403)", r.status_code == 403,
              str(r.status_code))

        # --------------------------------------------------------- leave
        print("\n2. Leave request")
        day = next_weekday()

        # Leave can no longer overlap existing leave, so clear anything on
        # file for the days this test uses — from a demo, or a run that was
        # interrupted before its own cleanup.
        window_end = (day + dt.timedelta(days=5)).isoformat()
        for old in (sb.table("leave_requests").select("id")
                    .eq("teacher_id", teacher["id"])
                    .gte("to_date", day.isoformat())
                    .lte("from_date", window_end).execute().data):
            sb.table("substitutions").delete().eq(
                "leave_request_id", old["id"]).execute()
            sb.table("leave_requests").delete().eq("id", old["id"]).execute()

        r = c.post(f"{API}/leave", headers=T, json={
            "from_date": day.isoformat(), "to_date": day.isoformat(),
            "reason": "E2E test — fever"})
        if not check("teacher files leave (201)", r.status_code == 201,
                     f"{r.status_code} {r.text[:160]}"):
            return 1
        leave = r.json()
        created_leaves.append(leave["id"])
        check("starts pending an in-charge", leave["status"] == "pending_incharge")

        r = c.post(f"{API}/leave", headers=T, json={
            "from_date": day.isoformat(),
            "to_date": (day - dt.timedelta(days=3)).isoformat()})
        check("end-before-start rejected (422)", r.status_code == 422, str(r.status_code))

        print("\n3. Decentralised approval")
        r = c.get(f"{API}/leave/pending", headers=T)
        check("a plain teacher has no approval queue", r.json() == [],
              f"{len(r.json())} items")

        r = c.get(f"{API}/leave/pending", headers=H)
        check("the HOD sees it in their queue",
              any(x["id"] == leave["id"] for x in r.json()),
              f"{len(r.json())} pending")
        check("HOD queue is limited to their department",
              all((x.get("teacher") or {}).get("department_id") == hod["department_id"]
                  for x in r.json()))

        r = c.post(f"{API}/leave/{leave['id']}/review", headers=T,
                   json={"approve": True})
        check("a teacher cannot approve leave (403)", r.status_code == 403,
              str(r.status_code))

        # ------------------------------------------------- substitutions
        print("\n4. Approval fires the substitution matcher")
        r = c.post(f"{API}/leave/{leave['id']}/review", headers=H,
                   json={"approve": True})
        if not check("HOD approves (200)", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        review = r.json()
        check("status is approved", review["status"] == "approved")
        check("periods needing cover were found",
              review["periods_affected"] > 0,
              f"{review['periods_affected']} periods")
        check("every period got at least one candidate",
              review["periods_without_cover"] == 0,
              f"{review['periods_without_cover']} uncovered")

        r = c.post(f"{API}/leave/{leave['id']}/review", headers=H,
                   json={"approve": True})
        check("cannot review the same request twice (409)", r.status_code == 409,
              str(r.status_code))

        print("\n5. Suggestion quality")
        subs = sb.table("substitutions").select(
            "id, rank, rationale, date, timetable_entry_id, substitute_teacher_id"
        ).eq("leave_request_id", leave["id"]).execute().data
        check("suggestions persisted", len(subs) > 0, f"{len(subs)} rows")

        by_period = defaultdict(list)
        for s in subs:
            by_period[s["timetable_entry_id"], s["date"]].append(s)
        check("each period is ranked from 1",
              all(sorted(x["rank"] for x in v)[0] == 1 for v in by_period.values()))
        check("every suggestion explains itself",
              all(s["rationale"] for s in subs))
        check("the absent teacher is never their own cover",
              all(s["substitute_teacher_id"] != teacher["id"] for s in subs))

        # a top pick must genuinely be free in that slot
        entry_slot = {
            e["id"]: e["slot_id"] for e in sb.table("timetable_entries")
            .select("id, slot_id")
            .in_("id", list({s["timetable_entry_id"] for s in subs}))
            .execute().data
        }
        ver = sb.table("timetable_versions").select("id").eq(
            "is_active", True).maybe_single().execute().data["id"]
        clashes = 0
        for (entry_id, _date), group in by_period.items():
            top = min(group, key=lambda g: g["rank"])
            slot = entry_slot.get(entry_id)
            busy = sb.table("timetable_entries").select(
                "id, teaching_assignments!inner(teacher_id)"
            ).eq("version_id", ver).eq("slot_id", slot).eq(
                "teaching_assignments.teacher_id", top["substitute_teacher_id"]
            ).execute().data
            if busy:
                clashes += 1
        check("top pick is genuinely free in that slot", clashes == 0,
              f"{clashes} clashes")

        same_dept = sb.table("profiles").select("id").eq(
            "department_id", teacher["department_id"]).eq("role", "teacher").execute().data
        dept_ids = {p["id"] for p in same_dept}
        top_in_dept = sum(
            1 for v in by_period.values()
            if min(v, key=lambda g: g["rank"])["substitute_teacher_id"] in dept_ids
        )
        check("domain match is preferred where possible",
              top_in_dept >= len(by_period) * 0.5,
              f"{top_in_dept}/{len(by_period)} top picks from the same department")

        print("\n6. Action Board")
        r = c.get(f"{API}/substitutions/board", headers=A)
        if not check("board loads (200)", r.status_code == 200, str(r.status_code)):
            return 1
        board = r.json()
        grp = next((g for g in board["groups"] if g["leave_id"] == leave["id"]), None)
        check("the new absence appears on the board", grp is not None)
        check("it names who is away",
              grp and grp["absent_teacher"] == teacher["full_name"],
              grp["absent_teacher"] if grp else "")
        check("candidates are ordered best-first",
              grp and all(
                  [c["rank"] for c in p["candidates"]] ==
                  sorted(c["rank"] for c in p["candidates"])
                  for p in grp["periods"]))
        check("board counts work needing action", board["needs_action"] > 0,
              f"{board['needs_action']} periods")

        print("\n7. Confirming cover")
        period = grp["periods"][0]
        best = period["candidates"][0]
        r = c.post(f"{API}/substitutions/{best['substitution_id']}/confirm", headers=T)
        check("a teacher cannot confirm cover (403)", r.status_code == 403,
              str(r.status_code))

        r = c.post(f"{API}/substitutions/{best['substitution_id']}/confirm", headers=A)
        if not check("admin confirms (200)", r.status_code == 200,
                     f"{r.status_code} {r.text[:160]}"):
            return 1
        conf = r.json()
        check("confirmation names the teacher",
              best["teacher_name"] in conf["message"], conf["message"])
        check("the alternatives were declined",
              conf["declined_alternatives"] == len(period["candidates"]) - 1,
              f"{conf['declined_alternatives']}")

        rows = sb.table("substitutions").select("status").eq(
            "timetable_entry_id", period["timetable_entry_id"]).eq(
            "date", period["date"]).execute().data
        check("exactly one confirmed for that period",
              sum(1 for x in rows if x["status"] == "confirmed") == 1)

        r = c.get(f"{API}/substitutions/board", headers=A)
        g2 = next(g for g in r.json()["groups"] if g["leave_id"] == leave["id"])
        p2 = next(p for p in g2["periods"]
                  if p["timetable_entry_id"] == period["timetable_entry_id"]
                  and p["date"] == period["date"])
        check("the board reflects the confirmation", p2["status"] == "confirmed")

        print("\n8. Rejection path")
        day2 = next_weekday() + dt.timedelta(days=1)
        if day2.isoweekday() == 7:
            day2 += dt.timedelta(days=1)
        r = c.post(f"{API}/leave", headers=T, json={
            "from_date": day2.isoformat(), "to_date": day2.isoformat(),
            "reason": "E2E test — to be rejected"})
        rejected = r.json()
        created_leaves.append(rejected["id"])
        r = c.post(f"{API}/leave/{rejected['id']}/review", headers=H,
                   json={"approve": False})
        check("HOD can reject (200)", r.status_code == 200, str(r.status_code))
        check("status is rejected", r.json()["status"] == "rejected")
        check("a rejected request creates no cover",
              r.json()["periods_affected"] == 0)
        n = sb.table("substitutions").select("id", count="exact").eq(
            "leave_request_id", rejected["id"]).limit(1).execute().count or 0
        check("no substitution rows written", n == 0, f"{n} rows")

    print("\n9. Cleanup")
    for lid in created_leaves:
        sb.table("substitutions").delete().eq("leave_request_id", lid).execute()
        sb.table("leave_requests").delete().eq("id", lid).execute()
    sb.table("attendance").delete().eq("class_id", class_id).eq(
        "slot_id", slot_id).eq("date", dt.date.today().isoformat()).execute()
    check("test data removed", True)

    print(f"\n{'=' * 62}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
