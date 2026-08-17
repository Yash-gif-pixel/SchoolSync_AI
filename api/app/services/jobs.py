"""Long jobs that must not be held open on an HTTP socket.

Solving a timetable takes 20–45 seconds of CPU. Doing that inside a request
has two separate problems, and only one of them is about speed:

* **The connection.** Reverse proxies and platform gateways cut idle-looking
  requests well before that — Cloudflare's default is 100s but many tiers cut
  at 30, and the client sees a bare 504 with no way to find out whether the
  solve actually finished. It usually did.
* **The event loop.** CP-SAT is synchronous C++ in a `def` endpoint. FastAPI
  runs those in a threadpool, so the loop survives, but the request still owns
  a worker for the whole solve.

So: submit returns immediately with a job id, the work runs on a thread, and
the caller polls. The HTTP request is short whatever the solver does.

**This registry lives in the process.** Jobs do not survive a restart and are
not visible to a second replica. That is a deliberate fit to how this deploys
— one container on Render, which sleeps rather than scales — and not a
general-purpose queue. Running more than one replica means moving this to
Redis (ARQ or Celery); the endpoint contract is already the right shape for
that, which is the point of putting it behind a small interface here.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import threading
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Callable

log = logging.getLogger(__name__)

#: Finished jobs kept for polling after the fact. A timetable result is a few
#: hundred KB, so this is bounded rather than left to grow for the life of the
#: process.
MAX_REMEMBERED = 20

QUEUED, RUNNING, DONE, FAILED = "queued", "running", "done", "failed"


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


@dataclass
class Job:
    id: str
    kind: str
    submitted_by: str | None
    status: str = QUEUED
    created_at: str = field(default_factory=_now)
    started_at: str | None = None
    finished_at: str | None = None
    result: Any = None
    error: str | None = None

    @property
    def finished(self) -> bool:
        return self.status in (DONE, FAILED)

    def as_dict(self, include_result: bool = True) -> dict:
        out = {
            "job_id": self.id,
            "kind": self.kind,
            "status": self.status,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "error": self.error,
        }
        if include_result:
            out["result"] = self.result
        return out


class JobRegistry:
    def __init__(self) -> None:
        self._jobs: OrderedDict[str, Job] = OrderedDict()
        # Guards the dict against the worker thread writing a result while a
        # request thread is reading it.
        self._lock = threading.Lock()

    # ------------------------------------------------------------ reading
    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def recent(self, kind: str | None = None, limit: int = 10) -> list[Job]:
        with self._lock:
            jobs = list(self._jobs.values())
        if kind:
            jobs = [j for j in jobs if j.kind == kind]
        return list(reversed(jobs))[:limit]

    def running(self, kind: str) -> Job | None:
        """The live job of this kind, if there is one.

        Used to refuse a second concurrent solve. Two CP-SAT runs on one small
        container do not go twice as fast; they take each other's cores and
        both miss their time budget.
        """
        with self._lock:
            for j in reversed(self._jobs.values()):
                if j.kind == kind and j.status in (QUEUED, RUNNING):
                    return j
        return None

    # ------------------------------------------------------------ writing
    def _remember(self, job: Job) -> None:
        with self._lock:
            self._jobs[job.id] = job
        self._cull()

    def _cull(self) -> None:
        """Drop the oldest finished jobs once there are too many.

        Run when a job is submitted AND when one finishes. Culling on submit
        alone is not enough: a burst of jobs is all still running at the
        moment each one is added, so nothing is evictable then, and the
        registry stays over its cap until somebody happens to submit again.
        """
        with self._lock:
            while len(self._jobs) > MAX_REMEMBERED:
                # Never evict something still running, however old it looks —
                # its poller has nowhere else to get the answer.
                victim = next(
                    (k for k, v in self._jobs.items() if v.finished), None)
                if victim is None:
                    return
                del self._jobs[victim]

    async def submit(
        self,
        kind: str,
        work: Callable[[], Any],
        submitted_by: str | None = None,
    ) -> Job:
        """Start `work` on a worker thread and hand back the job immediately."""
        job = Job(id=str(uuid.uuid4()), kind=kind, submitted_by=submitted_by)
        self._remember(job)

        async def run() -> None:
            job.status = RUNNING
            job.started_at = _now()
            try:
                job.result = await asyncio.to_thread(work)
                job.status = DONE
            except Exception as e:  # noqa: BLE001 — the job records its failure
                job.status = FAILED
                job.error = f"{type(e).__name__}: {e}"
                log.exception("Job %s (%s) failed", job.id, kind)
            finally:
                job.finished_at = _now()
                self._cull()

        # Held so the task is not garbage-collected mid-flight; asyncio keeps
        # only a weak reference to tasks nobody awaits.
        task = asyncio.create_task(run())
        _live.add(task)
        task.add_done_callback(_live.discard)

        return job


_live: set[asyncio.Task] = set()

#: One registry per process.
jobs = JobRegistry()
