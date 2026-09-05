#!/usr/bin/env python3
"""Plan, run, and aggregate exact hosted quality shards."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import NoReturn

from quality_gate import (
    GateError,
    QualityGate,
    StageResult,
    git_bytes,
    parse_options,
    sha256_file,
    untracked_paths,
    write_private,
)


ROOT = Path(__file__).resolve().parent.parent
BINDING = "binding.tsv"
SHARD_GROUPS = (
    ("static", ("static",), 0),
    (
        "contracts-and-runtime",
        ("gate-contract", "tmux-runtime", "release-preflight"),
        2,
    ),
    ("build-and-coverage", ("swift", "quality-contracts", "app", "ui-e2e"), 2),
    ("codex", ("codex",), 2),
    ("claude-and-publish", ("claude", "publish-preflight"), 2),
    ("distribution-and-release", ("distribution", "release-workflow"), 2),
)


class ShardError(Exception):
    """A fail-closed distributed evidence error."""


def fail(message: str) -> NoReturn:
    print(f"quality-shard: {message}", file=sys.stderr)
    raise SystemExit(2)


def unique_values(path: Path) -> dict[str, str | None]:
    values: dict[str, list[str]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ShardError(f"cannot read {path.name}: {error}") from error
    for line in lines:
        fields = line.split("\t")
        if len(fields) == 2:
            values.setdefault(fields[0], []).append(fields[1])
    return {
        key: entries[0] if len(entries) == 1 else None
        for key, entries in values.items()
    }


def authoritative_plan(base: str) -> dict[str, object]:
    environment = os.environ.copy()
    environment["DETACH_QUALITY_AUTHORITY"] = "ci-merge"
    command = [
        str(ROOT / "scripts/quality-gate"),
        "--mode",
        "impact",
        "--base",
        base,
        "--plan",
        "--format",
        "json",
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ShardError(f"cannot compute authoritative plan: {detail}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ShardError("authoritative plan is not valid JSON") from error
    if not isinstance(value, dict):
        raise ShardError("authoritative plan is not an object")
    return value


def plan_stages(plan: dict[str, object]) -> list[str]:
    stages = plan.get("stages")
    if (
        not isinstance(stages, list)
        or not stages
        or not all(isinstance(stage, str) and stage for stage in stages)
        or len(stages) != len(set(stages))
    ):
        raise ShardError("authoritative plan has invalid stages")
    return stages


def shard_plan(plan: dict[str, object]) -> list[dict[str, object]]:
    selected = plan_stages(plan)
    remaining = set(selected)
    owned: set[str] = set()
    shards: list[dict[str, object]] = []
    for identifier, candidates, level in SHARD_GROUPS:
        stages = [stage for stage in selected if stage in candidates]
        if not stages:
            continue
        overlap = owned.intersection(stages)
        if overlap:
            raise ShardError(f"planned stage has more than one shard: {sorted(overlap)[0]}")
        owned.update(stages)
        remaining.difference_update(stages)
        needs_app = bool({"app", "codex", "claude", "tmux-runtime"} & set(stages))
        needs_cache = bool({"swift", "app", "ui-e2e"} & set(stages))
        needs_metrics = "quality-contracts" in stages
        shards.append(
            {
                "id": identifier,
                "stages": ",".join(stages),
                "level": level,
                "needs_app": needs_app,
                "needs_cache": needs_cache,
                "needs_metrics": needs_metrics,
                "coverage_profile": (
                    "combined" if needs_metrics and "ui-e2e" in stages
                    else "swift" if needs_metrics
                    else ""
                ),
            }
        )
    if remaining:
        raise ShardError(f"no shard owns planned stage: {sorted(remaining)[0]}")
    return shards


def shard_for(plan: dict[str, object], identifier: str) -> dict[str, object]:
    matches = [shard for shard in shard_plan(plan) if shard["id"] == identifier]
    if len(matches) != 1:
        raise ShardError(f"shard is absent from the exact plan: {identifier}")
    return matches[0]


def clean_checkout() -> bool:
    return not git_bytes(["diff", "--binary", "HEAD"]) and not untracked_paths()


def only_run_directory(root: Path) -> Path:
    candidates = [path for path in root.iterdir() if path.is_dir() and not path.is_symlink()]
    if len(candidates) != 1:
        raise ShardError("shard execution did not produce exactly one evidence directory")
    return candidates[0]


def binding_document(
    plan: dict[str, object], shard: dict[str, object], run_dir: Path
) -> str:
    required = ("policy", "source_commit", "base_commit", "input_fingerprint", "fingerprint")
    if any(not isinstance(plan.get(name), (str, int)) for name in required):
        raise ShardError("authoritative plan is missing identity fields")
    values = (
        ("schema", "1"),
        ("policy", str(plan["policy"])),
        ("source_commit", str(plan["source_commit"])),
        ("base_commit", str(plan["base_commit"])),
        ("plan_input_fingerprint", str(plan["input_fingerprint"])),
        ("plan_fingerprint", str(plan["fingerprint"])),
        ("plan_stages", ",".join(plan_stages(plan))),
        ("shard", str(shard["id"])),
        ("shard_stages", str(shard["stages"])),
        ("run", run_dir.name),
        ("manifest_sha256", sha256_file(run_dir / "manifest.tsv")),
    )
    return "".join(f"{name}\t{value}\n" for name, value in values)


def run_shard(base: str, identifier: str, result_root: Path) -> int:
    plan = authoritative_plan(base)
    shard = shard_for(plan, identifier)
    if result_root.exists():
        if not result_root.is_dir() or result_root.is_symlink() or any(result_root.iterdir()):
            raise ShardError("result root must be a new or empty non-symlink directory")
    else:
        result_root.mkdir(parents=True, mode=0o700)
    if not clean_checkout():
        raise ShardError("shard checkout changed after planning")
    environment = os.environ.copy()
    environment.update(
        {
            "DETACH_QUALITY_AUTHORITY": "ci-shard",
            "DETACH_QUALITY_GATE_RESULT_ROOT": str(result_root),
        }
    )
    command = [
        str(ROOT / "scripts/quality-gate"),
        "--mode",
        "impact",
        "--base",
        base,
        "--shard",
        str(shard["stages"]),
        "--keep-going",
    ]
    result = subprocess.run(command, cwd=ROOT, env=environment, check=False)
    run_dir = only_run_directory(result_root)
    manifest = run_dir / "manifest.tsv"
    if not manifest.is_file() or manifest.is_symlink():
        raise ShardError("shard execution produced no safe manifest")
    if not clean_checkout():
        raise ShardError("shard changed its tested checkout")
    write_private(run_dir / BINDING, binding_document(plan, shard, run_dir))
    print(run_dir)
    return result.returncode


def safe_evidence_file(run_dir: Path, relative: str) -> Path:
    if (
        not relative
        or relative.startswith("/")
        or relative.startswith("../")
        or "/../" in relative
        or "\t" in relative
        or "\n" in relative
    ):
        raise ShardError("evidence contains an unsafe path")
    if not run_dir.is_dir() or run_dir.is_symlink():
        raise ShardError("evidence run directory is missing or unsafe")
    path = run_dir
    for part in Path(relative).parts:
        path /= part
        if path.is_symlink():
            raise ShardError(f"evidence file is missing or unsafe: {relative}")
    if not path.is_file() or path.is_symlink():
        raise ShardError(f"evidence file is missing or unsafe: {relative}")
    return path


def validate_inventory(run_dir: Path, manifest: dict[str, str | None]) -> None:
    for name in ("environment.tsv", "artifacts.tsv", "summary.tsv"):
        path = safe_evidence_file(run_dir, name)
        key = name.removesuffix(".tsv") + "_sha256"
        if manifest.get(key) != sha256_file(path):
            raise ShardError(f"shard {name} digest does not match")
    artifacts = safe_evidence_file(run_dir, "artifacts.tsv")
    lines = artifacts.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "schema\t1":
        raise ShardError("shard artifact inventory has an invalid schema")
    seen: set[str] = set()
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 3 or fields[0] != "file" or fields[1] in seen:
            raise ShardError("shard artifact inventory is malformed")
        seen.add(fields[1])
        if sha256_file(safe_evidence_file(run_dir, fields[1])) != fields[2]:
            raise ShardError(f"shard artifact digest does not match: {fields[1]}")


def validate_binding(
    path: Path, plan: dict[str, object], expected: dict[str, dict[str, object]]
) -> tuple[Path, dict[str, StageResult]]:
    if not path.is_file() or path.is_symlink():
        raise ShardError("shard binding is missing or unsafe")
    run_dir = path.parent
    binding = unique_values(path)
    identifier = binding.get("shard")
    if identifier is None or identifier not in expected:
        raise ShardError("shard binding has an unknown identity")
    shard = expected[identifier]
    checks = {
        "schema": "1",
        "policy": str(plan["policy"]),
        "source_commit": str(plan["source_commit"]),
        "base_commit": str(plan["base_commit"]),
        "plan_input_fingerprint": str(plan["input_fingerprint"]),
        "plan_fingerprint": str(plan["fingerprint"]),
        "plan_stages": ",".join(plan_stages(plan)),
        "shard_stages": str(shard["stages"]),
        "run": run_dir.name,
    }
    for name, value in checks.items():
        if binding.get(name) != value:
            raise ShardError(f"shard binding does not match the exact plan: {name}")
    manifest_path = safe_evidence_file(run_dir, "manifest.tsv")
    if binding.get("manifest_sha256") != sha256_file(manifest_path):
        raise ShardError("shard manifest digest does not match its binding")
    manifest = unique_values(manifest_path)
    if any(value is None for value in manifest.values()):
        raise ShardError("shard manifest contains a duplicate value")
    # The regular plan has the full stage set. Recompute the exact shard
    # fingerprint through the same gate boundary before accepting its evidence.
    environment = os.environ.copy()
    environment["DETACH_QUALITY_AUTHORITY"] = "ci-shard"
    command = [
        str(ROOT / "scripts/quality-gate"), "--mode", "impact", "--base",
        str(plan["base_commit"]), "--shard", str(shard["stages"]), "--plan",
        "--format", "json",
    ]
    result = subprocess.run(
        command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode != 0:
        raise ShardError("cannot recompute shard identity")
    try:
        shard_identity = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ShardError("recomputed shard identity is malformed") from error
    if not isinstance(shard_identity, dict):
        raise ShardError("recomputed shard identity is not an object")
    manifest_checks = {
        "schema": "4",
        "policy": str(plan["policy"]),
        "mode": "impact",
        "authority": "ci-shard",
        "source_commit": str(plan["source_commit"]),
        "base_commit": str(plan["base_commit"]),
        "input_fingerprint": str(shard_identity.get("input_fingerprint")),
        "fingerprint": str(shard_identity.get("fingerprint")),
        "stages": str(shard["stages"]),
    }
    for name, value in manifest_checks.items():
        if manifest.get(name) != value:
            raise ShardError(f"shard manifest identity does not match: {name}")
    if manifest.get("result") not in ("passed", "failed"):
        raise ShardError("shard evidence is not complete")
    validate_inventory(run_dir, manifest)
    reader = QualityGate.__new__(QualityGate)
    reader.policy_version = int(plan["policy"])
    reader.all_stages = [stage for _, stages, _ in SHARD_GROUPS for stage in stages]
    results = reader.parse_summary(
        run_dir / "summary.tsv", str(shard["stages"]), "impact"
    )
    if list(results) != str(shard["stages"]).split(","):
        raise ShardError("shard summary does not contain its exact ordered stages")
    statuses = [result.status for result in results.values()]
    if any(status == "reused" for status in statuses):
        raise ShardError("shard summary contains reused evidence")
    if (manifest.get("result") == "passed") != all(
        status == "passed" for status in statuses
    ):
        raise ShardError("shard result does not match its stage results")
    return run_dir, results


def copy_artifacts(source: Path, destination: Path) -> None:
    lines = (source / "artifacts.tsv").read_text(encoding="utf-8").splitlines()[1:]
    for line in lines:
        _, relative, _ = line.split("\t")
        if relative.startswith("stage-scenarios/") or relative in (
            "scenarios.jsonl",
            "scenarios.junit.xml",
            "repair-bundle.json",
        ):
            continue
        source_path = safe_evidence_file(source, relative)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if sha256_file(target) != sha256_file(source_path):
                raise ShardError(f"shards produced conflicting artifact: {relative}")
            continue
        shutil.copyfile(source_path, target)
        target.chmod(0o600)


def aggregate(base: str, input_root: Path, result_root: Path) -> int:
    plan = authoritative_plan(base)
    expected_list = shard_plan(plan)
    expected = {str(shard["id"]): shard for shard in expected_list}
    if not input_root.is_dir() or input_root.is_symlink():
        raise ShardError("input root must be a non-symlink directory")
    bindings = sorted(input_root.rglob(BINDING))
    if len(bindings) != len(expected):
        raise ShardError("distributed evidence does not contain the exact shard set")
    validated: dict[str, tuple[Path, dict[str, StageResult]]] = {}
    for binding_path in bindings:
        binding = unique_values(binding_path)
        identifier = binding.get("shard")
        if identifier is None or identifier in validated:
            raise ShardError("distributed evidence contains a duplicate shard")
        validated[identifier] = validate_binding(binding_path, plan, expected)
    if set(validated) != set(expected):
        raise ShardError("distributed evidence omits a planned shard")

    raw_started = os.environ.get("DETACH_QUALITY_WORKFLOW_STARTED_AT", "")
    if not raw_started:
        raw_started = min(
            str(unique_values(run_dir / "manifest.tsv").get("started_at") or "")
            for run_dir, _ in validated.values()
        )
    try:
        started = datetime.fromisoformat(raw_started.replace("Z", "+00:00"))
    except ValueError as error:
        raise ShardError("workflow start time is invalid") from error
    if started.tzinfo is None:
        raise ShardError("workflow start time has no timezone")
    started_epoch = int(started.timestamp())
    if started_epoch <= 0 or started_epoch > int(datetime.now(timezone.utc).timestamp()):
        raise ShardError("workflow start time is outside the valid range")

    environment = os.environ.copy()
    environment["DETACH_QUALITY_AUTHORITY"] = "ci-merge"
    previous = os.environ.copy()
    os.environ.clear()
    os.environ.update(environment)
    try:
        gate = QualityGate(
            parse_options(
                [
                    "--mode", "impact", "--base", base, "--keep-going",
                ]
            )
        )
        gate.validate_options()
        gate.select_plan()
        if gate.selected != plan_stages(plan):
            raise ShardError("aggregate plan changed during validation")
        gate.result_root = result_root
        gate.run_dir = result_root / gate.run_dir.name
        gate.summary = gate.run_dir / "summary.tsv"
        gate.manifest = gate.run_dir / "manifest.tsv"
        gate.junit = gate.run_dir / "junit.xml"
        gate.markdown = gate.run_dir / "summary.md"
        gate.environment = gate.run_dir / "environment.tsv"
        gate.artifacts = gate.run_dir / "artifacts.tsv"
        gate.started_epoch = started_epoch
        gate.started_at = started.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        gate.prepare_evidence()
        gate.write_manifest("running")
        provenance = ["schema\t1"]
        for shard in expected_list:
            run_dir, _ = validated[str(shard["id"])]
            binding = unique_values(run_dir / BINDING)
            provenance.append(
                "\t".join(
                    (
                        "shard",
                        str(shard["id"]),
                        str(shard["stages"]),
                        run_dir.name,
                        str(binding["manifest_sha256"]),
                    )
                )
            )
        write_private(gate.run_dir / "shards.tsv", "\n".join(provenance) + "\n")
        for shard in expected_list:
            run_dir, results = validated[str(shard["id"])]
            copy_artifacts(run_dir, gate.run_dir)
            for stage in str(shard["stages"]).split(","):
                result = results[stage]
                if result.log != "-":
                    source_log = safe_evidence_file(run_dir, result.log)
                    target_log = gate.run_dir / result.log
                    shutil.copyfile(source_log, target_log)
                    target_log.chmod(0o600)
                scenario = safe_evidence_file(
                    run_dir, f"stage-scenarios/{stage}.jsonl"
                )
                gate.record_result(
                    stage,
                    StageResult(
                        result.status,
                        result.duration,
                        result.log,
                        result.exit_status,
                        "-",
                    ),
                    scenario_source=scenario,
                )
        gate.assemble_summary()
        gate.write_scenario_outputs()
        gate.write_junit()
        gate.write_markdown()
        failed = [stage for stage in gate.selected if gate.results[stage].status != "passed"]
        gate.write_manifest("failed" if failed else "passed")
        if failed:
            print(
                f"quality-shard: authoritative aggregate failed: {','.join(failed)}",
                file=sys.stderr,
            )
            return 1
        print(f"quality-shard: PASS evidence={gate.summary}")
        return 0
    finally:
        os.environ.clear()
        os.environ.update(previous)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="scripts/quality-shard")
    subparsers = result.add_subparsers(dest="command", required=True)
    plan = subparsers.add_parser("plan")
    plan.add_argument("--base", required=True)
    run_command = subparsers.add_parser("run")
    run_command.add_argument("--base", required=True)
    run_command.add_argument("--shard", required=True)
    run_command.add_argument("--result-root", type=Path, required=True)
    aggregate_command = subparsers.add_parser("aggregate")
    aggregate_command.add_argument("--base", required=True)
    aggregate_command.add_argument("--input-root", type=Path, required=True)
    aggregate_command.add_argument("--result-root", type=Path, required=True)
    return result


def main(arguments: list[str]) -> int:
    options = parser().parse_args(arguments)
    try:
        if options.command == "plan":
            plan = authoritative_plan(options.base)
            value = dict(plan)
            value["shards"] = shard_plan(plan)
            print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
            return 0
        if options.command == "run":
            return run_shard(options.base, options.shard, options.result_root)
        return aggregate(options.base, options.input_root, options.result_root)
    except (GateError, ShardError, OSError, UnicodeError, ValueError) as error:
        fail(str(error))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
