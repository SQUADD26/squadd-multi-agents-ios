#!/usr/bin/env python3
"""Share the two booted simulators between the Mac's two PR iOS runners, so two pushes at once don't queue.

Each runner owns one simulator (the runner whose name ends in -2 owns ONE's twin, TWO) and borrows the
other one when the other runner has no job going, so a lone run still splits its tests over both. Used as
the shell of the test step:

    shell: python3 ci/pr_sims.py bash --noprofile --norc -eo pipefail {0}

It holds a lock on each simulator it takes (released when the step ends), runs the step with ONE set to
its simulator and TWO to the borrowed one or empty, and clears this runner's busy mark at the end.
`python3 ci/pr_sims.py --busy` sets the mark at the start of the job.
"""

import fcntl
import os
import subprocess
import sys
import time
from pathlib import Path

LOCKS = Path("/tmp")
BUSY_FOR = 150  # seconds a busy mark counts: a job's limit is 2 minutes, so a cancelled job's mark expires


def slot():
    return 2 if os.environ.get("RUNNER_NAME", "").endswith("-2") else 1


def busy_mark(n):
    return LOCKS / f"squadd-multi-ios-busy-{n}"


def lock(udid, wait):
    fd = os.open(LOCKS / f"squadd-multi-ios-sim-{udid}.lock", os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        return fd
    except BlockingIOError:
        os.close(fd)
        return None


def other_busy(now=None):
    mark = busy_mark(3 - slot())
    return mark.exists() and (now or time.time()) - mark.stat().st_mtime < BUSY_FOR


def main(cmd):
    if cmd == ["--busy"]:
        busy_mark(slot()).touch()
        return 0
    one, two = os.environ["ONE"], os.environ["TWO"]
    mine, other = (two, one) if slot() == 2 else (one, two)
    lock(mine, wait=True)  # free unless the other runner borrowed it: then until its tests end
    borrowed = None if other_busy() else lock(other, wait=False)
    print(f"Simulators: {mine}" + (f" and {other} (borrowed)" if borrowed else " (the other runner has a job)"))
    try:
        return subprocess.run(cmd, env={**os.environ, "ONE": mine, "TWO": other if borrowed else ""}).returncode
    finally:
        busy_mark(slot()).unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
