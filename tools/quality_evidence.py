#!/usr/bin/env python3
"""Fetch the hosted quality evidence that proves one exact source commit."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import NoReturn, Optional

from quality_baseline import BaselineError, document, evidence_artifact, gh, successful_runs

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/quality-evidence"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


class EvidenceError(Exception):
    """Hosted evidence is unavailable or does not prove the commit."""


def fail(message: str) -> NoReturn:
    print(f"quality-evidence: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tsv_values(path: Path) -> dict[str, Optional[str]]:
    values: dict[str, Optional[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2:
            raise EvidenceError(f"{path.name} has a malformed record")
        key, value = fields
        values[key] = None if key in values else value
    return values


def commit_tree(commit: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", f"{commit}^{{tree}}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise EvidenceError(f"cannot resolve the tree of {commit}")
    return result.stdout.strip()


def binding_error(run_dir: Path, commit: str, repository: str) -> Optional[str]:
    """Return why the run does not prove the commit, or None when it does."""
    manifest = run_dir / "manifest.tsv"
    for name in ("manifest.tsv", "summary.tsv", "environment.tsv", "artifacts.tsv"):
        path = run_dir / name
        if not path.is_file() or path.is_symlink():
            return f"{name} is missing or unsafe"
    values = tsv_values(manifest)
    if values.get("schema") != "4":
        return "manifest schema is unsupported"
    if values.get("result") != "passed":
        return "run did not pass"
    authority = values.get("authority")
    if authority not in ("ci-merge", "ci-main"):
        return "authority is not hosted"
    for name, key in (
        ("environment.tsv", "environment_sha256"),
        ("artifacts.tsv", "artifacts_sha256"),
        ("summary.tsv", "summary_sha256"),
    ):
        if sha256_file(run_dir / name) != values.get(key):
            return f"{name} digest does not match the manifest"
    tested = values.get("source_commit") or ""
    if authority == "ci-main" and tested == commit:
        return None
    promotion = run_dir / "promotion.tsv"
    if not promotion.is_file() or promotion.is_symlink():
        return "run is not bound to the commit"
    record = tsv_values(promotion)
    tree = commit_tree(commit)
    expected = {
        "schema": "1",
        "authority": "ci-main",
        "result": "passed",
        "main_commit": commit,
        "tested_commit": tested,
        "source_manifest_sha256": sha256_file(manifest),
        "main_tree": tree,
        "tested_tree": tree,
    }
    for key, value in expected.items():
        if not value or record.get(key) != value:
            return f"promotion {key} does not bind the commit"
    if repository and record.get("repository") != repository:
        return "promotion names another repository"
    return None


def fetch(
    repository: str,
    commit: str,
    output_root: Path,
    executable: str,
    *,
    test_mode: bool,
) -> Path:
    if not REPOSITORY.fullmatch(repository):
        raise EvidenceError("repository must identify owner/repository")
    if not COMMIT.fullmatch(commit):
        raise EvidenceError("commit must be a full lowercase SHA-1")
    if not test_mode and output_root.resolve() != DEFAULT_OUTPUT.resolve():
        raise EvidenceError("evidence output must use app/build/quality-evidence")
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise EvidenceError("evidence output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    run_ids = successful_runs(document(
        gh(
            executable,
            [
                "api",
                f"repos/{repository}/actions/workflows/quality-gates.yml/runs"
                f"?branch=main&status=success&event=push&head_sha={commit}&per_page=5",
            ],
        ),
        "workflow run",
    ))
    reasons: list[str] = []
    for run_id in run_ids:
        destination = output_root / str(run_id)
        if destination.exists():
            if not destination.is_dir() or destination.is_symlink():
                raise EvidenceError(f"evidence destination is unsafe: {destination}")
        else:
            artifact = evidence_artifact(document(
                gh(executable, ["api", f"repos/{repository}/actions/runs/{run_id}/artifacts"]),
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
            raise EvidenceError("downloaded evidence has no unique quality manifest")
        run_dir = manifests[0].parent
        reason = binding_error(run_dir, commit, repository)
        if reason is None:
            print(run_dir)
            return run_dir
        reasons.append(f"run {run_id}: {reason}")
    raise EvidenceError(
        f"no hosted quality evidence proves {commit}: " + "; ".join(reasons)
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    fetch_parser = subcommands.add_parser("fetch")
    fetch_parser.add_argument(
        "--repository",
        default=os.environ.get("DETACH_QUALITY_REPOSITORY", os.environ.get("GITHUB_REPOSITORY", "")),
    )
    fetch_parser.add_argument("--commit", required=True)
    fetch_parser.add_argument(
        "--output-root",
        type=Path,
        default=Path(os.environ.get("DETACH_QUALITY_EVIDENCE_OUTPUT", DEFAULT_OUTPUT)),
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    test_mode = os.environ.get("DETACH_QUALITY_EVIDENCE_TEST_MODE") == "1"
    executable = (
        os.environ.get("DETACH_QUALITY_EVIDENCE_GH", "gh") if test_mode else "gh"
    )
    fetch(
        arguments.repository,
        arguments.commit,
        arguments.output_root,
        executable,
        test_mode=test_mode,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EvidenceError, BaselineError, OSError) as error:
        fail(str(error))
