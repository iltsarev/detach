#!/usr/bin/env python3
"""Contracts for the advisory changed-assertion report."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/quality_test_changes.py"


def git(root: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


class QualityTestChangesContract(unittest.TestCase):
    def run_report(self, root: Path, base: str) -> str:
        result = subprocess.run(
            ["python3", str(TOOL), "--root", str(root), "--base", base],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_reports_only_rewritten_assertions_in_existing_tests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            git(root, "init", "-q")
            git(root, "config", "user.email", "test@example.invalid")
            git(root, "config", "user.name", "Test")
            existing = root / "app/Tests/Kit/GuardTests.swift"
            existing.parent.mkdir(parents=True)
            existing.write_text(
                "final class GuardTests {\n"
                "    func testZombieCanReregister() {\n"
                "        XCTAssertEqual(backend.registerCalls, 1)\n"
                "        let note = 1\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            git(root, "add", ".")
            git(root, "commit", "-q", "-m", "base")
            base = git(root, "rev-parse", "HEAD")

            # Inverting an assertion in an existing test is reported with its
            # test name; a non-assertion edit and a brand-new test are not.
            existing.write_text(
                "final class GuardTests {\n"
                "    func testZombieCanReregister() {\n"
                "        XCTAssertEqual(backend.registerCalls, 0)\n"
                "        let note = 2\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            new = root / "app/Tests/Kit/NewTests.swift"
            new.write_text("func testNew() { XCTAssertTrue(true) }\n", encoding="utf-8")
            git(root, "add", ".")
            git(root, "commit", "-q", "-m", "change")

            output = self.run_report(root, base)
            self.assertIn(
                "app/Tests/Kit/GuardTests.swift:3 (testZombieCanReregister): "
                "XCTAssertEqual(backend.registerCalls, 1)",
                output,
            )
            self.assertNotIn("let note", output)
            self.assertNotIn("NewTests.swift", output)

    def test_reports_nothing_without_assertion_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            git(root, "init", "-q")
            git(root, "config", "user.email", "test@example.invalid")
            git(root, "config", "user.name", "Test")
            (root / "README.md").write_text("a\n", encoding="utf-8")
            git(root, "add", ".")
            git(root, "commit", "-q", "-m", "base")
            base = git(root, "rev-parse", "HEAD")
            (root / "README.md").write_text("b\n", encoding="utf-8")
            git(root, "commit", "-q", "-am", "docs")
            self.assertIn(
                "No removed or rewritten assertion lines", self.run_report(root, base)
            )


if __name__ == "__main__":
    unittest.main()
