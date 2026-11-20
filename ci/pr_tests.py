#!/usr/bin/env python3
"""Print the `-only-testing:` arguments for the tests a PR touches, one per line.

Reads the PR's changed paths on stdin and selects test classes from HermesMobileTests:
- every class in a changed test file;
- every class in `<Name>Tests.swift` for a changed `<Name>.swift`;
- the photo classes (they read FOTO_DIR or BRAND_PHOTOS_DIR) that name a changed `<Name>.swift`,
  so a touched screen gets its photos;
- LocalizationCatalogTests when the String Catalog changes.
Nothing selected prints nothing: the PR still builds and checks the catalog. The full suite runs at night.
With `--rosso` (a `rosso/*` branch, which only shows that a test fails without its change) it selects just the
non-photo classes of the changed test files.

    git diff --name-only BASE...HEAD | python3 ci/pr_tests.py [--rosso]
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TESTS = REPO / "HermesMobileTests"
CLASS = re.compile(r"^(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(\w*TestCase)\b", re.M)
PHOTO = re.compile(r"\b(?:FOTO_DIR|BRAND_PHOTOS_DIR)\b")


def classes(text):
    """[(class name, its source text)] for every XCTestCase subclass in a file."""
    found = list(CLASS.finditer(text))
    return [(m.group(1), text[m.start():found[i + 1].start() if i + 1 < len(found) else len(text)]) for i, m in enumerate(found)]


def select(changed, tests=TESTS, red=False):
    changed = [Path(p) for p in changed if p.strip()]
    names = {p.stem for p in changed if p.suffix == ".swift" and p.parts[:1] != ("HermesMobileTests",)}
    picked = set()
    for file in sorted(tests.rglob("*.swift")):
        rel = file.relative_to(tests.parent)
        whole = rel in changed or file.stem in {f"{n}Tests" for n in names}
        for name, body in classes(file.read_text(encoding="utf-8")):
            if red:
                if rel in changed and not PHOTO.search(body):
                    picked.add(name)
            elif whole or (PHOTO.search(body) and any(re.search(rf"\b{re.escape(n)}\b", body) for n in names)):
                picked.add(name)
    if not red and any(p.name == "Localizable.xcstrings" for p in changed):
        picked.add("LocalizationCatalogTests")
    return sorted(picked)


if __name__ == "__main__":
    for name in select(sys.stdin.read().splitlines(), red="--rosso" in sys.argv[1:]):
        print(f"-only-testing:HermesMobileTests/{name}")
