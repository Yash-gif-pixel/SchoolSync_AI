"""Rules about leave that more than one route needs.

A teacher cannot be on two overlapping leaves at once. Leave arrives by two
doors — the form in the teacher portal, and a scanned medical note committed
through the document reader — and both must refuse a clash the same way.
Keeping the check here is what stops the second door being forgotten, which is
exactly what happened when it lived inside the leave router.
"""

from __future__ import annotations

import datetime as dt

LIVE_STATUSES = ["pending_incharge", "approved"]


def fmt_date(d: dt.date) -> str:
    return d.strftime("%d %b %Y")


def overlapping_leave(
    sb,
    teacher_id: str,
    start: dt.date,
    end: dt.date,
    exclude_id: str | None = None,
) -> list[dict]:
    """Live requests for this teacher clashing with the given dates.

    Two ranges overlap when each starts on or before the other ends. Only
    pending and approved leave counts — a rejected or cancelled request must
    never stop someone re-applying for the same days.
    """
    rows = (sb.table("leave_requests")
            .select("id, from_date, to_date, status, reason")
            .eq("teacher_id", teacher_id)
            .in_("status", LIVE_STATUSES)
            .lte("from_date", end.isoformat())
            .gte("to_date", start.isoformat())
            .execute().data)
    return [r for r in rows if r["id"] != exclude_id]


def describe_clash(row: dict, *, subject: str = "You have") -> str:
    """A message that says which dates already exist and what state they're in."""
    c_from = dt.date.fromisoformat(row["from_date"])
    c_to = dt.date.fromisoformat(row["to_date"])
    span = fmt_date(c_from) if c_from == c_to else f"{fmt_date(c_from)} to {fmt_date(c_to)}"
    state = "already approved" if row["status"] == "approved" \
        else "already awaiting approval"
    reason = f" ({row['reason']})" if row.get("reason") else ""
    return (f"{subject} leave {state} for {span}{reason}. "
            f"Cancel that request first if the dates have changed.")
