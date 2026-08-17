"""Supabase Storage helpers.

Every bucket this project uses is private, and the client never talks to
storage directly — it is handed a short-lived signed URL by the API. That is
what keeps a scanned admission form, which has a child's name, address and
guardian's phone number on it, from being one guessable path away from anyone
who happens to be signed in.
"""

from __future__ import annotations

import logging

from ..db import admin

log = logging.getLogger(__name__)

#: An hour. Long enough to review a document or scroll a roll of 1,800
#: students; short enough that a URL pasted into a chat expires on its own.
DEFAULT_TTL = 3600


def signed_url(bucket: str, path: str | None, seconds: int = DEFAULT_TTL) -> str | None:
    """A time-limited URL for one object, or None if it cannot be signed.

    Returns None rather than raising: a missing thumbnail should leave a
    placeholder on the page, not fail the whole roster request.
    """
    if not path:
        return None
    try:
        res = admin().storage.from_(bucket).create_signed_url(path, seconds)
    except Exception as e:  # noqa: BLE001
        log.warning("Could not sign %s/%s: %s", bucket, path, e)
        return None
    # The SDK has spelled this key three ways across releases.
    return res.get("signedURL") or res.get("signedUrl") or res.get("signed_url")


def signed_urls(bucket: str, paths: list[str | None],
                seconds: int = DEFAULT_TTL) -> dict[str, str]:
    """Sign many objects at once, keyed by path.

    One round trip per object is fine for a single document and ruinous for a
    roster: 45 pupils meant 45 sequential calls to Supabase before the page
    could render. Duplicates are collapsed, and anything that fails to sign is
    simply absent from the result.
    """
    wanted = sorted({p for p in paths if p})
    if not wanted:
        return {}

    try:
        rows = admin().storage.from_(bucket).create_signed_urls(wanted, seconds)
    except Exception as e:  # noqa: BLE001
        log.warning("Batch signing failed for %s (%d paths): %s",
                    bucket, len(wanted), e)
        return {}

    out: dict[str, str] = {}
    for row in rows or []:
        url = (row.get("signedURL") or row.get("signedUrl")
               or row.get("signed_url"))
        # The batch API echoes the path back; older releases spell it "path".
        key = row.get("path") or row.get("Key") or row.get("key")
        if url and key:
            out[key.removeprefix(f"{bucket}/")] = url
    return out
