#!/usr/bin/env python3
"""Share a simulator between the Mac's two PR iOS runners, so two pushes at once neither queue nor collide.

Each runner owns one booted simulator (ONE) and borrows the shared one (TWO) only while the other runner has
no job going, so a lone run still splits its tests over two simulators. Used as the shell of the test step:

    shell: python3 ci/pr_sims.py bash --noprofile --norc -eo pipefail {0}

It runs the step with TWO emptied when it cannot borrow. A lock on the shared simulator, held until the step
ends, keeps two borrowers apart.
"""

import fcntl
import os
import subprocess
import sys
from pathlib import Path


def other_runner_busy():
    """A runner starts a Runner.Worker for each job and ends it with the job; the runners are
    ~/actions-runner-squadd-multi-ios and the same path with -2."""
    root = str(Path(os.environ["GITHUB_WORKSPACE"]).parents[2])
    other = root[:-2] if root.endswith("-2") else root + "-2"
    return subprocess.run(["pgrep", "-f", f"^{other}/bin/Runner.Worker "], capture_output=True).returncode == 0


def borrow(udid):
    fd = os.open(f"/tmp/squadd-multi-ios-sim-{udid}.lock", os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def main(cmd):
    shared = os.environ["TWO"]
    borrowed = not other_runner_busy() and borrow(shared)
    print(f"Simulators: {os.environ['ONE']}" + (f" and {shared} (shared)" if borrowed else " (the other runner has a job)"))
    return subprocess.run(cmd, env={**os.environ, "TWO": shared if borrowed else ""}).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
