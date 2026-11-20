import os
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import pr_state


def commit(repo, files):
    for name, text in files.items():
        (repo / name).write_text(text)
    subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
    subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"], check=True)
    return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()


class PRStateTests(unittest.TestCase):
    def test_deleting_a_swift_file_costs_more_than_any_number_of_changes(self):
        self.assertGreater(pr_state.cost("D\tA.swift\n"), pr_state.cost("M\tB.swift\n" * 500 + "A\tC.swift\nM\tdocs.md"))

    def test_one_app_file_costs_more_than_many_test_files(self):
        self.assertGreater(pr_state.cost("M\tApp/A.swift\n"), pr_state.cost("M\tAppTests/B.swift\n" * 50))

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.workspace = self.work / "repo" / "repo"
        self.workspace.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", self.workspace], check=True)
        self.base = commit(self.workspace, {"App.swift": "base"})
        os.environ["GITHUB_WORKSPACE"] = str(self.workspace)
        (self.work / "DerivedData").mkdir()
        (self.work / "DerivedData" / "built").write_text("start")

    def built(self, text=None):
        if text:
            (self.work / "DerivedData" / "built").write_text(text)
        return (self.work / "DerivedData" / "built").read_text()

    def test_each_branch_gets_its_own_state_back(self):
        pr_state.main("foto/1-a", self.base)
        self.built("branch 1")
        pr_state.main("foto/2-b", self.base)
        self.assertEqual(self.built(), "branch 1")  # a new branch clones the closest state
        self.built("branch 2")
        pr_state.main("foto/1-a", self.base)

        self.assertEqual(self.built(), "branch 1")
        self.assertTrue((self.workspace / ".git").is_dir())

        pr_state.KEEP = 1  # the oldest parked state leaves at once; its files go in the background
        pr_state.main("foto/3-c", self.base)
        self.assertEqual(sorted(p.name for p in (self.work / "pr-states").iterdir() if p.is_dir()), ["foto-1-a"])

    def test_a_branch_left_both_parked_and_in_place_still_gets_its_state(self):
        pr_state.main("foto/1-a", self.base)
        self.built("branch 1")
        (self.work / "pr-states" / "foto-1-a" / "dd").mkdir(parents=True)  # a run cancelled mid-swap
        subprocess.run(["cp", "-R", self.workspace, self.work / "pr-states" / "foto-1-a" / "src"], check=True)
        pr_state.main("foto/2-b", self.base)
        pr_state.main("foto/1-a", self.base)
        self.assertEqual(self.built(), "branch 1")

    def test_a_clone_left_by_a_run_cancelled_mid_copy_does_not_stop_the_next_new_branch(self):
        pr_state.main("foto/1-a", self.base)
        self.built("branch 1")
        pr_state.main("foto/2-b", self.base)
        (self.work / "pr-states" / "foto-1-a" / "dd-clone").mkdir()
        pr_state.main("foto/3-c", self.base)
        self.assertEqual(self.built(), "branch 1")

    def test_a_derived_data_written_after_parking_does_not_stop_the_run(self):
        pr_state.main("foto/1-a", self.base)
        self.built("branch 1")
        clone = pr_state.clone

        def clone_while_a_stray_build_writes(src, dst):  # an xcodebuild that outlived a cancelled job
            clone(src, dst)
            (self.work / "DerivedData" / "Logs").mkdir(parents=True, exist_ok=True)

        with mock.patch.object(pr_state, "clone", clone_while_a_stray_build_writes):
            pr_state.main("foto/2-b", self.base)
        self.assertEqual(self.built(), "branch 1")  # the closest state, not the stray

if __name__ == "__main__":
    unittest.main()
