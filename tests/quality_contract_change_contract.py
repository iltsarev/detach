#!/usr/bin/env python3
"""Negative controls for requirement review and direct execution evidence."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from quality_policy import Policy, POLICY_FILE, PolicyError
from quality_contract_change import ContractError, declaration, review, snapshot, event_body
from quality_scenarios import (ScenarioError, executed_tests, finalize_stage,
                               read_jsonl, scenario_context, validate_result)


POLICY = Policy(POLICY_FILE)


def body(rows):
    return "```detach-contract\n" + json.dumps({"schema": 1, "changes": rows}) + "\n```"


def change(identity="QC-RUNTIME-STORAGE", **overrides):
    value = {"requirement": identity, "change": "MODIFIED",
             "reason": "Reject a symlink before a restore can replace owned data.",
             "scenarios": ["SC-STATE-RESTORE-UNIT"]}
    value.update(overrides)
    return value


class ContractChangeTests(unittest.TestCase):
    def test_method_in_another_class_in_the_same_file_is_rejected(self):
        source = POLICY_FILE.read_text().replace(
            "DetachAppTests.OnboardingStepTests/testMissingProviderBlocksOnlyFirstOnboarding",
            "DetachAppTests.SetupGuidanceTests/testMissingProviderBlocksOnlyFirstOnboarding",
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.tsv"
            path.write_text(source)
            with self.assertRaisesRegex(PolicyError, "mapped test is missing"):
                Policy(path).validate_tracked_paths()

    def test_missing_or_duplicate_owning_anchor_is_rejected(self):
        target = ROOT / "docs/specs/state.md"
        original_read = Path.read_text
        anchor = '<a id="qc-runtime-storage"></a>'
        for replacement in ("", anchor + anchor):
            def read(path, *args, **kwargs):
                text = original_read(path, *args, **kwargs)
                return text.replace(anchor, replacement) if path == target else text
            with self.subTest(replacement=replacement), patch.object(Path, "read_text", read):
                with self.assertRaisesRegex(PolicyError, "owning spec anchor"):
                    POLICY.validate_tracked_paths()

    def test_removed_mapped_test_is_rejected(self):
        target = ROOT / "app/Tests/DetachKitTests/PowerProtectionTests.swift"
        original_read = Path.read_text
        def read(path, *args, **kwargs):
            text = original_read(path, *args, **kwargs)
            return text.replace("testProtectedRequiresBothAssertionAndClosedLidProtection", "removedTest") if path == target else text
        with patch.object(Path, "read_text", read):
            with self.assertRaisesRegex(PolicyError, "mapped test is missing"):
                POLICY.validate_tracked_paths()

    def test_every_changed_requirement_needs_a_declaration(self):
        for text in ("", "No contract change", body([])):
            with self.subTest(text=text), self.assertRaises(ContractError):
                declaration(text, {"QC-RUNTIME-STORAGE": "MODIFIED"}, POLICY)

    def test_create_scenario_cannot_prove_a_restore(self):
        with self.assertRaisesRegex(ContractError, "mapped"):
            declaration(body([change(scenarios=["SC-SESSION-CREATE-CODEX"])]), {}, POLICY)

    def test_duplicate_unknown_placeholder_and_invalid_kinds_are_rejected(self):
        for rows in ([change(), change()], [change("QC-MISSING")],
                     [change(reason="TODO explain this later")], [change(change="fixed")]):
            with self.subTest(rows=rows), self.assertRaises(ContractError):
                declaration(body(rows), {}, POLICY)

    def test_added_or_removed_contract_cannot_be_declared_unchanged(self):
        for kind in ("ADDED", "REMOVED"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ContractError, kind):
                declaration(body([change(change="UNCHANGED")]), {"QC-RUNTIME-STORAGE": kind}, POLICY)

    def test_missing_failed_skipped_or_stage_only_evidence_cannot_pass(self):
        with patch("quality_contract_change.changed_requirements", return_value={"QC-RUNTIME-STORAGE": "MODIFIED"}), patch("quality_contract_change.git", return_value="a" * 40):
            for records in ([], [{"id": "SC-STATE-RESTORE-UNIT", "status": "failed", "granularity": "test-cases"}],
                            [{"id": "SC-STATE-RESTORE-UNIT", "status": "passed", "granularity": "legacy-stage"}]):
                with self.subTest(records=records), self.assertRaisesRegex(ContractError, "no passed direct"):
                    review(ROOT, "base", POLICY, body([change()]), records)
            passed = review(ROOT, "base", POLICY, body([change()]), [{"id": "SC-STATE-RESTORE-UNIT", "status": "passed", "granularity": "test-cases"}])
            self.assertEqual(passed["status"], "passed")
            self.assertEqual(passed["source_commit"], "a" * 40)
            self.assertEqual(len(passed["body_sha256"]), 64)

    def test_actual_git_diff_detects_spec_and_mapping_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True, text=True).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "Contract Test")
            git("config", "user.email", "test@example.invalid")
            (root / "quality").mkdir()
            (root / "docs/specs").mkdir(parents=True)
            policy_path = root / "quality/policy.tsv"
            policy_path.write_text(POLICY_FILE.read_text())
            (root / "docs/specs/state.md").write_text("Old restore contract.\n")
            git("add", "."); git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "docs/specs/state.md").write_text("New restore contract.\n")
            git("add", "."); git("commit", "-qm", "contract")
            from quality_contract_change import changed_requirements
            changes = changed_requirements(root, base, Policy(policy_path))
            self.assertEqual(set(changes), {"QC-RUNTIME-STATE", "QC-RUNTIME-STORAGE"})
            with self.assertRaises(ContractError):
                review(root, base, Policy(policy_path), body([change()]))

    def test_pr_event_must_name_tested_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "event.json"
            path.write_text(json.dumps({"pull_request": {"head": {"sha": "b" * 40}, "body": "text"}}))
            with patch("quality_contract_change.git", return_value="a" * 40), self.assertRaisesRegex(ContractError, "head"):
                event_body(path, ROOT)

    def test_policy_rejects_the_audited_semantic_mislink(self):
        source = POLICY_FILE.read_text()
        lines = []
        for line in source.splitlines():
            fields = line.split("\t")
            if fields[:2] == ["journey", "J-STATE-RECOVER"]:
                fields[4] = "SC-SESSION-CREATE-CODEX,SC-SESSION-CREATE-CLAUDE"
            lines.append("\t".join(fields))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.tsv"
            path.write_text("\n".join(lines) + "\n")
            with self.assertRaises(PolicyError):
                Policy(path)


class ExecutedTestTests(unittest.TestCase):
    identity = "DetachKitTests.PowerProtectionTests/testProtectedRequiresBothAssertionAndClosedLidProtection"

    def test_discovery_skipped_duplicate_and_missing_records_do_not_prove_execution(self):
        suite, name = self.identity.split("/")
        start = f"Test Case '-[{suite} {name}]' started.\n"
        passed = f"Test Case '-[{suite} {name}]' passed (0.012 seconds).\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "swift.log"
            for text, status in [(self.identity, "missing"), (start, "invalid"),
                                 (passed, "invalid"), (start + passed + start + passed, "invalid"),
                                 (start + passed.replace("passed", "skipped"), "skipped"),
                                 (start + passed.replace("passed", "failed"), "failed"),
                                 (start + passed, "passed")]:
                with self.subTest(status=status):
                    path.write_text(text)
                    result = executed_tests(path, [self.identity])[0]
                    self.assertEqual(result["status"], status)
                    if status == "passed": self.assertEqual(result["duration_ms"], 12)

    def test_passed_swift_stage_without_test_events_fails_all_exact_scenarios(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            errors = finalize_stage(policy=POLICY, stage="swift", stage_status="passed",
                stage_duration_seconds=1, stage_log="swift.log", event_path=root / "events.jsonl",
                output_path=root / "stage-scenarios/swift.jsonl")
            self.assertEqual(len(errors), len(POLICY.scenario_tests))

    def test_exact_results_round_trip_and_cannot_hide_a_skipped_test(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lines = []
            for identity in sorted({test for tests in POLICY.scenario_tests.values() for test in tests}):
                suite, name = identity.split("/")
                lines += [f"Test Case '-[{suite} {name}]' started.",
                          f"Test Case '-[{suite} {name}]' passed (0.012 seconds)."]
            (root / "swift.log").write_text("\n".join(lines) + "\n")
            output = root / "stage-scenarios/swift.jsonl"
            errors = finalize_stage(policy=POLICY, stage="swift", stage_status="passed",
                stage_duration_seconds=1, stage_log="swift.log", event_path=root / "events.jsonl",
                output_path=output)
            self.assertEqual(errors, [])
            records = read_jsonl(output, "scenario test evidence")
            for record in records:
                validate_result(record, POLICY, scenario_context(POLICY))
                self.assertEqual(record["status"], "passed")
            records[0]["tests"][0]["status"] = "skipped"
            with self.assertRaisesRegex(ScenarioError, "unproved"):
                validate_result(records[0], POLICY, scenario_context(POLICY))


if __name__ == "__main__":
    unittest.main(verbosity=2)
