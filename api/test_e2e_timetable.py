"""End-to-end test of the timetable API against the running server.

    python test_e2e_timetable.py

Generates a real timetable, verifies it independently from the database,
and checks the teacher and class views agree with the master grid.
"""

from __future__ import annotations

import os
import sys
import time
from collections import defaultdict
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"

# Must match DEFAULT_TIME_LIMIT in app/services/timetable.py.
#
# The solver splits its budget: phase 1 (strict feasibility) gets
# min(limit, max(12, limit * 0.4)). This school — 40 classes, 57 staff, 320
# assignments under a 5-periods-a-day cap — needs about 14.5s to pack the
# curriculum, so a 20s budget clamps phase 1 to 12s, times out, falls back to
# relaxed packing and leaves ~90 periods unplaced. Testing with a smaller
# budget than production runs with was testing a different solver.
TIME_LIMIT = 45.0

# Wall clock is the budget plus the database round trips either side of it.
WALL_BUDGET = TIME_LIMIT + 8

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed = failed = 0


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
    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")
    A = {"Authorization": f"Bearer {admin_tok}"}
    T = {"Authorization": f"Bearer {teacher_tok}"}

    with httpx.Client(timeout=180) as c:
        print("\n1. Preflight — arithmetic before search")
        r = c.get(f"{API}/timetable/preflight", headers=A)
        check("preflight returns 200", r.status_code == 200)
        pf = r.json()
        check("the seeded school is solvable", pf["solvable"] is True,
              f"{pf['error_count']} errors")

        print("\n2. Authorisation")
        r = c.post(f"{API}/timetable/generate", headers=T, json={"time_limit": 5})
        check("teacher cannot generate (403)", r.status_code == 403, str(r.status_code))
        r = c.post(f"{API}/timetable/generate", json={"time_limit": 5})
        check("anonymous cannot generate (401)", r.status_code == 401, str(r.status_code))

        print("\n3. Generate")
        r = c.post(f"{API}/timetable/generate", headers=A,
                   json={"time_limit": TIME_LIMIT, "optimise_gaps": True,
                         "label": "e2e run"})
        if not check("generate returns 201", r.status_code == 201,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        out = r.json()
        s = out["stats"]

        check("every period was placed", out["placed_everything"] is True,
              f"{s.get('unplaced_periods')} unplaced")
        check("published as the live timetable", out["activated"] is True)
        check("no errors reported", out["error_count"] == 0,
              f"{out['error_count']} errors")
        check("ran inside the time budget", s["wall_seconds"] <= WALL_BUDGET,
              f"{s['wall_seconds']}s of {WALL_BUDGET}s")
        check("used the compact variable model", s["variables"] < 50_000,
              f"{s['variables']:,} variables")
        check("used strict packing on a well-staffed school",
              s.get("strict_packing") is True)
        check("both phases ran", s.get("phases") == 2, str(s.get("phases")))
        check("gap optimisation improved on phase one",
              s.get("gaps_before_optimising", 0) >= s.get("teacher_gaps", 0),
              f"{s.get('gaps_before_optimising')} -> {s.get('teacher_gaps')}")

        print("\n4. Verify the stored timetable independently")
        version_id = out["version_id"]

        # Paged deliberately: PostgREST caps a select at 1000 rows and a full
        # week is 1440, so an unpaged read would quietly lose a third of it.
        rows = []
        start = 0
        while True:
            page = sb.table("timetable_entries").select(
                "slot_id, room_id, teaching_assignments(teacher_id, class_id, "
                "subject_id, requires_lab, periods_per_week)"
            ).eq("version_id", version_id).range(start, start + 999).execute().data
            rows.extend(page)
            if len(page) < 1000:
                break
            start += 1000

        check("entries persisted", len(rows) == s["entries"],
              f"{len(rows)} rows vs {s['entries']} reported")

        teacher_slot = defaultdict(int)
        class_slot = defaultdict(int)
        room_slot = defaultdict(int)
        for row in rows:
            a = row["teaching_assignments"]
            teacher_slot[a["teacher_id"], row["slot_id"]] += 1
            class_slot[a["class_id"], row["slot_id"]] += 1
            if row["room_id"]:
                room_slot[row["room_id"], row["slot_id"]] += 1

        check("no teacher double-booked in the database",
              max(teacher_slot.values()) == 1,
              f"max {max(teacher_slot.values())}")
        check("no class double-booked in the database",
              max(class_slot.values()) == 1, f"max {max(class_slot.values())}")
        check("no room double-booked in the database",
              max(room_slot.values()) == 1, f"max {max(room_slot.values())}")

        n_slots = len([x for x in sb.table("time_slots").select("is_break")
                       .execute().data if not x["is_break"]])
        n_classes = sb.table("classes").select("id", count="exact").limit(1).execute().count
        check("every class slot filled", len(rows) == n_slots * n_classes,
              f"{len(rows)} vs {n_slots * n_classes}")

        print("\n5. Exactly one active version")
        active = sb.table("timetable_versions").select("id").eq(
            "is_active", True).execute().data
        check("exactly one version is live", len(active) == 1, f"{len(active)}")
        check("it is the one just generated", active and active[0]["id"] == version_id)

        print("\n6. Views agree with the master grid")
        r = c.get(f"{API}/timetable/active", headers=T)
        check("a teacher can read the timetable (200)", r.status_code == 200)
        check("active view returns every entry",
              len(r.json()["entries"]) == len(rows))

        r = c.get(f"{API}/timetable/me", headers=T)
        check("teacher's own view returns 200", r.status_code == 200)
        mine = r.json()["entries"]
        check("the teacher has periods", len(mine) > 0, f"{len(mine)} periods")

        teacher_id = mine[0]["teaching_assignments"]["profiles"]["id"]
        expected = sum(
            1 for row in rows
            if row["teaching_assignments"]["teacher_id"] == teacher_id
        )
        check("their view matches the master grid", len(mine) == expected,
              f"{len(mine)} vs {expected}")

        days = {e["time_slots"]["day_of_week"] for e in mine}
        per_slot = defaultdict(int)
        for e in mine:
            per_slot[e["time_slots"]["day_of_week"], e["time_slots"]["slot_index"]] += 1
        check("no clash within their own week",
              max(per_slot.values()) == 1, f"max {max(per_slot.values())}")
        check("spread over multiple days", len(days) >= 2, f"{len(days)} days")

        any_class = rows[0]["teaching_assignments"]["class_id"]
        r = c.get(f"{API}/timetable/class/{any_class}", headers=T)
        check("class view returns 200", r.status_code == 200)
        check("a class's week is exactly full",
              len(r.json()["entries"]) == n_slots,
              f"{len(r.json()['entries'])} of {n_slots}")

        print("\n7. Versions")
        r = c.get(f"{API}/timetable/versions", headers=A)
        check("version history returns 200", r.status_code == 200)
        check("the new version is listed",
              any(v["id"] == version_id for v in r.json()))

        print("\n8. The same solve as a background job")
        # Short budget and activate=false: this is about the job mechanics,
        # not the timetable, and it must not disturb the live one published
        # above.
        job_opts = {"time_limit": 8, "optimise_gaps": False,
                    "activate": False, "label": "e2e job"}

        r = c.post(f"{API}/timetable/jobs", headers=T, json=job_opts)
        check("teacher cannot start a job (403)", r.status_code == 403,
              str(r.status_code))

        r = c.post(f"{API}/timetable/jobs", headers=A, json=job_opts)
        if not check("job accepted (202)", r.status_code == 202,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        started = r.json()
        job_id = started.get("job_id")
        check("returned a job id to poll", bool(job_id))
        check("said where to poll", started.get("poll", "").endswith(job_id))
        check("returned immediately, before the solve could finish",
              started["status"] in {"queued", "running"}, started["status"])

        # A second solve on the same machine would fight the first for cores.
        r = c.post(f"{API}/timetable/jobs", headers=A, json=job_opts)
        check("a concurrent solve is refused (409)", r.status_code == 409,
              str(r.status_code))

        deadline = time.monotonic() + 120
        job = None
        while time.monotonic() < deadline:
            time.sleep(2)
            r = c.get(f"{API}/timetable/jobs/{job_id}", headers=A)
            if r.status_code != 200:
                break
            job = r.json()
            if job["status"] in {"done", "failed"}:
                break

        if not check("the job finished", job is not None and job["status"] == "done",
                     job["status"] if job else f"HTTP {r.status_code}"):
            return 1

        check("no error recorded", job["error"] is None, str(job["error"]))
        check("the result carries the solve outcome",
              isinstance(job["result"], dict) and "version_id" in job["result"])
        check("it wrote a version", bool(job["result"]["version_id"]))
        check("and left the live timetable alone",
              job["result"]["activated"] is False)

        live = sb.table("timetable_versions").select("id").eq(
            "is_active", True).execute().data
        check("the published timetable is still the one from step 3",
              len(live) == 1 and live[0]["id"] == version_id)

        r = c.get(f"{API}/timetable/jobs", headers=A)
        check("the job appears in the job list", r.status_code == 200
              and any(j["job_id"] == job_id for j in r.json()))

        r = c.get(f"{API}/timetable/jobs/00000000-0000-0000-0000-000000000000",
                  headers=A)
        check("an unknown job is a 404", r.status_code == 404, str(r.status_code))

        # Housekeeping: the job's draft version is not wanted on the shelf.
        sb.table("timetable_entries").delete().eq(
            "version_id", job["result"]["version_id"]).execute()
        sb.table("timetable_versions").delete().eq(
            "id", job["result"]["version_id"]).execute()

    print(f"\n{'=' * 60}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
