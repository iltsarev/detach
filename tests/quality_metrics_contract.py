#!/usr/bin/env python3
"""Negative contracts for automatic green-main quality metrics."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Optional, Tuple
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import quality_metrics  # noqa: E402
from quality_metrics import build_metrics, collect_coverage  # noqa: E402
from quality_policy import POLICY_FILE, Policy  # noqa: E402


POLICY = Policy(POLICY_FILE)
BASE_COMMIT = "a" * 40
SOURCE_COMMIT = "b" * 40
TESTED_COMMIT = "c" * 40


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def segments(covered: int, total: int) -> list[list[Any]]:
    result: list[list[Any]] = []
    if covered:
        result.append([1, 1, 1, True, True, False])
    if covered < total:
        result.append([covered + 1, 1, 0, True, True, False])
    result.append([total + 1, 1, 0, False, False, False])
    return result


def coverage_document(
    *, ui_covered: int = 9, critical_override: Optional[Tuple[str, int]] = None
) -> dict[str, Any]:
    files = []
    sources = [
        ("app/Sources/DetachApp/Synthetic.swift", ui_covered),
        ("app/Sources/DetachApp/UIE2ETestDriver.swift", 0),
    ]
    sources.extend((path, 9) for path, _ in POLICY.critical)
    for path, covered in sources:
        if critical_override and path == critical_override[0]:
            covered = critical_override[1]
        files.append(
            {
                "filename": f"/fixture/{path}",
                "segments": segments(covered, 10),
                "summary": {
                    "lines": {"count": 10, "covered": covered, "percent": covered * 10.0}
                },
            }
        )
    return {"type": "llvm.coverage.json.export", "version": "2.0.1", "data": [{"files": files}]}


def test_lines(*, remove: str = "") -> list[str]:
    values = [f"{suite}/testEvidence" for suite in POLICY.required_suites if suite != remove]
    values.append("DetachKitTests.SessionHealthTests/testSecondEvidence")
    return values


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_baseline(
    root: Path,
    metrics: Path,
    *,
    include_metrics: bool = True,
    manifest_policy: Optional[int] = None,
    authority: str = "ci-main",
    source_commit: str = BASE_COMMIT,
    promotion_main: Optional[str] = None,
    swift_metrics: Optional[Path] = None,
) -> Path:
    run_dir = root / "run"
    run_dir.mkdir(parents=True)
    artifacts = run_dir / "artifacts.tsv"
    if include_metrics:
        shutil.copyfile(metrics, run_dir / "quality-metrics.json")
        artifact_lines = [
            "schema\t1",
            f"file\tquality-metrics.json\t{digest(run_dir / 'quality-metrics.json')}",
        ]
        if swift_metrics is not None:
            shutil.copyfile(swift_metrics, run_dir / "quality-metrics-swift.json")
            artifact_lines.append(
                "file\tquality-metrics-swift.json\t"
                f"{digest(run_dir / 'quality-metrics-swift.json')}"
            )
        artifacts.write_text("\n".join(artifact_lines) + "\n", encoding="utf-8")
    else:
        artifacts.write_text("schema\t1\n", encoding="utf-8")
    (run_dir / "manifest.tsv").write_text(
        "schema\t4\n"
        f"policy\t{manifest_policy if manifest_policy is not None else POLICY.version}\n"
        f"authority\t{authority}\n"
        "result\tpassed\n"
        f"source_commit\t{source_commit}\n"
        f"base_commit\t{'d' * 40}\n"
        f"artifacts_sha256\t{digest(artifacts)}\n",
        encoding="utf-8",
    )
    if promotion_main is not None:
        manifest = run_dir / "manifest.tsv"
        (run_dir / "promotion.tsv").write_text(
            "schema\t1\n"
            "authority\tci-main\n"
            "result\tpassed\n"
            "repository\towner/repository\n"
            f"main_commit\t{promotion_main}\n"
            f"main_tree\t{'e' * 40}\n"
            f"base_commit\t{'d' * 40}\n"
            f"head_commit\t{'f' * 40}\n"
            f"tested_commit\t{source_commit}\n"
            f"tested_tree\t{'e' * 40}\n"
            "pull_request\t25\n"
            "merged_at\t2026-08-12T12:00:00Z\n"
            "source_run\t123\n"
            "source_run_attempt\t1\n"
            "source_run_url\thttps://github.com/owner/repository/actions/runs/123\n"
            "source_artifact\tquality-gate-evidence-123-1\n"
            f"source_manifest_sha256\t{digest(manifest)}\n",
            encoding="utf-8",
        )
    return run_dir


def invoke(arguments: list[str], *, expected: int = 0, test_mode: bool = True) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if test_mode:
        environment["DETACH_QUALITY_METRICS_TEST_MODE"] = "1"
    else:
        environment.pop("DETACH_QUALITY_METRICS_TEST_MODE", None)
    result = subprocess.run(
        [str(ROOT / "scripts/quality-metrics"), *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"quality metrics returned {result.returncode}, expected {expected}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def evaluate_arguments(
    coverage: Path,
    tests: Path,
    output: Path,
    changed: Path,
    *,
    baseline: Optional[Path] = None,
    authority: str = "local-diagnostic",
    source_commit: str = SOURCE_COMMIT,
    opportunities: Optional[Path] = None,
    profile: str = "",
) -> list[str]:
    arguments = [
        "evaluate",
        "--coverage-json",
        str(coverage),
        "--tests",
        str(tests),
        "--output",
        str(output),
        "--source-commit",
        source_commit,
        "--authority",
        authority,
        "--test-changed-lines",
        str(changed),
    ]
    if baseline is not None:
        arguments.extend(("--baseline-root", str(baseline)))
    if profile:
        arguments.extend(("--coverage-profile", profile))
    if opportunities is not None:
        arguments.extend(("--opportunities-output", str(opportunities)))
    return arguments


def require_text(result: subprocess.CompletedProcess[str], text: str) -> None:
    if text not in result.stderr and text not in result.stdout:
        raise AssertionError(f"missing diagnostic: {text}")


def main() -> None:
    if sys.version_info < (3, 9):
        raise AssertionError("quality metrics require Python 3.9 or newer")
    with tempfile.TemporaryDirectory(prefix="detach-quality-metrics-contract.") as temporary:
        root = Path(temporary)
        coverage = root / "coverage.json"
        tests = root / "tests.txt"
        changed = root / "changed.json"
        baseline_metrics = root / "baseline-metrics.json"
        baseline_root = root / "baseline"

        test_binary = root / "tests-binary"
        unit_profile = root / "unit.profdata"
        app_binary = root / "app-binary"
        profile_directory = root / "ui-profiles"
        profile_directory.mkdir()
        for fixture in (test_binary, unit_profile, app_binary):
            fixture.write_bytes(b"fixture")
        (profile_directory / "ui.profraw").write_bytes(b"fixture")
        coverage_export = json.dumps(coverage_document()).encode("utf-8")
        coverage_commands: list[list[str]] = []

        def fake_coverage_run(
            command: list[str], *, text: bool = True
        ) -> subprocess.CompletedProcess[Any]:
            coverage_commands.append(command)
            if "llvm-profdata" in command:
                Path(command[-1]).write_bytes(b"combined")
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            return subprocess.CompletedProcess(
                command, 0, stdout=coverage_export, stderr=b""
            )

        with patch.object(quality_metrics, "run", side_effect=fake_coverage_run):
            merged_export = quality_metrics.export_coverage(
                test_binary,
                unit_profile,
                [app_binary],
                profile_directory,
            )
        assert merged_export == coverage_document()
        assert len(coverage_commands) == 2
        assert "llvm-profdata" in coverage_commands[0]
        assert str(unit_profile) in coverage_commands[0]
        assert str(profile_directory / "ui.profraw") in coverage_commands[0]
        assert "llvm-cov" in coverage_commands[1]
        assert coverage_commands[1][coverage_commands[1].index("-object") + 1] == str(
            app_binary
        )

        write_json(coverage, coverage_document())
        tests.write_text("\n".join(test_lines()) + "\n", encoding="utf-8")
        write_json(changed, {})
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                baseline_metrics,
                changed,
                source_commit=BASE_COMMIT,
            )
        )
        invoke(["validate", str(baseline_metrics)])
        baseline_document = json.loads(baseline_metrics.read_text(encoding="utf-8"))
        assert baseline_document["schema"] == 2
        assert baseline_document["coverage_profile"] == "swift"
        run_dir = create_baseline(baseline_root, baseline_metrics)

        combined_metrics = root / "combined-metrics.json"
        combined_document = dict(baseline_document)
        combined_document["coverage_profile"] = "combined"
        write_json(combined_metrics, combined_document)
        combined_root = root / "combined-baseline"
        create_baseline(combined_root, combined_metrics)
        profile_mismatch = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "profile-mismatch.json",
                changed,
                baseline=combined_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(profile_mismatch, "has no swift quality metrics")

        dual_root = root / "dual-profile-baseline"
        create_baseline(
            dual_root,
            combined_metrics,
            swift_metrics=baseline_metrics,
        )
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "dual-profile-current.json",
                changed,
                baseline=dual_root,
                authority="ci-merge",
            )
        )

        legacy_metrics = root / "legacy-metrics.json"
        legacy_document = dict(combined_document)
        legacy_document["schema"] = 1
        legacy_document.pop("coverage_profile")
        write_json(legacy_metrics, legacy_document)
        legacy_root = root / "legacy-baseline"
        create_baseline(legacy_root, legacy_metrics)
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "legacy-current.json",
                changed,
                baseline=legacy_root,
                authority="ci-merge",
                profile="combined",
            )
        )

        write_json(changed, {"app/Sources/DetachApp/Synthetic.swift": list(range(1, 11))})
        current = root / "current.json"
        current_opportunities = root / "current-opportunities.json"
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                current,
                changed,
                baseline=baseline_root,
                authority="ci-merge",
                opportunities=current_opportunities,
            )
        )
        document = json.loads(current.read_text(encoding="utf-8"))
        assert document["comparison"]["status"] == "passed"
        assert document["suites"]["ui"]["line_coverage"]["percent"] == 90.0
        assert document["changed_lines"]["status"] == "passed"
        assert document["changed_lines"]["line_coverage"]["percent"] == 90.0
        invoke(["validate-opportunities", str(current_opportunities)])
        opportunity_document = json.loads(
            current_opportunities.read_text(encoding="utf-8")
        )
        assert opportunity_document["observed"]["percent"] == 90.0
        assert opportunity_document["next_milestone_percent"] == 95
        assert opportunity_document["lines_to_milestone"] == 1
        assert opportunity_document["opportunities"][0]["path"] == (
            "app/Sources/DetachApp/Synthetic.swift"
        )
        assert opportunity_document["opportunities"][0]["uncovered"] == 1

        malformed_opportunities = json.loads(
            current_opportunities.read_text(encoding="utf-8")
        )
        malformed_opportunities["opportunities"][0]["uncovered"] = 2
        malformed_opportunities_path = root / "malformed-opportunities.json"
        write_json(malformed_opportunities_path, malformed_opportunities)
        malformed_opportunities_result = invoke(
            ["validate-opportunities", str(malformed_opportunities_path)],
            expected=2,
        )
        require_text(
            malformed_opportunities_result,
            "uncovered count is inconsistent",
        )

        extra_coverage_input = invoke(
            [
                *evaluate_arguments(
                    coverage,
                    tests,
                    root / "extra-coverage-input.json",
                    changed,
                ),
                "--additional-object",
                str(coverage),
                "--additional-profile-directory",
                str(root),
            ],
            expected=2,
        )
        require_text(
            extra_coverage_input,
            "additional coverage inputs require a test binary",
        )

        promoted_metrics = root / "promoted-metrics.json"
        promoted_document = json.loads(baseline_metrics.read_text(encoding="utf-8"))
        promoted_document["source_commit"] = TESTED_COMMIT
        write_json(promoted_metrics, promoted_document)
        promoted_root = root / "promoted-baseline"
        promoted_run = create_baseline(
            promoted_root,
            promoted_metrics,
            authority="ci-merge",
            source_commit=TESTED_COMMIT,
            promotion_main=BASE_COMMIT,
        )
        promoted_current = root / "promoted-current.json"
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                promoted_current,
                changed,
                baseline=promoted_root,
                authority="ci-merge",
            )
        )
        promoted_result = json.loads(promoted_current.read_text(encoding="utf-8"))
        assert promoted_result["comparison"]["baseline_source_commit"] == BASE_COMMIT
        shard_current = root / "shard-current.json"
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                shard_current,
                changed,
                baseline=promoted_root,
                authority="ci-shard",
            )
        )
        shard_result = json.loads(shard_current.read_text(encoding="utf-8"))
        assert shard_result["comparison"]["status"] == "passed"

        missing_promotion_root = root / "missing-promotion"
        create_baseline(
            missing_promotion_root,
            promoted_metrics,
            authority="ci-merge",
            source_commit=TESTED_COMMIT,
        )
        missing_promotion = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "missing-promotion.json",
                changed,
                baseline=missing_promotion_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(missing_promotion, "no direct or promoted ci-main authority")

        promotion_path = promoted_run / "promotion.tsv"
        promotion_text = promotion_path.read_text(encoding="utf-8")
        promotion_path.write_text(
            promotion_text.replace(f"tested_tree\t{'e' * 40}", f"tested_tree\t{'0' * 40}"),
            encoding="utf-8",
        )
        tampered_promotion = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "tampered-promotion.json",
                changed,
                baseline=promoted_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(tampered_promotion, "does not bind the tested manifest")
        promotion_path.write_text(promotion_text, encoding="utf-8")

        write_json(
            changed,
            {"app/Sources/DetachApp/UIE2ETestDriver.swift": list(range(1, 11))},
        )
        excluded = root / "excluded.json"
        invoke(
            evaluate_arguments(
                coverage,
                tests,
                excluded,
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            )
        )
        excluded_document = json.loads(excluded.read_text(encoding="utf-8"))
        assert excluded_document["changed_lines"]["status"] == "not-applicable"
        assert excluded_document["changed_lines"]["files"] == []

        region_path = "app/Sources/DetachApp/SidebarView.swift"
        region_lines = POLICY.coverage_region_lines(region_path)
        source_lines = (ROOT / region_path).read_text(encoding="utf-8").splitlines()
        region_line = min(
            line
            for line in region_lines
            if "quality-coverage:" not in source_lines[line - 1]
        )
        region_coverage = collect_coverage(coverage_document())
        region_coverage[region_path] = {
            "covered": 0,
            "total": 1,
            "lines": {region_line: False},
        }
        region_metrics, _ = build_metrics(
            region_coverage,
            set(test_lines()),
            POLICY,
            SOURCE_COMMIT,
            BASE_COMMIT,
            None,
            "none",
            changed_override={region_path: {region_line}},
            allow_incomplete_sources=True,
        )
        assert region_metrics["changed_lines"]["status"] == "not-applicable"
        assert region_metrics["changed_lines"]["files"] == []

        write_json(changed, {"app/Sources/DetachApp/Synthetic.swift": list(range(1, 11))})

        missing = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "missing.json",
                changed,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(missing, "require last green main evidence")

        test_only = invoke(
            evaluate_arguments(coverage, tests, root / "test-only.json", changed),
            expected=2,
            test_mode=False,
        )
        require_text(test_only, "test changed-line evidence is test-only")

        metrics_path = run_dir / "quality-metrics.json"
        original_metrics = metrics_path.read_bytes()
        metrics_path.write_bytes(original_metrics + b" ")
        tampered = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "tampered.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(tampered, "digest does not match")
        metrics_path.write_bytes(original_metrics)

        exact_tests = root / "exact-tests.txt"
        exact_tests.write_text(
            "\n".join(
                test for test in test_lines()
                if test != "DetachKitTests.SessionHealthTests/testSecondEvidence"
            ) + "\n",
            encoding="utf-8",
        )
        exact_removed = invoke(
            evaluate_arguments(
                coverage,
                exact_tests,
                root / "exact-removed.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
        )
        require_text(exact_removed, "advisory: business test was removed")

        wrong_policy = json.loads(original_metrics)
        wrong_policy["policy"] = 13
        write_json(metrics_path, wrong_policy)
        artifacts = run_dir / "artifacts.tsv"
        artifacts.write_text(
            "schema\t1\n"
            f"file\tquality-metrics.json\t{digest(metrics_path)}\n",
            encoding="utf-8",
        )
        manifest = run_dir / "manifest.tsv"
        manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
        manifest.write_text(
            "\n".join(
                f"artifacts_sha256\t{digest(artifacts)}"
                if line.startswith("artifacts_sha256\t") else line
                for line in manifest_lines
            ) + "\n",
            encoding="utf-8",
        )
        policy_mismatch = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "policy-mismatch.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(policy_mismatch, "policy does not match")
        metrics_path.write_bytes(original_metrics)
        artifacts.write_text(
            "schema\t1\n"
            f"file\tquality-metrics.json\t{digest(metrics_path)}\n",
            encoding="utf-8",
        )
        manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
        manifest.write_text(
            "\n".join(
                f"artifacts_sha256\t{digest(artifacts)}"
                if line.startswith("artifacts_sha256\t") else line
                for line in manifest_lines
            ) + "\n",
            encoding="utf-8",
        )

        missing_suite = POLICY.required_suites[0]
        removed_tests = root / "removed-tests.txt"
        removed_tests.write_text("\n".join(test_lines(remove=missing_suite)) + "\n", encoding="utf-8")
        removed = invoke(
            evaluate_arguments(
                coverage,
                removed_tests,
                root / "removed.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(removed, "required Swift suite is missing")

        write_json(changed, {})
        regressed_coverage = root / "coverage-regressed.json"
        write_json(regressed_coverage, coverage_document(ui_covered=8))
        aggregate = invoke(
            evaluate_arguments(
                regressed_coverage,
                tests,
                root / "aggregate.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
        )
        require_text(aggregate, "advisory: ui line coverage regressed")

        critical_path = POLICY.critical[0][0]
        critical_coverage = root / "critical-regressed.json"
        write_json(
            critical_coverage,
            coverage_document(critical_override=(critical_path, 8)),
        )
        critical = invoke(
            evaluate_arguments(
                critical_coverage,
                tests,
                root / "critical.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
            expected=1,
        )
        require_text(critical, "critical line coverage regressed")

        write_json(changed, {"app/Sources/DetachApp/Synthetic.swift": [10]})
        changed_loss = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "changed-loss.json",
                changed,
                baseline=baseline_root,
                authority="ci-merge",
            ),
        )
        require_text(changed_loss, "advisory: changed-line coverage regressed")

        no_metrics_root = root / "no-metrics"
        create_baseline(no_metrics_root, baseline_metrics, include_metrics=False)
        no_metrics = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "no-metrics.json",
                changed,
                baseline=no_metrics_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(no_metrics, "has no swift quality metrics")

        old_floor_root = root / "old-floor-only"
        create_baseline(
            old_floor_root,
            baseline_metrics,
            include_metrics=False,
            manifest_policy=13,
        )
        old_floor_only = invoke(
            evaluate_arguments(
                coverage,
                tests,
                root / "old-floor-only.json",
                changed,
                baseline=old_floor_root,
                authority="ci-merge",
            ),
            expected=2,
        )
        require_text(old_floor_only, "has no swift quality metrics")

        removed_bootstrap_flag = invoke(
            [
                *evaluate_arguments(
                    coverage,
                    tests,
                    root / "removed-bootstrap-flag.json",
                    changed,
                ),
                "--allow-policy-13-bootstrap",
            ],
            expected=2,
        )
        require_text(removed_bootstrap_flag, "unrecognized arguments")

        malformed = root / "malformed.json"
        write_json(malformed, {"schema": 999})
        malformed_result = invoke(["validate", str(malformed)], expected=2)
        require_text(malformed_result, "schema is unsupported")

        extra = json.loads(current.read_text(encoding="utf-8"))
        extra["manual_floor"] = 1
        extra_path = root / "extra.json"
        write_json(extra_path, extra)
        extra_result = invoke(["validate", str(extra_path)], expected=2)
        require_text(extra_result, "schema is unsupported")

        legacy_mode = json.loads(current.read_text(encoding="utf-8"))
        legacy_mode["comparison"]["mode"] = "policy-13-bootstrap"
        legacy_path = root / "legacy-mode.json"
        write_json(legacy_path, legacy_mode)
        legacy_result = invoke(["validate", str(legacy_path)], expected=2)
        require_text(legacy_result, "comparison baseline is invalid")

    print("Quality metrics contracts passed")


if __name__ == "__main__":
    main()
