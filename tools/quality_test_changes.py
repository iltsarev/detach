#!/usr/bin/env python3
"""Advisory report of weakened or rewritten assertions in existing tests.

A regression test can be inverted to match regressed behavior while every
check stays green (#246). This report lists removed or rewritten assertion
lines in test files that already existed at the base commit, so a reviewer
sees them. It never fails a check.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TEST_PATH = re.compile(r"^(app/Tests/.+\.swift|tests/.+\.(sh|py))$")
ASSERTION = re.compile(
    r"XCTAssert|XCTFail|XCTUnwrap|#expect|#require|\bassert[A-Z(]|\bfail\("
    r"|^\s*!?\s*\[\s|\bgrep\s+-[A-Za-z]*[Fq]|\bexit\s+1\b"
)
SWIFT_TEST = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\(")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@")


def git(root: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True, capture_output=True, text=True,
    ).stdout


def existing_at(root: Path, base: str, path: str) -> list[str] | None:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{base}:{path}"],
        capture_output=True, text=True,
    )
    return result.stdout.splitlines() if result.returncode == 0 else None


def enclosing_test(lines: list[str], line_number: int) -> str:
    for index in range(min(line_number, len(lines)) - 1, -1, -1):
        match = SWIFT_TEST.search(lines[index])
        if match:
            return match.group(1)
    return ""


def report(root: Path, base: str, head: str) -> list[str]:
    findings: list[str] = []
    changed = git(root, "diff", "--name-only", "--diff-filter=MD", base, head).splitlines()
    for path in sorted(changed):
        if not TEST_PATH.match(path):
            continue
        old_lines = existing_at(root, base, path)
        if old_lines is None:
            continue
        diff = git(root, "diff", "--unified=0", base, head, "--", path)
        old_number = 0
        for line in diff.splitlines():
            hunk = HUNK.match(line)
            if hunk:
                old_number = int(hunk.group(1))
                continue
            if line.startswith("---") or line.startswith("+++"):
                continue
            if line.startswith("-"):
                text = line[1:]
                if ASSERTION.search(text):
                    test = enclosing_test(old_lines, old_number)
                    where = f"{path}:{old_number}" + (f" ({test})" if test else "")
                    findings.append(f"{where}: {text.strip()[:160]}")
                old_number += 1
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--root", type=Path, default=ROOT)
    arguments = parser.parse_args()
    try:
        findings = report(arguments.root, arguments.base, arguments.head)
    except subprocess.CalledProcessError as error:
        print(f"quality-test-changes: git failed: {error.stderr.strip()}", file=sys.stderr)
        return 2
    print("## Changed assertions in existing tests (advisory)\n")
    if not findings:
        print("No removed or rewritten assertion lines in existing tests.")
        return 0
    print(
        "Review each line: an intended behavior change should say so in the "
        "pull request; a regression test must not be inverted.\n"
    )
    print("```text")
    for finding in findings:
        print(finding)
    print("```")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
