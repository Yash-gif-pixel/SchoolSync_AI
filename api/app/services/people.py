"""Matching a name written on paper to a member of staff.

A medical note says "Nisha Nair". The database has 55 teachers. Turning one
into the other is where a document pipeline quietly goes wrong: pick the
nearest match and you file someone else's sick leave, refuse everything
imperfect and the feature is useless.

So: resolve confidently or not at all, and when not, say who it might have
been. Validation and commit both call this, so the review screen can never
promise something the commit will refuse.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass


@dataclass
class NameMatch:
    resolved_id: str | None
    resolved_name: str | None
    candidates: list[dict]      # [{id, full_name}] when ambiguous or near
    reason: str                 # 'exact' | 'unique_partial' | 'ambiguous' | 'none'

    @property
    def ok(self) -> bool:
        return self.resolved_id is not None


def normalise(name: str | None) -> str:
    """Lowercase, strip accents, drop honorifics and punctuation."""
    if not name:
        return ""
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    s = re.sub(r"\b(mr|mrs|ms|miss|dr|prof|shri|smt|sri)\.?\b", " ", s)
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def _tokens(name: str) -> set[str]:
    return {t for t in normalise(name).split() if len(t) > 1}


def _edit_distance(a: str, b: str) -> int:
    """Levenshtein, for "did you mean" only — never to auto-pick a match."""
    if a == b:
        return 0
    if not a or not b:
        return max(len(a), len(b))
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def resolve_person(written: str | None, people: list[dict]) -> NameMatch:
    """Find the one person `written` refers to, or report why we cannot.

    `people` is [{id, full_name}]. Deliberately conservative: a fuzzy near-miss
    is offered as a suggestion, never chosen automatically.
    """
    if not written or not written.strip():
        return NameMatch(None, None, [], "none")

    target = normalise(written)
    if not target:
        return NameMatch(None, None, [], "none")

    # 1. Exact, on the normalised form.
    exact = [p for p in people if normalise(p.get("full_name")) == target]
    if len(exact) == 1:
        return NameMatch(exact[0]["id"], exact[0]["full_name"], [], "exact")
    if len(exact) > 1:
        return NameMatch(None, None, _slim(exact), "ambiguous")

    # 2. One person whose name contains every token written, or vice versa.
    #    Catches "Nisha" for "Nisha Nair", and "Nisha Nair (Science)".
    want = _tokens(written)
    partial = [
        p for p in people
        if want and (want <= _tokens(p.get("full_name", ""))
                     or _tokens(p.get("full_name", "")) <= want)
    ]
    if len(partial) == 1:
        return NameMatch(partial[0]["id"], partial[0]["full_name"], [], "unique_partial")
    if len(partial) > 1:
        return NameMatch(None, None, _slim(partial), "ambiguous")

    # 3. Nothing matched. Offer the closest few so a human can pick.
    scored = sorted(
        ((_edit_distance(target, normalise(p.get("full_name"))), p) for p in people),
        key=lambda t: t[0],
    )
    near = [p for dist, p in scored[:3] if dist <= max(3, len(target) // 3)]
    return NameMatch(None, None, _slim(near), "none")


def _slim(people: list[dict]) -> list[dict]:
    return [{"id": p["id"], "full_name": p.get("full_name", "")} for p in people]
