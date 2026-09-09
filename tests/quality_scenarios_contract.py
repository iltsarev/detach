#!/usr/bin/env python3
"""Deterministic contracts for scenario event and result evidence."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import POLICY_FILE, Policy  # noqa: E402
from quality_scenarios import (  # noqa: E402
    ScenarioError,
    assemble,
    finalize_stage,
    main as scenario_main,
    next_event_time_ns,
    read_jsonl,
    record_event,
    rerun,
    run_bounded,
)


class QualityScenarioContract(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = Policy(POLICY_FILE)

    @staticmethod
    def scenario_record(**overrides: object) -> dict[str, object]:
        record: dict[str, object] = {
            "schema": 1,
            "id": "SC-UPDATE-CHECK",
            "stage": "release-preflight",
            "policy_status": "instrumented",
            "status": "failed",
            "granularity": "scenario",
            "duration_ms": 12,
            "requirements": ["QC-APP-UPDATE"],
            "journeys": ["J-UPDATE-CHECK"],
            "rerun": "scripts/quality-scenarios rerun SC-UPDATE-CHECK",
            "command": "tests/release-preflight.sh",
            "log": "release-preflight.log",
            "message": "failed",
        }
        record.update(overrides)
        return record

    def test_instrumented_events_produce_addressable_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "events.jsonl"
            output = root / "stage" / "release-preflight.jsonl"
            output.parent.mkdir()
            environment = {
                "DETACH_QUALITY_SCENARIO_EVENTS": str(events),
                "DETACH_QUALITY_SCENARIO_STAGE": "release-preflight",
            }
            with patch.dict("os.environ", environment, clear=False):
                record_event("begin", "SC-UPDATE-CHECK")
                record_event("pass", "SC-UPDATE-CHECK")
            errors = finalize_stage(
                policy=self.policy,
                stage="release-preflight",
                stage_status="passed",
                stage_duration_seconds=3,
                stage_log="release-preflight.log",
                event_path=events,
                output_path=output,
            )
            records = read_jsonl(output, "result")
        self.assertEqual(errors, [])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["id"], "SC-UPDATE-CHECK")
        self.assertEqual(records[0]["status"], "passed")
        self.assertEqual(records[0]["granularity"], "scenario")
        self.assertIn("QC-APP-UPDATE", records[0]["requirements"])
        self.assertEqual(records[0]["journeys"], ["J-UPDATE-CHECK"])

    def test_pass_without_begin_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            environment = {
                "DETACH_QUALITY_SCENARIO_EVENTS": str(Path(directory) / "events.jsonl"),
                "DETACH_QUALITY_SCENARIO_STAGE": "release-preflight",
            }
            with patch.dict("os.environ", environment, clear=False):
                with self.assertRaisesRegex(ScenarioError, "passed without one begin"):
                    record_event("pass", "SC-UPDATE-CHECK")

    def test_event_time_stays_ordered_across_process_clock_origins(self) -> None:
        prior = [{"time_ns": 200}]
        with patch("quality_scenarios.time.time_ns", return_value=100):
            self.assertEqual(next_event_time_ns(prior), 201)

    def test_event_command_records_multiple_scenarios_in_one_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events.jsonl"
            environment = {
                "DETACH_QUALITY_SCENARIO_EVENTS": str(events),
                "DETACH_QUALITY_SCENARIO_STAGE": "ui-e2e",
            }
            with patch.dict("os.environ", environment, clear=False):
                self.assertEqual(scenario_main([
                    "event",
                    "begin",
                    "SC-UI-DASHBOARD",
                    "SC-UI-SESSION-DETAIL",
                ]), 0)
            records = read_jsonl(events, "events")
        self.assertEqual(
            [record["id"] for record in records],
            ["SC-UI-DASHBOARD", "SC-UI-SESSION-DETAIL"],
        )

    def test_missing_marker_is_a_contract_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "stage.jsonl"
            errors = finalize_stage(
                policy=self.policy,
                stage="release-preflight",
                stage_status="passed",
                stage_duration_seconds=3,
                stage_log="release-preflight.log",
                event_path=root / "missing-events.jsonl",
                output_path=output,
            )
            records = read_jsonl(output, "result")
        self.assertEqual(errors, ["SC-UPDATE-CHECK emitted no markers"])
        self.assertEqual(records[0]["status"], "missing")

    def test_aggregate_writes_junit_and_bounded_repair_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage.jsonl"
            log = root / "release-preflight.log"
            log.write_text("\n".join(f"line-{index}" for index in range(150)), encoding="utf-8")
            record = self.scenario_record(log=log.name)
            stage.write_text(json.dumps(record) + "\n", encoding="utf-8")
            output = root / "scenarios.jsonl"
            junit = root / "scenarios.junit.xml"
            repair = root / "repair-bundle.json"
            assemble(
                stage_paths=[stage],
                output_jsonl=output,
                output_junit=junit,
                repair_bundle=repair,
                run_dir=root,
                expected_stages=["release-preflight"],
            )
            repair_document = json.loads(repair.read_text(encoding="utf-8"))
            junit_text = junit.read_text(encoding="utf-8")
        self.assertIn('failures="1"', junit_text)
        self.assertEqual(len(repair_document["failures"][0]["log_tail"]), 100)

    def test_aggregate_rejects_unsafe_or_incomplete_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage.jsonl"
            stage.write_text(
                json.dumps(self.scenario_record(log="../private.log")) + "\n",
                encoding="utf-8",
            )
            arguments = {
                "stage_paths": [stage],
                "output_jsonl": root / "scenarios.jsonl",
                "output_junit": root / "scenarios.junit.xml",
                "repair_bundle": root / "repair-bundle.json",
                "run_dir": root,
                "expected_stages": ["release-preflight"],
            }
            with self.assertRaisesRegex(ScenarioError, "log is unsafe"):
                assemble(**arguments)
            stage.write_text("", encoding="utf-8")
            with self.assertRaisesRegex(ScenarioError, "coverage mismatch"):
                assemble(**arguments)

    def test_instrumented_rerun_uses_the_bounded_owning_stage(self) -> None:
        with patch.dict(
            "os.environ",
            {"DETACH_QUALITY_AUTHORITY": "ci-merge", "GITHUB_ACTIONS": "true"},
            clear=False,
        ), patch("quality_scenarios.run_bounded", return_value=0) as run:
            self.assertEqual(rerun("SC-SESSION-CREATE-CODEX"), 0)
        arguments = run.call_args.args[0]
        keywords = run.call_args.kwargs
        self.assertEqual(
            arguments,
            [str(ROOT / "scripts/quality-gate"), "--stage", "codex"],
        )
        self.assertEqual(
            keywords["timeout"],
            self.policy.stages_by_name["codex"].timeout + 30,
        )
        self.assertNotIn("DETACH_QUALITY_AUTHORITY", keywords["environment"])
        self.assertNotIn("GITHUB_ACTIONS", keywords["environment"])

    def test_legacy_rerun_uses_the_bounded_owning_stage(self) -> None:
        with patch("quality_scenarios.run_bounded", return_value=0) as run:
            self.assertEqual(rerun("SC-POWER-UNIT"), 0)
        self.assertEqual(
            run.call_args.args[0],
            [str(ROOT / "scripts/quality-gate"), "--stage", "swift"],
        )

    def test_bounded_runner_terminates_a_hung_process_group(self) -> None:
        with self.assertRaises(subprocess.TimeoutExpired):
            run_bounded(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                environment=os.environ.copy(),
                timeout=1,
            )


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QualityScenarioContract)
    result = unittest.TextTestRunner(verbosity=0).run(suite)
    if not result.wasSuccessful():
        return 1
    print("Quality scenario contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
