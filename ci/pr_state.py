#!/usr/bin/env python3
"""Give the PR iOS job the build state of its own branch, so a push rebuilds only what it changed.

The runner builds in one fixed place (the workspace and _work/DerivedData: DerivedData keeps absolute
paths). Between runs each branch's checkout and DerivedData are parked in _work/pr-states/<branch>/ by
renaming, which is instant. A branch seen for the first time takes the parked state closest to its head,
which keeps an APFS clone (copy-on-write, ~0.1 s) for itself: the fewest app files to recompile, and never one that
would delete Swift files (a deleted input makes the Swift driver rebuild the whole module).

    python3 ci/pr_state.py <branch> <head sha>

Runs before the checkout; the workspace it leaves holds some earlier commit that the job then fetches over.
"""

import ctypes
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

KEEP = 8  # parked states; the oldest beyond this are deleted (each is up to ~2 GB once it diverges)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def clone(src, dst):
    """One APFS clonefile(2) of a whole tree, file dates kept: 0.1 s where `cp -c -pR` takes 2 s on DerivedData."""
    libc = ctypes.CDLL("libc.dylib", use_errno=True)
    if libc.clonefile(os.fsencode(src), os.fsencode(dst), 0):
        raise OSError(ctypes.get_errno(), f"clonefile {src} -> {dst}")


def cost(name_status):
    """Rebuild cost for `git diff --name-status` output. A deletion rebuilds a whole module; any other app file
    re-emits the app module (~20 s) and may recompile every test; a test file recompiles only itself."""
    swift = [line.split("\t") for line in name_status.splitlines() if line.endswith(".swift")]
    return sum(100_000 if fields[0].startswith("D") else 1 if "Tests/" in fields[-1] else 100 for fields in swift)


def closest(repo, head, candidates):
    """The candidate (name, sha) whose tree is cheapest to rebuild into `head`."""
    missing = [sha for sha in [head, *(sha for _, sha in candidates)] if git(repo, "cat-file", "-e", sha).returncode]
    if missing and git(repo, "fetch", "-q", "--no-tags", "origin", *missing).returncode:
        for sha in missing:  # one commit gone from GitHub fails the whole fetch
            git(repo, "fetch", "-q", "--no-tags", "origin", sha)
    scored = []
    for name, sha in candidates:
        diff = git(repo, "diff", "--name-status", sha, head)
        if diff.returncode == 0:
            scored.append((cost(diff.stdout), name))
    return min(scored)[1] if scored else candidates[0][0]


def main(branch, head):
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    work = workspace.parent.parent
    derived, states = work / "DerivedData", work / "pr-states"
    marker = states / "current"
    states.mkdir(exist_ok=True)
    current = marker.read_text().strip() if marker.exists() else "start"
    mine = re.sub(r"[^A-Za-z0-9._-]", "-", branch)
    if current == mine:
        print(f"Build state: {mine}, kept from its last run")
        return
    os.chdir(work)
    parked = states / current
    parked.mkdir(exist_ok=True)
    # A run cancelled after parking but before the marker leaves `current`'s state parked and an empty
    # workspace in its place: the parked one is the real state, so what sits in the workspace goes.
    for part, live in (("src", workspace), ("dd", derived)):
        if (parked / part).exists() and live.exists():
            discard(work, live, f"{current}-{part}")
            print(f"Build state: {current}'s {part} was already parked (a cancelled run); discarding the leftover")
    if workspace.exists():
        workspace.rename(parked / "src")
    if derived.exists():
        derived.rename(parked / "dd")
    if (states / mine).is_dir():
        (states / mine / "src").rename(workspace)
        (states / mine / "dd").rename(derived)
        shutil.rmtree(states / mine)
        print(f"Build state: {mine}, back from {states / mine}")
    else:
        candidates = [(p.name, git(p / "src", "rev-parse", "HEAD").stdout.strip())
                      for p in states.iterdir() if (p / "dd").is_dir() and (p / "src").is_dir()]
        base = closest(parked / "src", head, sorted(candidates, key=lambda c: c[0] != current))
        # The build system records each file's inode, and a clone has new ones: a no-op build after a clone
        # redoes the asset catalog and the copies (~6 s). So the new branch takes the base's own files and the
        # base keeps the clone, paying that once if its branch runs again.
        for part, dest in (("src", workspace), ("dd", derived)):
            spare = states / base / f"{part}-clone"
            clone(states / base / part, spare)
            (states / base / part).rename(dest)
            spare.rename(states / base / part)
        print(f"Build state: {mine}, new, from {base} (which keeps a clone)")
    # After a clone git's index holds old inodes: without this the checkout rewrites every file.
    git(workspace, "update-index", "-q", "--refresh")
    marker.write_text(mine)
    old = sorted((p for p in states.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True)[KEEP:]
    for p in old:
        discard(work, p, p.name)
        print(f"Deleting the old build state {p.name}")


def discard(work, path, name):
    """Renamed out of the way at once, deleted in the background: a state is ~100k files (~1 s)."""
    gone = work / f"pr-state-deleting-{name}-{os.getpid()}"
    path.rename(gone)
    subprocess.Popen([sys.executable, "-c", "import shutil, sys; shutil.rmtree(sys.argv[1])", str(gone)],
                     start_new_session=True)


if __name__ == "__main__":
    main(*sys.argv[1:3])
