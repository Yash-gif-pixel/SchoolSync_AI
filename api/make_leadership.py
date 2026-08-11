"""Create the school's leadership accounts.

    python make_leadership.py

Auth users cannot be created from SQL, so the columns land in
db/009_vice_principal.sql and db/010_principal.sql and the accounts are made
here. Re-runnable: existing accounts are reused and repointed rather than
duplicated.

Both are members of teaching staff, not administrators. The admin account is
office staff who runs the software; the principal runs the school. Keeping
those separate is the whole reason these are flags on an ordinary profile.
"""

from __future__ import annotations

import sys

from app.db import admin

PASSWORD = "Demo@12345"

POSTS = [
    {
        "column": "is_principal",
        "title": "Principal",
        "email": "principal@school.test",
        "name": "Meera Raghavan",
        # The principal keeps a light teaching load but sits outside the
        # departmental approval chain.
        "is_approver": False,
    },
    {
        "column": "is_vice_principal",
        "title": "Vice Principal",
        "email": "vp@school.test",
        "name": "Farida Qureshi",
        "is_approver": False,
    },
]


def find_auth_user(email: str) -> str | None:
    """list_users() pages at 50, and this school has more staff than that —
    the same trap that once hid 23 of 72 teachers."""
    page = 1
    while True:
        users = admin().auth.admin.list_users(page=page, per_page=200)
        if not users:
            return None
        for u in users:
            if (u.email or "").lower() == email.lower():
                return u.id
        if len(users) < 200:
            return None
        page += 1


def ensure(post: dict, department_id: str | None) -> None:
    sb = admin()
    uid = find_auth_user(post["email"])
    if uid:
        print(f"  reusing {post['email']}")
        sb.auth.admin.update_user_by_id(uid, {"password": PASSWORD})
    else:
        print(f"  creating {post['email']}")
        uid = sb.auth.admin.create_user({
            "email": post["email"],
            "password": PASSWORD,
            "email_confirm": True,
            "user_metadata": {"full_name": post["name"], "role": "teacher"},
        }).user.id

    row = {
        "full_name": post["name"],
        "role": "teacher",
        "department_id": department_id,
        "is_approver": post["is_approver"],
        post["column"]: True,
    }

    # The unique index allows only one holder, so stand everyone else down
    # before promoting this account.
    sb.table("profiles").update({post["column"]: False}) \
        .eq(post["column"], True).neq("id", uid).execute()

    existing = (sb.table("profiles").select("id")
                .eq("id", uid).maybe_single().execute())
    if existing and existing.data:
        sb.table("profiles").update(row).eq("id", uid).execute()
    else:
        sb.table("profiles").insert({"id": uid, **row}).execute()
    print(f"    {post['title']}: {post['name']}")


def main() -> int:
    sb = admin()

    for post in POSTS:
        try:
            sb.table("profiles").select(post["column"]).limit(1).execute()
        except Exception:
            print(f"! profiles.{post['column']} is missing — apply the "
                  f"migrations in db/ first.")
            return 1

    dept = (sb.table("departments").select("id, name")
            .order("name").limit(1).execute().data or [])
    department_id = dept[0]["id"] if dept else None

    for post in POSTS:
        ensure(post, department_id)

    admin_row = (sb.table("profiles").select("full_name")
                 .eq("role", "admin").limit(1).execute().data or [])
    print()
    for post in POSTS:
        print(f"  {post['title']:<15}: {post['name']} <{post['email']}>")
    if admin_row:
        print(f"  {'Administrator':<15}: {admin_row[0]['full_name']} "
              f"<admin@school.test>")
    print(f"\n  All passwords: {PASSWORD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
