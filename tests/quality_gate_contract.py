#!/usr/bin/env python3
"""Focused unit contracts for the Python quality-gate boundary."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from quality_gate import (  # noqa: E402
    EXECUTION_PREREQUISITES,
    GateError,
    QualityGate,
    exact_products_enabled,
    gate_contract_process_limit,
    gate_contract_definitions,
    gate_orchestrator_limit,
    include_gate_orchestrators,
    parse_name_status,
    parse_options,
    provider_test_parts,
    run_app_stage,
    run_distribution_parts,
    run_provider_parts,
    run_static_contracts,
    split_quality_pipeline_jobs,
    split_swift_build_jobs,
    ui_coverage_binary,
)
from quality_gate import provider_runtime_payload  # noqa: E402
from quality_policy import POLICY_FILE, Policy  # noqa: E402


class QualityGateContract(unittest.TestCase):
    def test_provider_payload_follows_exact_product_binding(self) -> None:
        root = Path("/repo")
        with patch.dict("os.environ", {}, clear=False):
            for name in (
                "DETACH_QUALITY_EXACT_PRODUCTS",
                "GITHUB_ACTIONS",
                "DETACH_QUALITY_GATE_AUTHORITY",
            ):
                os.environ.pop(name, None)
            self.assertEqual(
                provider_runtime_payload(root),
                root / "app/build/Detach.app/Contents/Resources/DetachCLI",
            )
            os.environ["DETACH_QUALITY_EXACT_PRODUCTS"] = "1"
            with self.assertRaisesRegex(GateError, "hosted CI authority"):
                provider_runtime_payload(root)
            os.environ["GITHUB_ACTIONS"] = "true"
            os.environ["DETACH_QUALITY_GATE_AUTHORITY"] = "ci-shard"
            self.assertEqual(
                provider_runtime_payload(root), root / "app/.build/quality-runtime"
            )

    def test_relative_result_root_becomes_absolute_evidence(self) -> None:
        relative = Path("app/build/relative-quality-evidence")
        with patch.dict(
            "os.environ",
            {"DETACH_QUALITY_GATE_RESULT_ROOT": str(relative)},
            clear=False,
        ), patch("quality_gate.git_text", return_value="a" * 40):
            gate = QualityGate(parse_options([]))
        self.assertEqual(gate.result_root, (Path.cwd() / relative).absolute())
        self.assertTrue(gate.run_dir.is_absolute())

    def test_environment_document_marks_an_unavailable_platform_tool(self) -> None:
        gate = QualityGate.__new__(QualityGate)
        with patch("quality_gate.run", side_effect=GateError("missing")):
            self.assertEqual(gate.command_version(["missing-tool"]), "unavailable")

    def test_name_status_preserves_rename_and_unusual_paths(self) -> None:
        raw = b"R100\0old name\0new\nname\0A\0plain\0"
        self.assertEqual(
            parse_name_status(raw),
            [("R100", "old name", "new\nname"), ("A", "plain", None)],
        )

    def test_name_status_fails_closed_on_a_partial_rename(self) -> None:
        with self.assertRaisesRegex(GateError, "malformed rename/copy entry"):
            parse_name_status(b"R100\0old\0")

    def test_manifest_reader_marks_duplicate_values_invalid(self) -> None:
        gate = QualityGate.__new__(QualityGate)
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.tsv"
            manifest.write_text(
                "policy\t17\npolicy\t16\nresult\tpassed\n", encoding="utf-8"
            )
            values = gate.manifest_values(manifest)
        self.assertIsNone(values["policy"])
        self.assertEqual(values["result"], "passed")

    def test_execution_prerequisites_reference_policy_stages(self) -> None:
        stages = set(Policy(POLICY_FILE).stages_by_name)
        self.assertLessEqual(set(EXECUTION_PREREQUISITES), stages)
        self.assertTrue(all(EXECUTION_PREREQUISITES.values()))
        prerequisites = {
            prerequisite
            for values in EXECUTION_PREREQUISITES.values()
            for prerequisite in values
        }
        self.assertLessEqual(prerequisites, stages)

    def test_local_change_contracts_skip_repository_orchestrator_shards(self) -> None:
        all_contracts = gate_contract_definitions(ROOT, include_orchestrators=True)
        focused = gate_contract_definitions(ROOT, include_orchestrators=False)
        focused_names = {contract[0] for contract in focused}
        self.assertTrue(focused_names)
        self.assertFalse(any(name.startswith("orchestrator-") for name in focused_names))
        self.assertEqual(
            focused_names,
            {
                contract[0]
                for contract in all_contracts
                if not contract[0].startswith("orchestrator-")
            },
        )
        self.assertLess(len(focused), len(all_contracts))
        self.assertFalse(include_gate_orchestrators("change", ""))
        self.assertTrue(include_gate_orchestrators("repository", ""))
        self.assertTrue(include_gate_orchestrators("change", "gate-contract"))

    def test_gate_orchestrator_capacity_tracks_available_processors(self) -> None:
        self.assertEqual(gate_orchestrator_limit(10), 4)
        self.assertEqual(gate_orchestrator_limit(8), 4)
        self.assertEqual(gate_orchestrator_limit(4), 2)
        self.assertEqual(gate_contract_process_limit(10), 4)
        self.assertEqual(gate_contract_process_limit(4), 4)

    def test_public_shell_entry_point_is_thin(self) -> None:
        wrapper = (ROOT / "scripts/quality-gate").read_text(encoding="utf-8")
        self.assertLessEqual(len(wrapper.splitlines()), 12)
        self.assertIn('exec python3 "$ROOT/tools/quality_gate.py" "$@"', wrapper)
        self.assertNotIn("jq ", wrapper)
        self.assertNotIn("awk ", wrapper)

    def test_app_builds_normal_bundle_and_release_coverage_in_parallel(self) -> None:
        events: list[str] = []

        class FakeProcess:
            def __init__(self, command, *, cwd, env):
                self.command = command
                self.cwd = cwd
                self.env = env
                events.append("coverage-started")

            def wait(self):
                events.append("coverage-finished")
                return 0

        def fake_child_run(command, *, cwd=ROOT, env=None):
            self.assertEqual(events, ["coverage-started"])
            self.assertEqual(command, [str(ROOT / "app/scripts/make-app.sh")])
            self.assertEqual(env["DETACH_SWIFT_BUILD_JOBS"], "5")
            self.assertEqual(env["DETACH_QUALITY_APP_SCRATCH"], "1")
            events.append("normal-finished")
            return 0

        with patch.dict(
            "os.environ",
            {"DETACH_QUALITY_GATE_SELECTED_STAGES": "app,quality-contracts"},
            clear=False,
        ), patch("quality_gate.os.cpu_count", return_value=10), patch(
            "quality_gate.subprocess.Popen", FakeProcess
        ), patch("quality_gate.child_run", fake_child_run):
            self.assertEqual(run_app_stage(ROOT), 0)

        self.assertEqual(
            events,
            ["coverage-started", "normal-finished", "coverage-finished"],
        )
        self.assertEqual(split_swift_build_jobs(10), (5, 5))
        self.assertEqual(split_quality_pipeline_jobs(3), (1, 1, 1))
        self.assertEqual(split_quality_pipeline_jobs(10), (4, 3, 3))
        self.assertEqual(
            ui_coverage_binary(ROOT),
            ROOT / "app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp",
        )
        self.assertEqual(
            ui_coverage_binary(ROOT, exact_products=True),
            ROOT / "app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp",
        )

    def test_exact_hosted_app_is_verified_while_coverage_builds(self) -> None:
        commands: list[list[str]] = []

        class FakeProcess:
            def __init__(self, command, *, cwd, env):
                self.command = command

            def wait(self):
                return 0

        def fake_child_run(command, *, cwd=ROOT, env=None):
            commands.append(command)
            return 0

        environment = {
            "DETACH_QUALITY_EXACT_APP": "1",
            "DETACH_QUALITY_GATE_SELECTED_STAGES": "app,quality-contracts",
            "DETACH_QUALITY_GATE_AUTHORITY": "ci-shard",
            "GITHUB_ACTIONS": "true",
        }
        with patch.dict("os.environ", environment, clear=True), patch(
            "quality_gate.subprocess.Popen", FakeProcess
        ), patch("quality_gate.child_run", fake_child_run):
            self.assertEqual(run_app_stage(ROOT), 0)
        self.assertEqual(commands, [[str(ROOT / "app/scripts/verify-app.sh")]])

        environment["DETACH_QUALITY_GATE_AUTHORITY"] = "local-diagnostic"
        with patch.dict("os.environ", environment, clear=True):
            self.assertEqual(run_app_stage(ROOT), 2)

    def test_exact_products_are_hosted_only_and_skip_coverage_build(self) -> None:
        commands: list[list[str]] = []

        def fake_child_run(command, *, cwd=ROOT, env=None):
            commands.append(command)
            return 0

        environment = {
            "DETACH_QUALITY_EXACT_APP": "1",
            "DETACH_QUALITY_EXACT_PRODUCTS": "1",
            "DETACH_QUALITY_GATE_SELECTED_STAGES": "app,quality-contracts",
            "DETACH_QUALITY_GATE_AUTHORITY": "ci-shard",
            "GITHUB_ACTIONS": "true",
        }
        with patch.dict("os.environ", environment, clear=True), patch(
            "quality_gate.subprocess.Popen"
        ) as coverage, patch("quality_gate.child_run", fake_child_run):
            self.assertTrue(exact_products_enabled())
            self.assertEqual(run_app_stage(ROOT), 0)
        coverage.assert_not_called()
        self.assertEqual(commands, [[str(ROOT / "app/scripts/verify-app.sh")]])

        environment["DETACH_QUALITY_GATE_AUTHORITY"] = "local-diagnostic"
        with patch.dict("os.environ", environment, clear=True):
            with self.assertRaisesRegex(GateError, "hosted CI authority"):
                exact_products_enabled()

    def test_provider_stages_receive_the_exact_product_binding(self) -> None:
        environment = {
            "DETACH_QUALITY_GATE_TEST_MODE": "1",
            "DETACH_QUALITY_EXACT_PRODUCTS": "1",
            "DETACH_QUALITY_EXACT_APP": "1",
        }
        with patch.dict("os.environ", environment, clear=False):
            gate = QualityGate(parse_options([]))
            for stage in ("codex", "claude", "swift", "ui-e2e"):
                self.assertEqual(
                    gate.stage_environment(stage).get("DETACH_QUALITY_EXACT_PRODUCTS"), "1",
                    stage,
                )
            for stage in ("static", "distribution", "tmux-runtime"):
                self.assertNotIn(
                    "DETACH_QUALITY_EXACT_PRODUCTS", gate.stage_environment(stage), stage
                )
            self.assertNotIn("DETACH_QUALITY_EXACT_APP", gate.stage_environment("codex"))

    def test_codex_parts_get_private_artifact_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            suite = root / "tests/run.sh"
            suite.parent.mkdir()
            suite.write_text(
                "#!/bin/bash\n"
                "set -eu\n"
                "printf '%s\\t%s\\n' \"$DETACH_CODEX_TEST_PART\" "
                "\"$DETACH_PROVIDER_TEST_ARTIFACT_DIR\"\n",
                encoding="utf-8",
            )
            suite.chmod(0o755)
            run_dir = root / "evidence"
            run_dir.mkdir()
            artifacts = run_dir / "codex-artifacts"
            environment = {
                "PATH": "/usr/bin:/bin",
                "DETACH_PROVIDER_TEST_ARTIFACT_DIR": str(artifacts),
            }
            events = run_dir / "codex-events.jsonl"
            with patch.dict(
                "os.environ",
                {
                    "DETACH_QUALITY_SCENARIO_STAGE": "codex",
                    "DETACH_QUALITY_SCENARIO_EVENTS": str(events),
                },
            ), patch("quality_gate.os.cpu_count", return_value=3):
                self.assertEqual(
                    run_provider_parts(root, run_dir, "codex", environment),
                    0,
                )
            for part in (
                "guardrails",
                "lifecycle-recovery",
                "resume-identity",
            ):
                log = (run_dir / f"codex-parts/{part}.log").read_text(
                    encoding="utf-8"
                )
                self.assertEqual(log, f"{part}\t{artifacts / part}\n")
            records = [
                json.loads(line)
                for line in events.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(len(records), 10)
            self.assertEqual(
                {(record["kind"], record["id"]) for record in records},
                {
                    (kind, f"SC-SESSION-{scenario}-CODEX")
                    for kind in ("begin", "pass")
                    for scenario in ("CREATE", "PERSIST", "STOP", "RECOVER", "DELETE")
                },
            )
            with patch("quality_gate.os.cpu_count", return_value=10):
                self.assertEqual(
                    provider_test_parts("codex"),
                    (
                        "delete",
                        "resume",
                        "crash",
                        "lifecycle",
                        "preflight",
                        "recovery",
                        "identity",
                    ),
                )

    def test_static_contracts_keep_separate_deterministic_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tests = root / "tests"
            tests.mkdir()
            names = (
                "docs-contract.sh",
                "shell-safety.sh",
                "test-suite-contract.sh",
            )
            for name in names:
                script = tests / name
                script.write_text(
                    f"#!/bin/bash\nprintf '%s\\n' '{name}'\n",
                    encoding="utf-8",
                )
                script.chmod(0o755)
            run_dir = root / "evidence"
            run_dir.mkdir()
            self.assertEqual(run_static_contracts(root, run_dir), 0)
            logs = run_dir / "static-parts"
            self.assertEqual(
                (logs / "documentation.log").read_text(encoding="utf-8"),
                "docs-contract.sh\n",
            )
            self.assertEqual(
                (logs / "suite-inventory.log").read_text(encoding="utf-8"),
                "test-suite-contract.sh\n",
            )

    def test_claude_parts_get_private_artifact_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            suite = root / "tests/run-claude.sh"
            suite.parent.mkdir()
            suite.write_text(
                "#!/bin/bash\n"
                "set -eu\n"
                "printf '%s\\t%s\\n' \"$DETACH_CLAUDE_TEST_PART\" "
                "\"$DETACH_PROVIDER_TEST_ARTIFACT_DIR\"\n",
                encoding="utf-8",
            )
            suite.chmod(0o755)
            run_dir = root / "evidence"
            run_dir.mkdir()
            artifacts = run_dir / "claude-artifacts"
            environment = {
                "PATH": "/usr/bin:/bin",
                "DETACH_PROVIDER_TEST_ARTIFACT_DIR": str(artifacts),
            }
            events = run_dir / "claude-events.jsonl"
            with patch.dict(
                "os.environ",
                {
                    "DETACH_QUALITY_SCENARIO_STAGE": "claude",
                    "DETACH_QUALITY_SCENARIO_EVENTS": str(events),
                },
            ), patch("quality_gate.os.cpu_count", return_value=3):
                self.assertEqual(
                    run_provider_parts(root, run_dir, "claude", environment),
                    0,
                )
            for part in ("session", "history"):
                log = (run_dir / f"claude-parts/{part}.log").read_text(
                    encoding="utf-8"
                )
                self.assertEqual(log, f"{part}\t{artifacts / part}\n")
            records = [
                json.loads(line)
                for line in events.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(len(records), 10)
            self.assertEqual(
                {(record["kind"], record["id"]) for record in records},
                {
                    (kind, f"SC-SESSION-{scenario}-CLAUDE")
                    for kind in ("begin", "pass")
                    for scenario in ("CREATE", "PERSIST", "STOP", "RECOVER", "DELETE")
                },
            )
            with patch("quality_gate.os.cpu_count", return_value=10):
                self.assertEqual(
                    provider_test_parts("claude"),
                    ("lifecycle-guardrails", "recovery", "history"),
                )

    def test_distribution_parts_keep_separate_logs_and_scenario_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            suite = root / "tests/distribution.sh"
            suite.parent.mkdir()
            suite.write_text(
                "#!/bin/bash\n"
                "set -eu\n"
                "[ \"$DETACH_QUALITY_PARTITIONED_DISTRIBUTION\" = 1 ]\n"
                "root=\"${GATE_DISTRIBUTION_PARALLEL_ROOT:?}\"\n"
                "part=\"$DETACH_DISTRIBUTION_TEST_PART\"\n"
                "peer=runtime\n"
                "[ \"$part\" = runtime ] && peer=shells\n"
                ": >\"$root/$part\"\n"
                "attempt=0\n"
                "while [ ! -f \"$root/$peer\" ] && [ \"$attempt\" -lt 40 ]; do\n"
                "  attempt=$((attempt + 1))\n"
                "  sleep 0.05\n"
                "done\n"
                "[ -f \"$root/$peer\" ]\n"
                "printf '%s\\n' \"$DETACH_DISTRIBUTION_TEST_PART\"\n",
                encoding="utf-8",
            )
            suite.chmod(0o755)
            run_dir = root / "evidence"
            run_dir.mkdir()
            barrier = root / "barrier"
            barrier.mkdir()
            events = run_dir / "distribution-events.jsonl"
            with patch.dict(
                "os.environ",
                {
                    "DETACH_QUALITY_SCENARIO_STAGE": "distribution",
                    "DETACH_QUALITY_SCENARIO_EVENTS": str(events),
                    "GATE_DISTRIBUTION_PARALLEL_ROOT": str(barrier),
                },
            ):
                self.assertEqual(run_distribution_parts(root, run_dir), 0)
            for part in ("runtime", "shells"):
                self.assertEqual(
                    (run_dir / f"distribution-parts/{part}.log").read_text(
                        encoding="utf-8"
                    ),
                    f"{part}\n",
                )
            records = [
                json.loads(line)
                for line in events.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(len(records), 8)
            self.assertEqual(
                {(record["kind"], record["id"]) for record in records},
                {
                    (kind, scenario)
                    for kind in ("begin", "pass")
                    for scenario in (
                        "SC-INSTALL-CLEAN",
                        "SC-INSTALL-REPAIR",
                        "SC-DOCTOR-REPORT",
                        "SC-INSTALL-UNINSTALL",
                    )
                },
            )


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QualityGateContract)
    result = unittest.TextTestRunner(verbosity=0).run(suite)
    if not result.wasSuccessful():
        return 1
    print("Quality gate Python contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
