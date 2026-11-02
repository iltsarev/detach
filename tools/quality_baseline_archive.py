#!/usr/bin/env python3
"""Preserve digest-bound main metrics outside expiring Actions logs."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import lzma
import os
from pathlib import Path
import shutil
import tempfile
from urllib.error import HTTPError
from urllib.request import urlopen

from quality_metrics import artifact_digest, load_baseline, load_baseline_run
from quality_baseline import BaselineError, REPOSITORY, document, gh

ARCHIVE_NAME = "quality-baseline.json.xz"
MAX_BYTES = 16 * 1024 * 1024
FILES = {
    "manifest.tsv", "artifacts.tsv", "promotion.tsv", "quality-metrics.json",
    "quality-metrics-swift.json", "summary.tsv", "scenarios.jsonl",
    "spec-sizes.json", "coverage-opportunities.json",
}


def validate_root(root: Path) -> str:
    run, manifest, commit = load_baseline_run(root)
    if run.is_symlink() or run.resolve().parent != root.resolve():
        raise BaselineError("archive run directory is unsafe")
    found = False
    for profile, name in (("combined", "quality-metrics.json"), ("swift", "quality-metrics-swift.json")):
        if (run / name).exists():
            # A Swift-only main run stores its primary metric under the generic name.
            value = json.loads((run / name).read_text())
            actual = value.get("coverage_profile", "combined")
            load_baseline(root, actual)
            found = True
    if not found:
        raise BaselineError("archive has no measured metrics")
    for path in run.iterdir():
        if path.name not in FILES:
            continue
        if path.is_symlink() or not path.is_file():
            raise BaselineError("archive input is unsafe")
        if path.name in {"manifest.tsv", "promotion.tsv", "artifacts.tsv"}:
            continue
        expected = manifest.get("summary_sha256") if path.name == "summary.tsv" else artifact_digest(run, path.name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise BaselineError(f"archive file digest is invalid: {path.name}")
    return commit


def pack(root: Path, repository: str, run_id: int) -> bytes:
    if not REPOSITORY.fullmatch(repository) or type(run_id) is not int or run_id <= 0:
        raise BaselineError("baseline archive source identity is invalid")
    validate_root(root)
    run = next(root.glob("*/manifest.tsv")).parent
    files = {p.name: p.read_bytes().decode("utf-8") for p in sorted(run.iterdir()) if p.name in FILES}
    raw = json.dumps({"schema": 1, "repository": repository, "run_id": run_id, "files": files},
                     sort_keys=True, separators=(",", ":")).encode()
    if len(raw) > MAX_BYTES:
        raise BaselineError("baseline archive is too large")
    return lzma.compress(raw)


def unpack(payload: bytes, repository: str, output: Path, executable: str = "gh") -> Path:
    if not REPOSITORY.fullmatch(repository):
        raise BaselineError("baseline archive repository is invalid")
    if output.is_symlink() or (output.exists() and not output.is_dir()):
        raise BaselineError("baseline archive output is unsafe")
    if len(payload) > MAX_BYTES:
        raise BaselineError("baseline archive is too large")
    try:
        decoder = lzma.LZMADecompressor(memlimit=64 * 1024 * 1024)
        raw = decoder.decompress(payload, max_length=MAX_BYTES + 1)
        if len(raw) > MAX_BYTES or not decoder.eof or decoder.unused_data:
            raise BaselineError("baseline archive is truncated or too large")
        value = json.loads(raw)
    except (lzma.LZMAError, UnicodeError, json.JSONDecodeError) as error:
        raise BaselineError(f"baseline archive is malformed: {error}") from error
    if (not isinstance(value, dict) or set(value) != {"schema", "repository", "run_id", "files"}
            or value["schema"] != 1 or value["repository"] != repository
            or type(value["run_id"]) is not int or value["run_id"] <= 0
            or not isinstance(value["files"], dict) or not value["files"]
            or not set(value["files"]).issubset(FILES)
            or not all(isinstance(v, str) for v in value["files"].values())):
        raise BaselineError("baseline archive identity or file set is invalid")
    output.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".archive-", dir=output))
    try:
        run = stage / "run"
        run.mkdir()
        for name, content in value["files"].items():
            (run / name).write_text(content, encoding="utf-8")
        commit = validate_root(stage)
        promotion = run / "promotion.tsv"
        if promotion.exists():
            values = dict(line.split("\t", 1) for line in promotion.read_text().splitlines())
            if values["repository"] != repository:
                raise BaselineError("archive promotion repository is invalid")
        metadata = document(gh(executable, ["api", f"repos/{repository}/actions/runs/{value['run_id']}"]), "archive source run")
        if (metadata.get("head_branch") != "main" or metadata.get("event") != "push"
                or metadata.get("status") != "completed" or metadata.get("conclusion") != "success"
                or metadata.get("path") != ".github/workflows/quality-gates.yml"
                or metadata.get("head_sha") != commit):
            raise BaselineError("archive does not name a successful main quality run")
        destination = output / str(value["run_id"])
        if destination.exists() or destination.is_symlink():
            # Reuse identical cached evidence. Never replace another root.
            if destination.is_symlink() or not destination.is_dir():
                raise BaselineError("archive destination is unsafe")
            existing_run, _, _ = load_baseline_run(destination)
            for name, content in value["files"].items():
                existing = existing_run / name
                if existing.is_symlink() or not existing.is_file() or existing.read_bytes() != content.encode("utf-8"):
                    raise BaselineError("archive destination contains different evidence")
            validate_root(destination)
            return destination
        stage.rename(destination)
        return destination
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def public_name(profile: str) -> str:
    if profile not in {"swift", "combined"}:
        raise BaselineError("baseline archive profile is invalid")
    return f"quality-baseline-{profile}.json.xz"


def public_payload(repository: str, profile: str) -> bytes | None:
    owner, name = repository.split("/")
    url = f"https://{owner}.github.io/{name}/{public_name(profile)}"
    try:
        with urlopen(url, timeout=10) as response:
            payload = response.read(MAX_BYTES + 1)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise BaselineError(f"baseline archive request failed: {error.code}") from error
    if len(payload) > MAX_BYTES:
        raise BaselineError("baseline archive is too large")
    return payload


def restore(repository: str, output: Path, executable: str, profile: str) -> Path | None:
    payload = public_payload(repository, profile)
    if payload is not None:
        return unpack(payload, repository, output, executable)
    owner = repository.split("/")[0]

    # Bootstrap recovery is explicit: only the repository owner's manual care
    # run can supply the saved artifact. The original main run is checked above.
    runs = document(gh(executable, ["api", f"repos/{repository}/actions/workflows/quality-care.yml/runs?event=workflow_dispatch&status=success&per_page=5"]), "baseline recovery runs")
    candidates = runs.get("workflow_runs")
    if not isinstance(candidates, list):
        raise BaselineError("baseline recovery run list is malformed")
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise BaselineError("baseline recovery run is malformed")
        if candidate.get("actor", {}).get("login") != owner:
            continue
        run_id = candidate.get("id")
        if type(run_id) is not int or run_id <= 0:
            raise BaselineError("baseline recovery run id is invalid")
        artifacts = document(gh(executable, ["api", f"repos/{repository}/actions/runs/{run_id}/artifacts"]), "baseline recovery artifacts")
        matches = [a for a in artifacts.get("artifacts", []) if a.get("name") == "quality-baseline-restored" and a.get("expired") is False]
        if len(matches) > 1:
            raise BaselineError("baseline recovery artifacts are ambiguous")
        if not matches:
            continue
        with tempfile.TemporaryDirectory(prefix="restore-", dir=output) as raw:
            gh(executable, ["run", "download", str(run_id), "--repo", repository,
                            "--name", "quality-baseline-restored", "--dir", raw])
            path = Path(raw) / ARCHIVE_NAME
            if path.is_symlink() or not path.is_file():
                raise BaselineError("baseline recovery archive is missing or unsafe")
            return unpack(path.read_bytes(), repository, output, executable)
    return None


def dashboard_archives(output: Path, current_run: Path, prior: Path | None,
                       repository: str, run_id: int) -> None:
    from quality_baseline import matching_metrics
    candidates: dict[str, tuple[int, bytes]] = {}
    with tempfile.TemporaryDirectory(prefix="detach-dashboard-baseline-") as raw:
        stage = Path(raw)
        (stage / "run").mkdir()
        for name in FILES:
            source = current_run / name
            if source.exists():
                shutil.copyfile(source, stage / "run" / name)
        for root, identity in ((prior, int(prior.name) if prior else 0), (stage, run_id)):
            if root is None:
                continue
            manifests = list(root.glob("*/manifest.tsv"))
            if len(manifests) != 1:
                raise BaselineError("dashboard baseline has no unique manifest")
            payload = None
            for profile in ("swift", "combined"):
                if matching_metrics(manifests[0].parent, profile) is not None:
                    payload = payload or pack(root, repository, identity)
                    if identity >= candidates.get(profile, (0, b""))[0]:
                        candidates[profile] = (identity, payload)
        for profile in ("swift", "combined"):
            payload = public_payload(repository, profile)
            if payload is not None:
                with tempfile.TemporaryDirectory(prefix="detach-prior-baseline-") as previous:
                    restored = unpack(payload, repository, Path(previous))
                    load_baseline(restored, profile)
                    identity = int(restored.name)
                if identity > candidates.get(profile, (0, b""))[0]:
                    candidates[profile] = (identity, payload)
            if profile in candidates:
                (output / public_name(profile)).write_bytes(candidates[profile][1])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("export", "restore-input"))
    parser.add_argument("--repository", required=True)
    parser.add_argument("--input-root", type=Path)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "export":
        payload = pack(args.input_root, args.repository, args.run_id)
    else:
        try:
            payload = base64.b64decode(os.environ["DETACH_BASELINE_ARCHIVE"], validate=True)
        except (KeyError, ValueError) as error:
            raise BaselineError("restore input is not a base64 archive") from error
        with tempfile.TemporaryDirectory(prefix="detach-baseline-restore-") as raw:
            unpack(payload, args.repository, Path(raw))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    print(f"Baseline archive SHA-256: {hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"quality-baseline-archive: {error}") from error
