import os
import subprocess
import tempfile
import unittest
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

    def test_each_branch_gets_its_own_state_back(self):
        work = Path(tempfile.mkdtemp())
        workspace = work / "repo" / "repo"
        workspace.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", workspace], check=True)
        base = commit(workspace, {"App.swift": "base"})
        os.environ["GITHUB_WORKSPACE"] = str(workspace)
        (work / "DerivedData").mkdir()
        (work / "DerivedData" / "built").write_text("start")

        pr_state.main("foto/1-a", base)
        (work / "DerivedData" / "built").write_text("branch 1")
        pr_state.main("foto/2-b", base)
        self.assertEqual((work / "DerivedData" / "built").read_text(), "branch 1")  # a new branch clones the closest state
        (work / "DerivedData" / "built").write_text("branch 2")
        pr_state.main("foto/1-a", base)

        self.assertEqual((work / "DerivedData" / "built").read_text(), "branch 1")
        self.assertTrue((workspace / ".git").is_dir())

        # A cancelled run left this branch both parked and in place: the next run still gets its state.
        (work / "pr-states" / "foto-1-a" / "dd").mkdir(parents=True)
        subprocess.run(["cp", "-R", workspace, work / "pr-states" / "foto-1-a" / "src"], check=True)
        pr_state.main("foto/2-b", base)
        self.assertEqual((work / "DerivedData" / "built").read_text(), "branch 2")

        pr_state.KEEP = 1  # the oldest parked state leaves at once; its files go in the background
        pr_state.main("foto/3-c", base)
        self.assertEqual(sorted(p.name for p in (work / "pr-states").iterdir() if p.is_dir()), ["foto-1-a"])


if __name__ == "__main__":
    unittest.main()
