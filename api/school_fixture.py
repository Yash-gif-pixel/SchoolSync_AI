"""A synthetic school in the shape the solver actually meets.

`load_school()` reads the seeded database, so every check on the timetable
engine needed Supabase credentials and a seeded project. That is a heavy
prerequisite for testing a pure function: `solve()` takes a dict and returns
entries, and touches nothing else.

This builds the same dict offline: the same six-day, 36-slot week, the same
curriculum, the same primary/secondary split, the same two science labs and
one computer lab, and classes whose curriculum exactly fills the week — which
is what lets the solver use `AddExactlyOne` and is the single most important
structural property to reproduce.

**It is a smaller school than the seeded one**: grades 1–6 rather than 1–10,
so 24 classes and 37 staff instead of 40 and 55. That is deliberate. The
40-class instance sits very close to its own feasibility limit — 40 of 55
teachers must be in front of a class in every one of the 36 slots, under a
hard five-a-day cap — and a fixture that sometimes fails to pack is worthless
as a regression test, because a real regression would look identical. At this
size the solve is comfortably strict and complete, so any failure means
something actually broke. Use the seeded database when the question is
specifically about the full-size instance.
"""

from __future__ import annotations

from collections import defaultdict

# --- mirrors seed.py -------------------------------------------------------
DEPARTMENTS = [
    "Maths", "Science", "English", "Hindi", "Social Studies",
    "Computer Science", "Physical Education",
]

# (name, code, department)
SUBJECTS = [
    ("Maths", "MATH", "Maths"),
    ("Science", "SCI", "Science"),
    ("English", "ENG", "English"),
    ("Hindi", "HIN", "Hindi"),
    ("Social Studies", "SST", "Social Studies"),
    ("Computer Science", "CS", "Computer Science"),
    ("Physical Education", "PE", "Physical Education"),
]

# Scaled from the seeded school's ratios, then eased slightly so no teacher
# lands within a period or two of the 30-a-week ceiling the daily cap implies.
# A fixture that is itself borderline tests the machine it runs on.
TEACHERS_PER_DEPT = {
    "Maths": 7, "Science": 6, "English": 7, "Hindi": 6,
    "Social Studies": 4, "Computer Science": 3, "Physical Education": 4,
}

# Grades 1–6: five primary years plus one secondary, so the practical and
# computer-lab periods — the only scarce room in the model — are exercised.
GRADES = list(range(1, 7))
SECTIONS = ["A", "B", "C", "D"]
PRIMARY_GRADES = {1, 2, 3, 4, 5}

DAYS = [1, 2, 3, 4, 5, 6]          # Monday to Saturday
PERIODS_PER_DAY = 6                 # excluding breaks

PRIMARY_CURRICULUM = [
    ("MATH", 7, False), ("SCI", 5, False), ("ENG", 7, False),
    ("HIN", 6, False), ("SST", 4, False), ("CS", 2, False), ("PE", 5, False),
]

SECONDARY_CURRICULUM = [
    ("MATH", 7, False), ("SCI", 5, False), ("SCI", 2, True),
    ("ENG", 6, False), ("HIN", 5, False), ("SST", 5, False),
    ("CS", 2, False), ("CS", 1, True), ("PE", 3, False),
]

LAB_TYPE_BY_SUBJECT_CODE = {"CS": "computer_lab", "SCI": "science_lab"}

SCIENCE_LABS, COMPUTER_LABS = 2, 1


def curriculum_for(grade: int):
    return PRIMARY_CURRICULUM if grade in PRIMARY_GRADES else SECONDARY_CURRICULUM


def build_school() -> dict:
    """The same shape `load_school()` returns, without a database."""
    subject_by_code = {
        code: {"id": f"sub-{code}", "name": name, "code": code,
               "department_id": f"dept-{dept}"}
        for name, code, dept in SUBJECTS
    }

    slots = [
        {
            "id": f"slot-{day}-{p}",
            "day_of_week": day,
            "slot_index": p,
            "is_break": False,
        }
        for day in DAYS
        for p in range(1, PERIODS_PER_DAY + 1)
    ]

    classes = [
        {
            "id": f"class-{g}{s}",
            "name": f"{g}{s}",
            "grade": g,
            "section": s,
            "home_room_id": f"room-{g}{s}",
        }
        for g in GRADES
        for s in SECTIONS
    ]

    teachers = []
    by_dept: dict[str, list[dict]] = defaultdict(list)
    for dept, count in TEACHERS_PER_DEPT.items():
        for i in range(count):
            t = {
                "id": f"t-{dept.replace(' ', '')}-{i}",
                "full_name": f"{dept} Teacher {i + 1}",
                "department_id": f"dept-{dept}",
            }
            teachers.append(t)
            by_dept[dept].append(t)

    dept_of_subject = {code: dept for _, code, dept in SUBJECTS}

    # Least-loaded teacher in the owning department, exactly as seed.py does —
    # the load distribution is what makes this problem hard, so an even
    # round-robin would be testing an easier school than the real one.
    load: dict[str, int] = defaultdict(int)
    assignments = []
    for cls in classes:
        for code, periods, needs_lab in curriculum_for(cls["grade"]):
            pool = by_dept[dept_of_subject[code]]
            teacher = min(pool, key=lambda t: load[t["id"]])
            load[teacher["id"]] += periods
            sub = subject_by_code[code]
            assignments.append({
                "id": f"a-{len(assignments)}",
                "teacher_id": teacher["id"],
                "class_id": cls["id"],
                "subject_id": sub["id"],
                "periods_per_week": periods,
                "requires_lab": needs_lab,
                "subject_name": sub["name"],
                "subject_code": code,
                "lab_type": (LAB_TYPE_BY_SUBJECT_CODE.get(code, "science_lab")
                             if needs_lab else None),
            })

    labs_by_type = {
        "science_lab": [f"lab-sci-{i}" for i in range(SCIENCE_LABS)],
        "computer_lab": [f"lab-com-{i}" for i in range(COMPUTER_LABS)],
    }

    return {
        "slots": slots,
        "classes": classes,
        "teachers": teachers,
        "assignments": assignments,
        "subjects": subject_by_code,
        "labs_by_type": labs_by_type,
        "lab_capacity": {k: len(v) for k, v in labs_by_type.items()},
        "home_room_by_class": {c["id"]: c["home_room_id"] for c in classes},
        "class_by_id": {c["id"]: c for c in classes},
        "teacher_by_id": {t["id"]: t for t in teachers},
        "unavailable": {},
    }


def describe(data: dict) -> str:
    periods = sum(a["periods_per_week"] for a in data["assignments"])
    return (f"{len(data['classes'])} classes, {len(data['teachers'])} teachers, "
            f"{len(data['assignments'])} assignments, "
            f"{len(data['slots'])} teaching slots, {periods} periods to place")


if __name__ == "__main__":
    print(describe(build_school()))
