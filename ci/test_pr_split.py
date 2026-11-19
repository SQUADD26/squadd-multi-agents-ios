import tempfile
import unittest
from pathlib import Path

from pr_split import record, split

T = "-only-testing:HermesMobileTests/"


class SplitTests(unittest.TestCase):
    def test_the_longest_class_runs_alone_and_remembered_times_win(self):
        log = Path(tempfile.mkdtemp()) / "two.log"
        log.write_text(
            "Test Case '-[HermesMobileTests.AgentPhotoTests testShots]' passed (15.473 seconds).\n"
            "Test Case '-[HermesMobileTests.EditorTests testA]' passed (0.002 seconds).\n"
            "Test Case '-[HermesMobileTests.EditorTests testB]' failed (0.010 seconds).\n"
        )
        known = record([log], {"BrandPhotoTests": 5.1})
        self.assertEqual(known["AgentPhotoTests"], 15.5)
        one, two = split([T + "BrandPhotoTests", T + "ScreenPhotoTests", T + "AgentPhotoTests", T + "EditorTests"], known)
        self.assertEqual(one, [T + "AgentPhotoTests"])
        self.assertEqual(sorted(two), [T + "BrandPhotoTests", T + "EditorTests", T + "ScreenPhotoTests"])


if __name__ == "__main__":
    unittest.main()
