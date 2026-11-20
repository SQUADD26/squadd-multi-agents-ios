import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import pr_sims  # noqa: E402
from test_pr_group import exits  # noqa: E402


class PrSimsTests(unittest.TestCase):
    def run_step(self, other_busy, shared, script='echo "$ONE $TWO" > {out}'):
        out = Path(tempfile.mkdtemp()) / "env.txt"
        workspace = out.parent / "repo" / "repo"
        with mock.patch.object(pr_sims, "other_runner_busy", return_value=other_busy), \
                mock.patch.dict(os.environ, {"ONE": "own", "TWO": shared, "GITHUB_WORKSPACE": str(workspace)}):
            self.assertEqual(pr_sims.main(["sh", "-c", script.format(out=out)]), 0)
        return out.read_text().split()

    def test_nothing_the_step_started_outlives_it(self):
        pid = int(self.run_step(True, str(uuid.uuid4()), "sleep 30 & echo $! > {out}")[0])
        self.assertTrue(exits(pid))

    def test_a_lone_run_borrows_the_shared_simulator(self):
        shared = str(uuid.uuid4())
        self.assertEqual(self.run_step(False, shared), ["own", shared])

    def test_with_the_other_runner_busy_a_run_keeps_its_own(self):
        self.assertEqual(self.run_step(True, str(uuid.uuid4())), ["own"])

    def test_a_shared_simulator_already_borrowed_is_not_borrowed_twice(self):
        shared = str(uuid.uuid4())
        self.assertTrue(pr_sims.borrow(shared))
        self.assertEqual(self.run_step(False, shared), ["own"])


if __name__ == "__main__":
    unittest.main()
