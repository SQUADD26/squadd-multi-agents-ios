"""Run with: python3 -m unittest discover -s scripts/tests -v"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "pr-ios-run"
loader = importlib.machinery.SourceFileLoader("pr_ios_run", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
tool = importlib.util.module_from_spec(spec)
loader.exec_module(tool)

REPO = "SQUADD26/squadd-multi-agents-ios"
SHA = {"route": "a" * 40, "link": "b" * 40}


class FakeWorld:
    """git and gh as PR iOS sees them; `runs` maps a sha to what `gh run list` returns over time."""

    def __init__(self, runs=None, push_error=None, gh_error=None, logs=None):
        self.runs, self.push_error, self.gh_error = runs or {}, push_error, gh_error
        self.logs = logs or {}
        self.calls, self.clock, self.polls = [], 0.0, {}

    def sh(self, *cmd):
        self.calls.append(cmd)
        if cmd[0] == "git":
            args = cmd[3:]
            if args[:2] == ("remote", "get-url"):
                return f"https://github.com/{REPO}.git\n"
            if args[0] == "rev-parse":
                return SHA[args[-1].split("^")[0]] + "\n"
            if args[0] == "push":
                if self.push_error:
                    raise tool.Stop(f"git -C x failed: {self.push_error}")
                return ""
        if cmd[0] == "gh":
            if self.gh_error:
                raise tool.Stop(f"gh run list failed: {self.gh_error}")
            if cmd[1:3] == ("run", "list"):
                sha_runs = []
                for sha, timeline in self.runs.items():
                    seen = self.polls.get(sha, 0)
                    self.polls[sha] = seen + 1
                    state = timeline[min(seen, len(timeline) - 1)]
                    if state:
                        sha_runs.append({"databaseId": state[0], "headSha": sha,
                                         "status": state[1], "conclusion": state[2]})
                return json.dumps(sha_runs)
            if cmd[1:3] == ("run", "view"):
                return self.logs.get(int(cmd[3]), "")
        raise AssertionError(cmd)

    def sleep(self, seconds):
        self.clock += seconds

    def run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(tool, "sh", self.sh), \
                patch.object(tool.time, "monotonic", lambda: self.clock), \
                patch.object(tool.time, "sleep", self.sleep), \
                patch.object(tool.subprocess, "run", lambda cmd, **_: self.calls.append(tuple(cmd))), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tool.main(argv)
        return code, out.getvalue(), err.getvalue()

    def gh_calls(self):
        return [c for c in self.calls if c[0] == "gh"]


FAIL_LOG = "job\tstep\tHermesMobileTests/SquaddNotificationsTests.swift:59: error: -[X testRead] : failed\n"
DONE_RED = (11, "completed", "failure")


class RedRowTests(unittest.TestCase):
    def test_a_rejected_push_stops_at_once_instead_of_waiting_for_a_run(self):
        # #98: `git push origin HEAD:rosso/32` failed and the loop waited 36 minutes for its run.
        world = FakeWorld(push_error="The destination you provided is not a full refname")
        code, _, err = world.run(["red", "32", "route=route"])
        self.assertEqual(code, 2)
        self.assertIn("not a full refname", err)
        self.assertEqual(world.gh_calls(), [])
        self.assertEqual(world.clock, 0)

    def test_every_mutation_is_pushed_to_its_own_branch_before_waiting(self):
        world = FakeWorld(runs={SHA["route"]: [None, (11, "in_progress", ""), DONE_RED],
                                SHA["link"]: [(12, "queued", ""), (12, "completed", "failure")]},
                          logs={11: FAIL_LOG, 12: FAIL_LOG})
        code, out, _ = world.run(["red", "32", "route=route", "link=link"])
        self.assertEqual(code, 0, out)
        pushes = [c[-1] for c in world.calls if c[:5] == ("git", "-C", str(tool.ROOT), "push", "-q") and "--force" in c]
        self.assertEqual(pushes, [f"{SHA['route']}:refs/heads/rosso/32-route", f"{SHA['link']}:refs/heads/rosso/32-link"])
        first_gh = next(i for i, c in enumerate(world.calls) if c[0] == "gh")
        last_push = max(i for i, c in enumerate(world.calls) if "--force" in c)
        self.assertLess(last_push, first_gh)
        self.assertIn("SquaddNotificationsTests.swift:59", out)
        deleted = [c[-1] for c in world.calls if "--delete" in c]
        self.assertEqual(deleted, ["refs/heads/rosso/32-route", "refs/heads/rosso/32-link"])

    def test_a_mutation_no_test_catches_fails_the_check(self):
        world = FakeWorld(runs={SHA["route"]: [(11, "completed", "success")]})
        code, out, _ = world.run(["red", "32", "route=route"])
        self.assertEqual(code, 1)
        self.assertIn("no test failed", out)

    def test_branches_are_deleted_even_when_waiting_stops(self):
        world = FakeWorld(gh_error="failed to determine base repo")
        code, _, _ = world.run(["red", "32", "route=route"])
        self.assertEqual(code, 2)
        self.assertEqual([c[-1] for c in world.calls if "--delete" in c], ["refs/heads/rosso/32-route"])


class WaitTests(unittest.TestCase):
    def test_a_gh_error_stops_at_the_first_look(self):
        # #98: watchers run from the scratchpad got "not a git repository" for 15 minutes.
        world = FakeWorld(gh_error="failed to determine base repo: not a git repository")
        code, _, err = world.run(["wait", "issue/32-notifiche", SHA["route"]])
        self.assertEqual(code, 2)
        self.assertIn("not a git repository", err)
        self.assertEqual(len(world.gh_calls()), 1)

    def test_every_gh_call_names_the_repository(self):
        world = FakeWorld(runs={SHA["route"]: [(11, "completed", "success")]})
        self.assertEqual(world.run(["wait", "issue/32-notifiche", SHA["route"]])[0], 0)
        for call in world.gh_calls():
            self.assertEqual(call[call.index("-R") + 1], REPO)

    def test_a_run_that_never_starts_stops_after_a_few_minutes(self):
        world = FakeWorld(runs={})
        code, _, err = world.run(["wait", "issue/32-notifiche", SHA["route"]])
        self.assertEqual(code, 2)
        self.assertIn("check the push reached GitHub", err)
        self.assertLessEqual(world.clock, (tool.NO_RUN_MINUTES * 60) + tool.POLL_SECONDS)

    def test_a_red_run_prints_its_assertion(self):
        world = FakeWorld(runs={SHA["route"]: [(11, "in_progress", ""), DONE_RED]}, logs={11: FAIL_LOG})
        code, out, _ = world.run(["wait", "issue/32-notifiche", SHA["route"]])
        self.assertEqual(code, 1)
        self.assertIn("run 11 failure", out)
        self.assertIn("HermesMobileTests/SquaddNotificationsTests.swift:59: error", out)


if __name__ == "__main__":
    unittest.main()
