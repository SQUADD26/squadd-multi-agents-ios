import unittest

from runner_guard import hosted_on_push


class HostedOnPushTests(unittest.TestCase):
    def test_a_push_workflow_on_a_hosted_mac_is_caught_and_the_nightly_one_is_not(self):
        # #67: foto-29-connettori.yml on xcode-27, 40 minutes for a proof PR iOS gives in one (D-188).
        self.assertTrue(hosted_on_push("on:\n  push:\n    branches: ['foto/29-*']\njobs:\n  a:\n    runs-on: xcode-27\n"))
        self.assertTrue(hosted_on_push("on: [push]\njobs:\n  a:\n    runs-on: macos-15\n"))
        self.assertFalse(hosted_on_push("on:\n  schedule:\n    - cron: '0 2 * * *'\njobs:\n  a:\n    runs-on: xcode-27\n"))
        self.assertFalse(hosted_on_push("on:\n  push:\njobs:\n  a:\n    runs-on: [squadd-multi-ios-senza-pr]  # not macos-15\n"))


if __name__ == "__main__":
    unittest.main()
