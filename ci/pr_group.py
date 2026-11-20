#!/usr/bin/env python3
"""Run a PR iOS command in its own process group, recorded in _work/pr-<name>.pgid, so a cancelled job's
xcodebuild never outlives it.

The job sets RUNNER_TRACKING_ID empty to keep the build daemons warm, so the runner does not kill what a
cancelled job leaves running: an xcodebuild that goes on writing into DerivedData after ci/pr_state.py has
parked it, and holding a simulator. On SIGINT or SIGTERM (the runner's cancel) the group is killed here; if this
wrapper is killed first, ci/pr_state.py kills the recorded group at the start of the next job.

    python3 ci/pr_group.py build nice -n 10 xcodebuild build-for-testing ...

The build's group is left alone when it ends well (the daemons it started stay warm); ci/pr_sims.py runs the
test step with kill_at_end, so nothing a test started survives it.
"""

import os
import signal
import subprocess
import sys
from pathlib import Path


def started(pid):
    """The start time of `pid`, '' when there is none: with the pid it names one process, even if pids wrap."""
    return subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()


def run(name, cmd, env=None, kill_at_end=False):
    record = Path(os.environ["GITHUB_WORKSPACE"]).parents[1] / f"pr-{name}.pgid"
    signal.signal(signal.SIGTERM, signal.default_int_handler)  # the runner cancels with SIGINT, then SIGTERM
    step, ended = None, False
    try:
        step = subprocess.Popen(cmd, env=env, start_new_session=True)
        record.with_suffix(".tmp").write_text(f"{step.pid} {started(step.pid)}")
        record.with_suffix(".tmp").rename(record)  # atomic: the next job never reads half a record
        code = step.wait()
        ended = True
        return code
    finally:
        if step and (kill_at_end or not ended):
            try:
                os.killpg(step.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        record.unlink(missing_ok=True)


def stop_leftovers(work):
    """Kills the groups an earlier cancelled job left in `work`, unless their pid now names another process."""
    for record in work.glob("pr-*.pgid"):
        text = record.read_text()
        record.unlink()
        pgid, _, when = text.partition(" ")
        if not pgid.isdigit() or started(pgid) not in ("", when):
            continue
        try:
            os.killpg(int(pgid), signal.SIGKILL)
            print(f"Stopped what an earlier cancelled job left running ({record.name}, process group {pgid})")
        except ProcessLookupError:
            pass


if __name__ == "__main__":
    sys.exit(run(sys.argv[1], sys.argv[2:]))
