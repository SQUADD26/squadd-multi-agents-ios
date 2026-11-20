#!/usr/bin/env python3
"""Split the PR's test classes across the two simulators so both finish together.

    python3 ci/pr_split.py split <times.json> < tests.txt     writes one.txt and two.txt in the current directory
    python3 ci/pr_split.py record <times.json> <log>...       remembers each class's seconds from xcodebuild logs

Longest class first, each to the simulator with less work so far. A class never timed counts as
PHOTO seconds when its name says Photo (they take seconds), OTHER otherwise.
"""

import json
import re
import sys
from pathlib import Path

PHOTO, OTHER = 6.0, 0.5
CASE = re.compile(r"Test Case '-\[HermesMobileTests\.(\w+) \w+\]' (?:passed|failed) \((\d+(?:\.\d+)?) seconds\)")


def load(times):
    return json.loads(times.read_text()) if times.exists() else {}


def split(lines, known):
    halves, work = ([], []), [0.0, 0.0]
    cost = lambda line: known.get(line.rsplit("/", 1)[-1], PHOTO if "Photo" in line else OTHER)
    for line in sorted(lines, key=cost, reverse=True):
        i = work.index(min(work))
        halves[i].append(line)
        work[i] += cost(line)
    return halves


def record(logs, known):
    seen = {}
    for log in logs:
        for name, seconds in CASE.findall(Path(log).read_text(errors="replace")):
            seen[name] = seen.get(name, 0.0) + float(seconds)
    return {**known, **{k: round(v, 1) for k, v in seen.items()}}


if __name__ == "__main__":
    command, times = sys.argv[1], Path(sys.argv[2])
    if command == "split":
        for name, half in zip(("one.txt", "two.txt"), split(sys.stdin.read().split(), load(times))):
            Path(name).write_text("".join(f"{line}\n" for line in half))
    else:
        times.write_text(json.dumps(record(sys.argv[3:], load(times)), indent=0, sort_keys=True))
