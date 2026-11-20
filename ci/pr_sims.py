#!/usr/bin/env python3
"""Share a simulator between the Mac's two PR iOS runners, so two pushes at once neither queue nor collide.

Each runner owns one booted simulator (ONE) and borrows the shared one (TWO) only while the other runner has
no job going, so a lone run still splits its tests over two simulators. Used as the shell of the test step:

    shell: python3 ci/pr_sims.py bash --noprofile --norc -eo pipefail {0}

It runs the step with TWO emptied when it cannot borrow. A lock on the shared simulator, held until the step
ends, keeps two borrowers apart. The step runs in its own process group, recorded in _work/pr-tests.pgid, so a
cancelled job's xcodebuild dies with it or, if this wrapper is killed first, at the next job (ci/pr_state.py).
"""

import fcntl
import os
import signal
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
    pgid_file = Path(os.environ["GITHUB_WORKSPACE"]).parents[1] / "pr-tests.pgid"
    step = subprocess.Popen(cmd, env={**os.environ, "TWO": shared if borrowed else ""}, start_new_session=True)
    pgid_file.write_text(str(step.pid))
    signal.signal(signal.SIGTERM, signal.default_int_handler)  # the runner cancels with SIGINT, then SIGTERM
    try:
        return step.wait()
    finally:
        try:
            os.killpg(step.pid, signal.SIGKILL)  # whatever the step left running: xcodebuild, grep, tee
        except ProcessLookupError:
            pass
        pgid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
