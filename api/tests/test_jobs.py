"""The background job registry, tested without a server.

Solving a timetable moved off the request thread so a proxy could not kill it
mid-solve. That only helps if the registry itself is honest about what is
running, keeps results long enough to be collected, and never loses a job to
the garbage collector — which is what these check.
"""

from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services import jobs as jobs_module  # noqa: E402
from app.services.jobs import DONE, FAILED, JobRegistry, RUNNING  # noqa: E402


def run(coro):
    """asyncio.run, so these stay plain sync tests with no plugin needed."""
    return asyncio.run(coro)


async def _settle(registry: JobRegistry, job_id: str, timeout: float = 5.0):
    """Wait for a job to reach a terminal state."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = registry.get(job_id)
        if job and job.finished:
            return job
        await asyncio.sleep(0.01)
    raise AssertionError(f"job {job_id} never finished")


async def _drain(registry: JobRegistry, kind: str, timeout: float = 5.0):
    """Wait until no job of this kind is still working."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if registry.running(kind) is None:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"{kind} jobs never drained")


def test_result_is_returned_to_the_poller():
    async def scenario():
        registry = JobRegistry()
        job = await registry.submit("solve", lambda: {"version_id": "v1"})
        assert job.status in ("queued", RUNNING)
        assert job.result is None

        done = await _settle(registry, job.id)
        assert done.status == DONE
        assert done.result == {"version_id": "v1"}
        assert done.error is None
        assert done.finished_at is not None

    run(scenario())


def test_a_failure_is_recorded_not_raised():
    """The submitting request has already returned, so an exception has
    nowhere to go except onto the job."""

    async def scenario():
        registry = JobRegistry()

        def explode():
            raise ValueError("no teaching assignments")

        job = await registry.submit("solve", explode)
        done = await _settle(registry, job.id)

        assert done.status == FAILED
        assert done.result is None
        assert "no teaching assignments" in done.error
        assert "ValueError" in done.error

    run(scenario())


def test_work_runs_off_the_event_loop():
    """A blocking solve must not stall everything else in the process."""

    async def scenario():
        registry = JobRegistry()
        await registry.submit("solve", lambda: time.sleep(0.3) or "done")

        # If the work were on the loop, this would not get a turn for 300ms.
        start = time.monotonic()
        await asyncio.sleep(0)
        await asyncio.sleep(0.01)
        assert time.monotonic() - start < 0.2

    run(scenario())


def test_running_reports_the_live_job_of_that_kind():
    async def scenario():
        registry = JobRegistry()
        job = await registry.submit("solve", lambda: time.sleep(0.2))

        live = registry.running("solve")
        assert live is not None and live.id == job.id
        # A different kind of work is not the same queue.
        assert registry.running("export") is None

        await _settle(registry, job.id)
        assert registry.running("solve") is None

    run(scenario())


def test_finished_jobs_are_evicted_but_running_ones_are_not():
    async def scenario():
        registry = JobRegistry()
        keep = await registry.submit("slow", lambda: time.sleep(1.5))

        # Comfortably more than MAX_REMEMBERED quick jobs.
        quick = []
        for i in range(jobs_module.MAX_REMEMBERED + 5):
            quick.append(await registry.submit("quick", lambda i=i: i))

        # Waited on as a batch, not one at a time: the early ones are evicted
        # by the later ones finishing, so asking after them individually is
        # asking after something the cap has already dropped — which is the
        # behaviour under test.
        await _drain(registry, "quick")

        assert len(registry._jobs) <= jobs_module.MAX_REMEMBERED
        # The one still working survived the cull; the oldest finished did not.
        assert registry.get(keep.id) is not None
        assert registry.get(quick[0].id) is None
        # And the newest results are still collectable.
        assert registry.get(quick[-1].id).status == DONE

    run(scenario())


def test_recent_is_newest_first_and_filtered_by_kind():
    async def scenario():
        registry = JobRegistry()
        a = await registry.submit("solve", lambda: 1)
        b = await registry.submit("solve", lambda: 2)
        c = await registry.submit("export", lambda: 3)
        for j in (a, b, c):
            await _settle(registry, j.id)

        ids = [j.id for j in registry.recent("solve")]
        assert ids == [b.id, a.id]
        assert [j.id for j in registry.recent()][0] == c.id
        assert len(registry.recent(limit=2)) == 2

    run(scenario())


def test_the_task_is_held_so_it_cannot_be_collected_mid_flight():
    """asyncio holds only a weak reference to a task nobody awaits, so a
    long solve can be garbage-collected halfway through and simply vanish."""

    async def scenario():
        registry = JobRegistry()
        job = await registry.submit("solve", lambda: time.sleep(0.1) or "kept")
        assert jobs_module._live, "the running task is not referenced anywhere"

        done = await _settle(registry, job.id)
        assert done.result == "kept"
        # And the reference is released once it finishes.
        await asyncio.sleep(0.05)
        assert not jobs_module._live

    run(scenario())


@pytest.mark.parametrize("include", [True, False])
def test_listings_can_omit_the_large_result(include):
    async def scenario():
        registry = JobRegistry()
        job = await registry.submit("solve", lambda: {"entries": [1, 2, 3]})
        done = await _settle(registry, job.id)

        body = done.as_dict(include_result=include)
        assert ("result" in body) is include
        assert body["job_id"] == job.id
        assert body["status"] == DONE

    run(scenario())
