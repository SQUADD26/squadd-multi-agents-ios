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
non-photo classes of the changed test files. `--test` keeps the classes that assert (no `Photo` in the name), for
the check that decides the PR's green; `--foto` keeps the classes that take photos (`is_photo`), for the photo job
after it. A test that asserts and also takes a photo is in both.

    git diff --name-only BASE...HEAD | python3 ci/pr_tests.py [--rosso | --test | --foto]
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


def is_photo(name, body):
    """A class that takes photos: named so, or reading FOTO_DIR / BRAND_PHOTOS_DIR in its own code. The doc
    comment above the next class falls at the end of `body` and doesn't count."""
    own = re.sub(r"(?:\n[ \t]*(?://[^\n]*|@\w+)?)*\s*\Z", "", body)
    return "Photo" in name or bool(PHOTO.search(own))


def select(changed, tests=TESTS, red=False, part=None):
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
                if part is None or (part == "test" and "Photo" not in name) or (part == "foto" and is_photo(name, body)):
                    picked.add(name)
    if not red and part != "foto" and any(p.name == "Localizable.xcstrings" for p in changed):
        picked.add("LocalizationCatalogTests")
    return sorted(picked)


if __name__ == "__main__":
    args = sys.argv[1:]
    part = "test" if "--test" in args else "foto" if "--foto" in args else None
    for name in select(sys.stdin.read().splitlines(), red="--rosso" in args, part=part):
        print(f"-only-testing:HermesMobileTests/{name}")
