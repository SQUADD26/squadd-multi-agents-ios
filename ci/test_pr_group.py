import os
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
import pr_group  # noqa: E402


def exits(pid, timeout=5):
    """True once `pid` has exited (kqueue: no polling), False if it is still running after `timeout`."""
    try:
        return bool(select.kqueue().control(
            [select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 1, timeout))
    except ProcessLookupError:
        return True


def work_dir():
    work = Path(tempfile.mkdtemp())
    (work / "repo" / "repo").mkdir(parents=True)
    return work


class PrGroupTests(unittest.TestCase):
    def test_a_cancelled_step_takes_its_xcodebuild_with_it(self):
        work = work_dir()
        fifo = work / "pid"
        os.mkfifo(fifo)
        wrapper = subprocess.Popen(
            [sys.executable, pr_group.__file__, "build", "sh", "-c", f"sleep 30 & echo $! > {fifo}; wait"],
            env={**os.environ, "GITHUB_WORKSPACE": str(work / "repo" / "repo")})
        grandchild = int(fifo.read_text())
        wrapper.send_signal(signal.SIGTERM)  # what the runner sends when it cancels the job
        wrapper.wait()
        self.assertTrue(exits(grandchild))
        self.assertFalse((work / "pr-build.pgid").exists())

    def test_the_next_job_stops_only_what_a_cancelled_job_left(self):
        work = work_dir()
        left = subprocess.Popen(["sleep", "30"], start_new_session=True)
        other = subprocess.Popen(["sleep", "30"], start_new_session=True)
        (work / "pr-build.pgid").write_text(f"{left.pid} {pr_group.started(left.pid)}")
        (work / "pr-tests.pgid").write_text(f"{other.pid} Thu Jan  1 00:00:00 1970")  # its pid, now someone else's
        pr_group.stop_leftovers(work)
        self.assertTrue(exits(left.pid))
        self.assertFalse(exits(other.pid, timeout=0.2))
        self.assertEqual(list(work.glob("pr-*.pgid")), [])
        other.kill()


if __name__ == "__main__":
    unittest.main()
