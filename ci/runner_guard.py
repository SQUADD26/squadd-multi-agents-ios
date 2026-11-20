"""Cancel a hosted macOS run a branch's own workflow starts on push, and say what to use instead.

Run by .github/workflows/runner-guard.yml on every push: python3 ci/runner_guard.py <repo> <sha>.
A hosted macOS runner builds from scratch: #67's proof on `xcode-27` took 40 minutes, PR iOS on the Mac takes one.
Workflows that run on schedule or by hand (pr-ci.yml, the release) are not touched. Exit 1 when it cancelled a run.
"""

import base64
import json
import re
import subprocess
import sys
import time

HOSTED_MAC = re.compile(r"^\s*runs-on:.*\b(?:macos|xcode)-[\w.-]+", re.M)
ON_PUSH = re.compile(r"^\s*(?:push|pull_request)\s*:|^on:\s*\[?.*\b(?:push|pull_request)\b", re.M)


def hosted_on_push(text):
    """True for a workflow a push starts on a hosted macOS runner."""
    text = "\n".join(line.split(" #")[0] for line in text.splitlines() if not line.lstrip().startswith("#"))
    return bool(HOSTED_MAC.search(text) and ON_PUSH.search(text))


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True, timeout=60).stdout


def main(repo, sha):
    files = json.loads(gh("api", f"repos/{repo}/compare/dev...{sha}", "--jq", "[.files[] | select(.status != \"removed\") | .filename]"))
    hosted = [path for path in files if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", path) and hosted_on_push(
        base64.b64decode(gh("api", f"repos/{repo}/contents/{path}?ref={sha}", "--jq", ".content")).decode())]
    if not hosted:
        return 0
    for _ in range(10):  # a push creates all its runs within seconds
        runs = json.loads(gh("api", f"repos/{repo}/actions/runs?head_sha={sha}", "--jq", "[.workflow_runs[] | {id, path, status}]"))
        mine = [run for run in runs if run["path"] in hosted and run["status"] != "completed"]
        if mine:
            break
        time.sleep(3)
    for run in mine:
        gh("run", "cancel", str(run["id"]), "-R", repo)
    print(f"::error::{', '.join(hosted)} runs on a hosted macOS runner, which builds from scratch (#67: 40 minutes): "
          "cancelled. Tests and red rows: PR iOS and scripts/pr-ios-run red; the real app against a companion: "
          "scripts/pr-ios-run live.")
    return 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
