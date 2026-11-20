"""Run with: python3 -m unittest discover -s scripts/tests -v"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
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
                                         "status": state[1], "conclusion": state[2],
                                         **dict(zip(("createdAt", "updatedAt"), state[3:]))})
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

    def test_a_run_cancelled_by_a_newer_push_names_the_run_to_wait_for(self):
        # #122 L2155: a merge pushed to the branch cancelled its own run; "cancelled" alone sent the session to the log.
        world = FakeWorld(runs={SHA["route"]: [(11, "completed", "cancelled", "2026-11-20T09:30:46Z",
                                                 "2026-11-20T09:31:58Z")],
                                SHA["link"]: [(12, "in_progress", "", "2026-11-20T09:31:55Z", "2026-11-20T09:32:10Z")]})
        code, out, _ = world.run(["wait", "claude/relay-e2e", SHA["route"]])
        self.assertEqual(code, 1)
        self.assertIn("cancelled by a newer push to claude/relay-e2e: run 12 of bbbbbbb", out)

    def test_a_run_cancelled_by_its_timeout_names_the_classes_that_never_ended(self):
        # #122 L2298-L2354: SquaddE2ETests hung on a quadratic hex() until timeout-minutes; six calls to find it.
        log = "\n".join(f"job\tstep\t2026-11-20T09:34:03Z {line}" for line in [
            "Tests of the touched files:",
            "-only-testing:HermesMobileTests/SquaddSettingsTests",
            "-only-testing:HermesMobileTests/SquaddE2ETests",
            "-only-testing:HermesMobileTests/SquaddRouteTests",
            "Test Suite 'SquaddSettingsTests' passed at 2026-11-20 11:35:03.633.",
            "Test Suite 'SquaddRouteTests' failed at 2026-11-20 11:35:04.100.",
            "##[error]The operation was canceled."])
        # The real runs of #122: 44711340082 hit the timeout at 09:32:55, the session pushed again at 09:33:50.
        world = FakeWorld(runs={SHA["route"]: [(11, "completed", "cancelled", "2026-11-20T09:30:46Z",
                                                 "2026-11-20T09:32:55Z")],
                                SHA["link"]: [(12, "in_progress", "", "2026-11-20T09:33:50Z", "2026-11-20T09:34:01Z")]},
                          logs={11: log})
        code, out, _ = world.run(["wait", "claude/relay-e2e", SHA["route"]])
        self.assertEqual(code, 1)
        self.assertIn("the job hit its timeout-minutes", out)
        self.assertNotIn("cancelled by a newer push", out)
        self.assertIn("never ended (a hung class holds back the output of its simulator): SquaddE2ETests\n", out)

    def test_a_test_case_started_and_never_ended_is_named(self):
        # With the hung simulator's lines in the log, the case itself is named, not every class of that simulator.
        log = "\n".join(f"job\tstep\t2026-11-20T09:34:03Z {line}" for line in [
            "-only-testing:HermesMobileTests/SquaddE2ETests",
            "-only-testing:HermesMobileTests/SquaddRouteTests",
            "Test Case '-[HermesMobileTests.SquaddE2ETests testDerivationsAndPointsMatchTheVectors]' started.",
            "Test Case '-[HermesMobileTests.SquaddE2ETests testDerivationsAndPointsMatchTheVectors]' passed (0.010 seconds).",
            "Test Case '-[HermesMobileTests.SquaddRouteTests testRealRouteToACompanion]' started.",
            "Test Case '-[HermesMobileTests.SquaddRouteTests testRealRouteToACompanion]' skipped (0.000 seconds).",
            "Test Case '-[HermesMobileTests.SquaddE2ETests testHandshakeMatchesTheVectors]' started.",
            "##[error]The operation was canceled."])
        world = FakeWorld(runs={SHA["route"]: [(11, "completed", "cancelled", "2026-11-20T09:30:46Z",
                                                 "2026-11-20T09:32:55Z")]}, logs={11: log})
        code, out, _ = world.run(["wait", "claude/relay-e2e", SHA["route"]])
        self.assertEqual(code, 1)
        self.assertIn("started and never ended: SquaddE2ETests.testHandshakeMatchesTheVectors\n", out)
        self.assertNotIn("SquaddRouteTests", out)  # a skipped case ends too (#122 run 44711340082)


SERVEO_OUTPUT = ("Pseudo-terminal will not be allocated because stdin is not a terminal.\n"
                 "To request a particular subdomain, see https://console.serveo.net/ssh-keys\n"
                 "\x1b[32mForwarding HTTP traffic from https://23103f55678de5d3-51-83-1-9.serveousercontent.com\n\x1b[0m\n")


class LiveTests(unittest.TestCase):
    def test_the_tunnel_address_is_never_a_serveo_console_link(self):
        # #112: a wider pattern wrote https://console.serveo.net/… into the gist (D-227).
        self.assertEqual(tool.tunnel_address(SERVEO_OUTPUT), "https://23103f55678de5d3-51-83-1-9.serveousercontent.com")

    def test_the_tunnel_has_a_key_of_its_own_on_port_443_with_a_connect_timeout(self):
        # #109: no key, another session's address (D-226); #93: port 22 hung silently 4 min (D-207).
        command = tool.tunnel_command("/w/tunnel-key", "/w/known_hosts", 18000)
        self.assertEqual(command[command.index("-i") + 1], "/w/tunnel-key")
        self.assertIn("IdentitiesOnly=yes", command)
        self.assertEqual(command[command.index("-p") + 1], "443")
        self.assertIn("ConnectTimeout=15", command)
        self.assertEqual(command[-2:], ["80:127.0.0.1:18000", "serveo.net"])

    def test_a_live_run_goes_to_a_free_branch_its_workflow_triggers_on(self):
        # #115: foto/16-live-3 pushed with the trigger still on -2: no run (D-232).
        branch = tool.live_branch("16", {"foto/16-live", "foto/16-live-2"})
        self.assertEqual(branch, "foto/16-live-3")
        workflow = tool.live_workflow("16", "SquaddChatLivePhotoTests", branch, "LIVE_16_A_LOOKUP", "LIVE_16_A_TOKEN")
        self.assertIn("branches: ['foto/16-live-3']", workflow)
        self.assertIn("-only-testing:HermesMobileTests/SquaddChatLivePhotoTests", workflow)
        self.assertIn("${{ secrets.LIVE_16_A_TOKEN }}", workflow)
        # #97: with parallel clones a failure has no line the grep keeps (D-216).
        self.assertIn("-parallel-testing-enabled NO", workflow)

    def test_openmausbot_gets_a_worktree_with_its_own_packages_and_the_fake_engine_server(self):
        # #78: a linked node_modules missed packages, ERR_MODULE_NOT_FOUND (D-195); #94: node server/index.ts with
        # FAKE_CLAUDE_MODE ran the real engine, «Not logged in» (D-214).
        calls, spawned = [], []
        run = tool.Live(REPO, "16")

        def sh(*cmd, cwd=None, **_):
            calls.append((cmd, cwd))
            return "/work/me/squadd-multi-agents-ios/.git\n" if "--git-common-dir" in cmd else ""

        def spawn(cmd, cwd, env, log):
            spawned.append((cmd, cwd))
            Path(log).write_text('{\n  "ok": true,\n  "url": "http://127.0.0.1:19001"\n}\n')
            return type("P", (), {"poll": lambda self: None})()
        with patch.object(tool, "sh", sh), patch.object(tool.Path, "exists", lambda self: True), \
                patch.object(run, "spawn", spawn):
            omb = run.openmausbot()
            info = run.server(omb)
        self.assertEqual(omb, run.work / "openmausbot")
        self.assertIn(((tuple("git -C /work/me/openmausbot worktree add -q --detach".split()) + (str(omb), "origin/dev")),
                       None), calls)
        self.assertIn((("pnpm", "install", "--frozen-lockfile", "--ignore-scripts"), omb), calls)
        self.assertEqual(spawned, [(["node", "--experimental-strip-types", "scripts/control-omb.ts", "launch"], omb)])
        self.assertEqual(info["url"], "http://127.0.0.1:19001")

    def test_closing_removes_exactly_what_the_run_made(self):
        run = tool.Live(REPO, "16")
        run.branch, run.secrets, run.gist = "foto/16-live-2", ["LIVE_16_A_LOOKUP"], "abc123"
        run.omb = (Path("/work/me/openmausbot"), run.work / "openmausbot")
        calls = []
        with patch.object(tool.subprocess, "run", lambda cmd, **_: calls.append(cmd)):
            run.close()
        self.assertEqual(calls, [
            ["git", "-C", str(tool.ROOT), "push", "-q", "origin", "--delete", "refs/heads/foto/16-live-2"],
            ["gh", "secret", "delete", "LIVE_16_A_LOOKUP", "-R", REPO],
            ["gh", "gist", "delete", "abc123", "--yes"],
            ["git", "-C", "/work/me/openmausbot", "worktree", "remove", "--force", str(run.work / "openmausbot")]])


class PrIosWorkflowTests(unittest.TestCase):
    WORKFLOW = (Path(__file__).resolve().parents[2] / ".github" / "workflows" / "pr-ios.yml").read_text()

    def test_pr_ios_leaves_foto_branches_to_their_own_workflow(self):
        # #47: a foto/ push built twice on the Mac runners, PR iOS and the branch's own workflow (D-184).
        self.assertIn("branches-ignore: [dev, main, master, 'foto/**']", self.WORKFLOW)

    def test_the_log_keeps_what_a_test_prints(self):
        # #86: a timing printed by a test never reached the PR iOS log, one CI round lost (D-203).
        keep = re.search(r"KEEP='(.*)'", self.WORKFLOW).group(1)
        lines = ["Test Case '-[HermesMobileTests.A b]' started.", "photo 1: 312 ms",
                 "Test Case '-[HermesMobileTests.A b]' passed (0.3 seconds).", "xcodebuild noise", "** TEST SUCCEEDED **"]
        kept = subprocess.run(["awk", keep], input="\n".join(lines) + "\n", capture_output=True, text=True).stdout
        self.assertEqual(kept.splitlines(), lines[:3] + lines[4:])


if __name__ == "__main__":
    unittest.main()
