import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import pr_sims  # noqa: E402


class PrSimsTests(unittest.TestCase):
    def run_step(self, other_busy):
        tmp = Path(tempfile.mkdtemp())
        out = tmp / "env.txt"
        env = {"RUNNER_NAME": "mac-2", "ONE": "sim-a", "TWO": "sim-b"}
        with mock.patch.object(pr_sims, "LOCKS", tmp), mock.patch.dict(os.environ, env):
            if other_busy:
                pr_sims.busy_mark(1).touch()
            pr_sims.main(["--busy"])
            code = pr_sims.main(["sh", "-c", f'echo "$ONE $TWO" > {out}'])
            self.assertFalse(pr_sims.busy_mark(2).exists())
        self.assertEqual(code, 0)
        return out.read_text().split()

    def test_a_lone_run_borrows_the_other_simulator(self):
        self.assertEqual(self.run_step(other_busy=False), ["sim-b", "sim-a"])

    def test_with_the_other_runner_busy_a_run_keeps_its_own(self):
        self.assertEqual(self.run_step(other_busy=True), ["sim-b"])


if __name__ == "__main__":
    unittest.main()
