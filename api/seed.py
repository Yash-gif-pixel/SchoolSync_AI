"""
Seed the demo school.

Run AFTER db/001_schema.sql and db/002_rls.sql have been applied.
Uses the service_role key, which bypasses RLS by design.

    python seed.py --reset

Scale (see docstring table in build_curriculum for the arithmetic):
    20 classes (6-10 x A-D) | 900 students | 36 teachers | 7 departments
    36 teaching slots/week  | 90 days of leave history | 10 days attendance
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import random
import sys
from collections import defaultdict
from pathlib import Path

from dotenv import load_dotenv
from supabase import Client, create_client

load_dotenv(Path(__file__).with_name(".env"))

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DEMO_PASSWORD = "Demo@12345"

random.seed(20260806)  # deterministic demo data

sb: Client = create_client(SUPABASE_URL, SERVICE_KEY)


# ---------------------------------------------------------------- helpers
def log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def step(msg: str) -> None:
    print(f"\n>>> {msg}", flush=True)


def insert(table: str, rows: list[dict], chunk: int = 500) -> list[dict]:
    """Insert in chunks and return all created rows."""
    out: list[dict] = []
    for i in range(0, len(rows), chunk):
        res = sb.table(table).insert(rows[i : i + chunk]).execute()
        out.extend(res.data)
    return out


def school_days(start: dt.date, end: dt.date):
    """Mon-Sat are school days; Sunday is not."""
    d = start
    while d <= end:
        if d.weekday() != 6:
            yield d
        d += dt.timedelta(days=1)


# ---------------------------------------------------------------- reset
TABLES_IN_DELETE_ORDER = [
    "substitutions",
    "attendance",
    "timetable_entries",
    "timetable_versions",
    "leave_requests",
    "teaching_assignments",
    "students",
    "documents",
    "calendar_events",
    "classes",
    "time_slots",
    "rooms",
    "subjects",
    "profiles",
    "departments",
]


def reset() -> None:
    step("Resetting existing data")
    for t in TABLES_IN_DELETE_ORDER:
        sb.table(t).delete().gte("id", "00000000-0000-0000-0000-000000000000").execute()
        log(f"cleared {t}")

    # auth users are not in a normal table; remove the demo ones explicitly
    page = sb.auth.admin.list_users()
    removed = 0
    for u in page:
        if u.email and u.email.endswith("@school.test"):
            sb.auth.admin.delete_user(u.id)
            removed += 1
    log(f"deleted {removed} demo auth users")


# ---------------------------------------------------------------- reference
DEPARTMENTS = [
    "Maths",
    "Science",
    "English",
    "Hindi",
    "Social Studies",
    "Computer Science",
    "Physical Education",
]

# 6 core examined subjects + PE as a timetabled non-core subject.
SUBJECTS = [
    # (name,               code,   department,           is_core)
    ("Maths",              "MATH", "Maths",              True),
    ("Science",            "SCI",  "Science",            True),
    ("English",            "ENG",  "English",            True),
    ("Hindi",              "HIN",  "Hindi",              True),
    ("Social Studies",     "SST",  "Social Studies",     True),
    ("Computer Science",   "CS",   "Computer Science",   True),
    ("Physical Education", "PE",   "Physical Education", False),
]

# slot_index -> (start, end, is_break, label). 6 teaching periods per day.
DAY_STRUCTURE = [
    (1, "08:00", "08:45", False, "Period 1"),
    (2, "08:45", "09:30", False, "Period 2"),
    (3, "09:30", "09:50", True,  "Short Break"),
    (4, "09:50", "10:35", False, "Period 3"),
    (5, "10:35", "11:20", False, "Period 4"),
    (6, "11:20", "12:00", True,  "Lunch"),
    (7, "12:00", "12:45", False, "Period 5"),
    (8, "12:45", "13:30", False, "Period 6"),
]

GRADES = [6, 7, 8, 9, 10]
SECTIONS = ["A", "B", "C", "D"]


def seed_reference() -> dict:
    step("Seeding reference data")

    depts = insert("departments", [{"name": n} for n in DEPARTMENTS])
    dept_by_name = {d["name"]: d["id"] for d in depts}
    log(f"{len(depts)} departments")

    subs = insert(
        "subjects",
        [
            {
                "name": n,
                "code": c,
                "department_id": dept_by_name[d],
                "is_core": core,
            }
            for n, c, d, core in SUBJECTS
        ],
    )
    subject_by_code = {s["code"]: s for s in subs}
    log(f"{len(subs)} subjects ({sum(1 for s in subs if s['is_core'])} core + PE)")

    # 20 home rooms + the scarce rooms the solver actually has to ration
    room_rows = [
        {"name": f"Room {g}{s}", "type": "home", "capacity": 50}
        for g in GRADES
        for s in SECTIONS
    ]
    room_rows += [
        {"name": "Science Lab 1", "type": "science_lab", "capacity": 40},
        {"name": "Science Lab 2", "type": "science_lab", "capacity": 40},
        {"name": "Computer Lab", "type": "computer_lab", "capacity": 40},
        {"name": "Sports Ground", "type": "sports", "capacity": 200},
    ]
    rooms = insert("rooms", room_rows)
    room_by_name = {r["name"]: r for r in rooms}
    log(f"{len(rooms)} rooms (2 science labs + 1 computer lab are the scarce ones)")

    slot_rows = [
        {
            "day_of_week": dow,
            "slot_index": idx,
            "start_time": start,
            "end_time": end,
            "is_break": is_break,
            "label": label,
        }
        for dow in range(1, 7)  # Mon-Sat
        for idx, start, end, is_break, label in DAY_STRUCTURE
    ]
    slots = insert("time_slots", slot_rows)
    teaching = [s for s in slots if not s["is_break"]]
    log(f"{len(slots)} slots, {len(teaching)} teaching ({len(teaching)//6}/day x 6 days)")

    class_rows = [
        {
            "grade": g,
            "section": s,
            "home_room_id": room_by_name[f"Room {g}{s}"]["id"],
        }
        for g in GRADES
        for s in SECTIONS
    ]
    classes = insert("classes", class_rows)
    log(f"{len(classes)} classes")

    return {
        "departments": dept_by_name,
        "subjects": subject_by_code,
        "rooms": rooms,
        "slots": slots,
        "classes": classes,
    }


# ---------------------------------------------------------------- curriculum
# Periods per week per class. Must total 36 (the teaching-slot count), and
# lab demand must stay inside lab capacity:
#
#   science practical : 20 classes x 2 = 40  <= 2 labs x 36 slots = 72   OK
#   computer lab      : 20 classes x 1 = 20  <= 1 lab  x 36 slots = 36   OK
#
#   MATH 7 | SCI 5+2lab | ENG 6 | HIN 5 | SST 5 | CS 2+1lab | PE 3  = 36
CURRICULUM = [
    # (subject_code, periods_per_week, requires_lab)
    ("MATH", 7, False),
    ("SCI",  5, False),
    ("SCI",  2, True),   # practical
    ("ENG",  6, False),
    ("HIN",  5, False),
    ("SST",  5, False),
    ("CS",   2, False),
    ("CS",   1, True),   # computer lab
    ("PE",   3, False),
]

# Teachers per department, sized so each carries ~20 of 36 possible periods.
#   MATH 20x7=140 -> 7 | SCI 20x7=140 -> 7 | ENG 120 -> 6 | HIN 100 -> 5
#   SST 100 -> 5 | CS 60 -> 3 | PE 60 -> 3          = 36 teachers, 720 periods
TEACHERS_PER_DEPT = {
    "Maths": 7,
    "Science": 7,
    "English": 6,
    "Hindi": 5,
    "Social Studies": 5,
    "Computer Science": 3,
    "Physical Education": 3,
}

FIRST_NAMES = [
    "Aarav", "Vivaan", "Aditya", "Vihaan", "Arjun", "Sai", "Reyansh", "Krishna",
    "Ishaan", "Rudra", "Ananya", "Diya", "Aadhya", "Saanvi", "Pari", "Anika",
    "Navya", "Riya", "Meera", "Kavya", "Rohan", "Kabir", "Advait", "Dhruv",
    "Neha", "Priya", "Sneha", "Pooja", "Nisha", "Ritika", "Karan", "Manav",
    "Tanvi", "Isha", "Shreya", "Lakshmi", "Rahul", "Amit", "Sunita", "Deepak",
]
LAST_NAMES = [
    "Sharma", "Verma", "Gupta", "Iyer", "Nair", "Reddy", "Patel", "Singh",
    "Chauhan", "Joshi", "Mehta", "Kulkarni", "Das", "Bose", "Rao", "Pillai",
    "Malhotra", "Kapoor", "Banerjee", "Chatterjee", "Desai", "Shetty",
]


def seed_staff(ref: dict) -> dict:
    step("Seeding staff (auth users + profiles)")

    used_emails: set[str] = set()

    def make_email(first: str, last: str) -> str:
        base = f"{first}.{last}".lower()
        email, n = f"{base}@school.test", 1
        while email in used_emails:
            n += 1
            email = f"{base}{n}@school.test"
        used_emails.add(email)
        return email

    def create_auth_user(email: str, name: str, role: str) -> str:
        res = sb.auth.admin.create_user(
            {
                "email": email,
                "password": DEMO_PASSWORD,
                "email_confirm": True,
                "user_metadata": {"full_name": name, "role": role},
            }
        )
        return res.user.id

    profiles: list[dict] = []

    # one admin
    admin_email = "admin@school.test"
    used_emails.add(admin_email)
    admin_id = create_auth_user(admin_email, "Principal Sharma", "admin")
    profiles.append(
        {
            "id": admin_id,
            "full_name": "Principal Sharma",
            "employee_code": "ADM001",
            "role": "admin",
            "department_id": None,
            "is_approver": True,
            "phone": "9800000001",
        }
    )

    # teachers, with the first in each department flagged as HOD
    teachers_by_dept: dict[str, list[dict]] = defaultdict(list)
    counter = 0
    for dept, count in TEACHERS_PER_DEPT.items():
        for i in range(count):
            counter += 1
            first = random.choice(FIRST_NAMES)
            last = random.choice(LAST_NAMES)
            name = f"{first} {last}"
            email = make_email(first, last)
            uid = create_auth_user(email, name, "teacher")
            is_hod = i == 0
            row = {
                "id": uid,
                "full_name": name,
                "employee_code": f"TCH{counter:03d}",
                "role": "teacher",
                "department_id": ref["departments"][dept],
                "is_approver": is_hod,
                "phone": f"98{random.randint(10000000, 99999999)}",
            }
            profiles.append(row)
            teachers_by_dept[dept].append(row)
        log(f"{dept:<20} {count} teachers (1 HOD)")

    insert("profiles", profiles)
    log(f"{len(profiles)} profiles total (1 admin + {counter} teachers)")
    log(f"login: admin@school.test / {DEMO_PASSWORD}")

    return {"admin_id": admin_id, "by_dept": teachers_by_dept, "all": profiles}


def seed_students(ref: dict) -> list[dict]:
    step("Seeding students")
    rows = []
    for cls in ref["classes"]:
        for roll in range(1, 46):  # 45 per class
            first = random.choice(FIRST_NAMES)
            last = random.choice(LAST_NAMES)
            age = 5 + cls["grade"]
            rows.append(
                {
                    "full_name": f"{first} {last}",
                    "class_id": cls["id"],
                    "roll_no": roll,
                    "date_of_birth": str(
                        dt.date(2026 - age, random.randint(1, 12), random.randint(1, 28))
                    ),
                    "gender": random.choice(["M", "F"]),
                    "guardian_name": f"{random.choice(FIRST_NAMES)} {last}",
                    "guardian_phone": f"9{random.randint(100000000, 999999999)}",
                    "address": f"{random.randint(1, 200)}, Sector {random.randint(1, 40)}",
                    "admission_date": str(dt.date(2026 - (cls["grade"] - 5), 4, 1)),
                }
            )
    students = insert("students", rows)
    log(f"{len(students)} students across {len(ref['classes'])} classes (45 each)")
    return students


def seed_assignments(ref: dict, staff: dict) -> list[dict]:
    step("Seeding teaching assignments")

    dept_of_subject = {code: dept for _, code, dept, _ in SUBJECTS}
    load: dict[str, int] = defaultdict(int)
    rows = []

    for cls in ref["classes"]:
        for code, periods, needs_lab in CURRICULUM:
            dept = dept_of_subject[code]
            pool = staff["by_dept"][dept]
            # least-loaded teacher in the owning department
            teacher = min(pool, key=lambda t: load[t["id"]])
            load[teacher["id"]] += periods
            rows.append(
                {
                    "teacher_id": teacher["id"],
                    "class_id": cls["id"],
                    "subject_id": ref["subjects"][code]["id"],
                    "periods_per_week": periods,
                    "requires_lab": needs_lab,
                }
            )

    assignments = insert("teaching_assignments", rows)

    total = sum(load.values())
    loads = sorted(load.values())
    log(f"{len(assignments)} assignments, {total} teacher-periods/week")
    log(f"load per teacher: min {loads[0]}, median {loads[len(loads)//2]}, max {loads[-1]} (of 36)")
    lab_periods = sum(p for _, p, lab in CURRICULUM if lab) * len(ref["classes"])
    log(f"lab demand {lab_periods}/week vs capacity 108 (2 science + 1 computer lab x 36)")
    return assignments


def seed_calendar() -> list[dict]:
    step("Seeding calendar events")
    today = dt.date.today()
    events = [
        ("Annual Day Rehearsal", today + dt.timedelta(days=18), "event", 12),
        ("Sports Day", today + dt.timedelta(days=32), "event", 15),
        ("Half-Yearly Exams Begin", today + dt.timedelta(days=45), "exam", 20),
        ("Parent-Teacher Meeting", today + dt.timedelta(days=9), "meeting", 8),
        ("Science Exhibition", today + dt.timedelta(days=25), "event", 10),
        ("Staff Training Workshop", today + dt.timedelta(days=5), "training", 6),
        ("Independence Day", today + dt.timedelta(days=9), "holiday", 0),
    ]
    rows = [
        {"name": n, "date": str(d), "event_type": t, "teachers_required": r}
        for n, d, t, r in events
    ]
    out = insert("calendar_events", rows)
    log(f"{len(out)} events over the next 45 days")
    return out


def seed_leave_history(staff: dict) -> list[dict]:
    """90 days of teacher leave with the patterns the Phase 4 forecast looks for:
    Monday/Friday spikes, a flu week, and heavier load in some departments."""
    step("Seeding 90 days of leave history")

    today = dt.date.today()
    start = today - dt.timedelta(days=90)
    teachers = [p for p in staff["all"] if p["role"] == "teacher"]
    hod_by_dept = {
        p["department_id"]: p["id"] for p in staff["all"] if p.get("is_approver")
    }

    flu_start = today - dt.timedelta(days=40)
    flu_end = flu_start + dt.timedelta(days=7)

    reasons = [
        "Fever and cold", "Medical appointment", "Family function",
        "Personal work", "Child unwell", "Travel", "Viral fever",
    ]

    rows = []
    for day in school_days(start, today - dt.timedelta(days=1)):
        base = 0.035
        if day.weekday() == 0:      # Monday
            base *= 1.8
        elif day.weekday() == 5:    # Saturday
            base *= 1.5
        elif day.weekday() == 4:    # Friday
            base *= 1.4
        if flu_start <= day <= flu_end:
            base *= 3.0

        for t in teachers:
            if random.random() < base:
                span = random.choices([1, 1, 1, 2, 3], k=1)[0]
                rows.append(
                    {
                        "teacher_id": t["id"],
                        "from_date": str(day),
                        "to_date": str(day + dt.timedelta(days=span - 1)),
                        "reason": random.choice(reasons),
                        "status": "approved",
                        "reviewed_by": hod_by_dept.get(t["department_id"]),
                        "reviewed_at": f"{day}T07:30:00+00:00",
                    }
                )

    out = insert("leave_requests", rows)
    log(f"{len(out)} approved leave requests over 90 days")
    log(f"flu week seeded {flu_start} -> {flu_end} (3x baseline)")
    return out


def seed_attendance(ref: dict, students: list[dict], staff: dict) -> None:
    """Recent student attendance, first teaching period only.

    Deliberately NOT every period: 900 students x 6 periods x 90 days would be
    ~486k rows, which is slow over PostgREST and wasteful on the free tier.
    History here is cosmetic -- the Phase 4 forecast reads teacher leave, not
    student attendance -- so 10 days of first-period marks is enough to make
    the dashboard look lived-in.
    """
    step("Seeding recent student attendance")

    first_slot_by_dow = {}
    for s in ref["slots"]:
        if not s["is_break"]:
            k = s["day_of_week"]
            if k not in first_slot_by_dow or s["slot_index"] < first_slot_by_dow[k]["slot_index"]:
                first_slot_by_dow[k] = s

    by_class = defaultdict(list)
    for s in students:
        by_class[s["class_id"]].append(s)

    today = dt.date.today()
    days = list(school_days(today - dt.timedelta(days=14), today - dt.timedelta(days=1)))[-10:]

    rows = []
    for day in days:
        slot = first_slot_by_dow[day.isoweekday()]
        for class_id, kids in by_class.items():
            for st in kids:
                r = random.random()
                status = "present" if r < 0.93 else ("absent" if r < 0.985 else "late")
                rows.append(
                    {
                        "student_id": st["id"],
                        "class_id": class_id,
                        "slot_id": slot["id"],
                        "date": str(day),
                        "status": status,
                        "marked_by": staff["admin_id"],
                    }
                )

    insert("attendance", rows, chunk=1000)
    absent = sum(1 for r in rows if r["status"] != "present")
    log(f"{len(rows)} records over {len(days)} days ({absent} not present, ~{absent*100//len(rows)}%)")


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reset", action="store_true", help="wipe existing data first")
    args = ap.parse_args()

    print(f"Target: {SUPABASE_URL}")

    if args.reset:
        reset()
    else:
        existing = sb.table("departments").select("id").limit(1).execute()
        if existing.data:
            print("\nDatabase already has data. Re-run with --reset to wipe and reseed.")
            return 1

    ref = seed_reference()
    staff = seed_staff(ref)
    students = seed_students(ref)
    seed_assignments(ref, staff)
    seed_calendar()
    seed_leave_history(staff)
    seed_attendance(ref, students, staff)

    step("Done")
    log(f"admin login : admin@school.test / {DEMO_PASSWORD}")
    sample = staff["by_dept"]["Science"][0]
    log(f"HOD login   : (Science HOD) {sample['full_name']} — see profiles table for email")
    log(f"all demo passwords: {DEMO_PASSWORD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
