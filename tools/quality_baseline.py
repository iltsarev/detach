#!/usr/bin/env python3
"""Restore the last successful main quality artifact through GitHub CLI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, NoReturn, Optional


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/quality-baseline"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
COVERAGE_PROFILES = ("swift", "combined")


class BaselineError(Exception):
    """Missing, malformed, or unsafe remote baseline evidence."""


def fail(message: str) -> NoReturn:
    print(f"quality-baseline: {message}", file=sys.stderr)
    raise SystemExit(2)


def gh(executable: str, arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            [executable, *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise BaselineError(f"cannot start gh: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise BaselineError(f"gh failed: {detail}")
    return result.stdout


def document(raw: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise BaselineError(f"{label} response is malformed: {error}") from error
    if not isinstance(value, dict):
        raise BaselineError(f"{label} response is malformed")
    return value


def successful_runs(value: dict[str, Any]) -> list[int]:
    runs = value.get("workflow_runs")
    if not isinstance(runs, list) or not runs:
        raise BaselineError("no successful main quality run is available")
    identifiers: list[int] = []
    for run in runs:
        if not isinstance(run, dict) or not isinstance(run.get("id"), int) or run["id"] <= 0:
            raise BaselineError("successful main quality run id is invalid")
        identifiers.append(run["id"])
    return identifiers


def evidence_artifact(value: dict[str, Any], run_id: int) -> str:
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list):
        raise BaselineError("quality artifact response is malformed")
    matches: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise BaselineError("quality artifact record is malformed")
        name = artifact.get("name")
        expired = artifact.get("expired")
        if not isinstance(name, str) or not isinstance(expired, bool):
            raise BaselineError("quality artifact record is malformed")
        if not expired and name.startswith("quality-gate-evidence-"):
            matches.append(name)
    if len(matches) != 1:
        raise BaselineError(f"main quality run {run_id} has no unique evidence artifact")
    return matches[0]


def metrics_profile(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise BaselineError("quality metrics are missing or unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BaselineError(f"quality metrics are malformed: {error}") from error
    if not isinstance(value, dict):
        raise BaselineError("quality metrics are malformed")
    if value.get("schema") == 1:
        return "combined"
    profile = value.get("coverage_profile")
    if value.get("schema") != 2 or profile not in COVERAGE_PROFILES:
        raise BaselineError("quality metrics coverage profile is invalid")
    return profile


def matching_metrics(run_dir: Path, coverage_profile: str) -> Optional[Path]:
    matches = []
    for name in ("quality-metrics.json", "quality-metrics-swift.json"):
        candidate = run_dir / name
        if candidate.exists() and metrics_profile(candidate) == coverage_profile:
            matches.append(candidate)
    if len(matches) > 1:
        raise BaselineError(
            f"quality evidence contains duplicate {coverage_profile} metrics"
        )
    return matches[0] if matches else None


def restore(
    repository: str,
    output_root: Path,
    executable: str,
    coverage_profile: str,
    *,
    test_mode: bool,
) -> Path:
    if not REPOSITORY.fullmatch(repository):
        raise BaselineError("repository must identify owner/repository")
    if not test_mode and output_root.resolve() != DEFAULT_OUTPUT.resolve():
        raise BaselineError("baseline output must use app/build/quality-baseline")
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise BaselineError("baseline output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    run_ids = successful_runs(document(
        gh(
            executable,
            [
                "api",
                f"repos/{repository}/actions/workflows/quality-gates.yml/runs"
                "?branch=main&status=success&event=push&per_page=20",
            ],
        ),
        "workflow run",
    ))
    for run_id in run_ids:
        destination = output_root / str(run_id)
        if destination.exists():
            if not destination.is_dir() or destination.is_symlink():
                raise BaselineError(f"baseline destination is unsafe: {destination}")
        else:
            artifact = evidence_artifact(document(
                gh(
                    executable,
                    ["api", f"repos/{repository}/actions/runs/{run_id}/artifacts"],
                ),
                "artifact",
            ), run_id)
            destination.mkdir()
            try:
                gh(
                    executable,
                    [
                        "run", "download", str(run_id), "--repo", repository,
                        "--name", artifact, "--dir", str(destination),
                    ],
                )
            except Exception:
                shutil.rmtree(destination, ignore_errors=True)
                raise
        manifests = [
            path for path in destination.glob("*/manifest.tsv")
            if path.is_file() and not path.is_symlink()
        ]
        if len(manifests) != 1:
            raise BaselineError("downloaded evidence has no unique quality manifest")
        run_dir = manifests[0].parent
        if matching_metrics(run_dir, coverage_profile) is not None:
            print(destination)
            return destination
    raise BaselineError(
        f"no successful main quality run has {coverage_profile} quality metrics"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--repository",
        default=os.environ.get("DETACH_QUALITY_REPOSITORY", os.environ.get("GITHUB_REPOSITORY", "")),
    )
    result.add_argument(
        "--output-root",
        type=Path,
        default=Path(os.environ.get("DETACH_QUALITY_BASELINE_OUTPUT", DEFAULT_OUTPUT)),
    )
    result.add_argument(
        "--profile", choices=COVERAGE_PROFILES, default="combined"
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    test_mode = os.environ.get("DETACH_QUALITY_BASELINE_TEST_MODE") == "1"
    executable = (
        os.environ.get("DETACH_QUALITY_BASELINE_GH", "gh") if test_mode else "gh"
    )
    restore(
        arguments.repository,
        arguments.output_root,
        executable,
        arguments.profile,
        test_mode=test_mode,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BaselineError, OSError) as error:
        fail(str(error))
