#!/usr/bin/env python3
"""Run Detach's bounded, deterministic mutation corpus."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from typing import Any, NoReturn, Optional

from quality_policy import Policy, PolicyError


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "quality/mutations.json"
DEFAULT_RESULTS = ROOT / "app/build/quality-mutations"
DEFAULT_BASELINE = ROOT / "app/build/quality-mutation-baseline"
IDENTIFIER = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REQUIREMENT = re.compile(r"^QC-[A-Z0-9-]+$")
SOURCE = re.compile(r"^app/Sources/[A-Za-z0-9_./-]+\.swift$")
SUITE = re.compile(r"^[A-Za-z0-9]+\.[A-Za-z0-9]+$")


class MutationError(Exception):
    """Invalid corpus, execution, or result evidence."""


@dataclass(frozen=True)
class Mutant:
    identifier: str
    requirement: str
    source: str
    before: str
    after: str
    test_suite: str
    failure_regex: str

    @property
    def command(self) -> list[str]:
        return [
            "swift",
            "test",
            "--disable-sandbox",
            "--filter",
            self.test_suite.split(".", 1)[1],
        ]


def fail(message: str) -> NoReturn:
    print(f"quality-mutation: {message}", file=sys.stderr)
    raise SystemExit(2)


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        raise MutationError(f"output target is a symlink: {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(content)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def regular_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise MutationError(f"{label} must be a regular, non-symlink file: {path}")
    return path


def read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(regular_file(path, label).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MutationError(f"cannot read {label}: {error}") from error


def load_corpus(path: Path, policy: Policy, *, test_mode: bool) -> list[Mutant]:
    document = read_json(path, "mutation corpus")
    if not isinstance(document, dict) or set(document) != {"schema", "mutants"}:
        raise MutationError("mutation corpus fields are invalid")
    if document["schema"] != 1 or not isinstance(document["mutants"], list):
        raise MutationError("mutation corpus schema is unsupported")
    if not document["mutants"]:
        raise MutationError("mutation corpus is empty")
    required_fields = {
        "id", "requirement", "source", "before", "after", "test_suite", "failure_regex"
    }
    critical = {source: requirement for source, requirement in policy.critical}
    required_suites = set(policy.required_suites)
    mutants: list[Mutant] = []
    seen: set[str] = set()
    for index, value in enumerate(document["mutants"], 1):
        if not isinstance(value, dict) or set(value) != required_fields:
            raise MutationError(f"mutant {index} fields are invalid")
        if not all(isinstance(value[field], str) for field in required_fields):
            raise MutationError(f"mutant {index} fields must be strings")
        mutant = Mutant(
            value["id"], value["requirement"], value["source"], value["before"],
            value["after"], value["test_suite"], value["failure_regex"])
        if not IDENTIFIER.fullmatch(mutant.identifier) or mutant.identifier in seen:
            raise MutationError(f"mutant {index} has an invalid or duplicate id")
        seen.add(mutant.identifier)
        if not REQUIREMENT.fullmatch(mutant.requirement):
            raise MutationError(f"mutant {mutant.identifier} has an invalid requirement")
        if not SOURCE.fullmatch(mutant.source):
            raise MutationError(f"mutant {mutant.identifier} has an invalid source")
        if not SUITE.fullmatch(mutant.test_suite):
            raise MutationError(f"mutant {mutant.identifier} has an invalid test suite")
        if not mutant.before or not mutant.after or mutant.before == mutant.after:
            raise MutationError(f"mutant {mutant.identifier} has an invalid replacement")
        if "\0" in mutant.before or "\0" in mutant.after:
            raise MutationError(f"mutant {mutant.identifier} contains a NUL byte")
        try:
            re.compile(mutant.failure_regex)
        except re.error as error:
            raise MutationError(
                f"mutant {mutant.identifier} has an invalid failure regex: {error}") from error
        if not test_mode:
            # A critical source keeps its policy requirement. A trusted
            # boundary outside the critical coverage set may carry a mutant
            # for any declared requirement without joining that ratchet.
            if mutant.source in critical:
                if critical[mutant.source] != mutant.requirement:
                    raise MutationError(
                        f"mutant {mutant.identifier} does not match the critical-source policy")
            elif mutant.requirement not in policy.requirements:
                raise MutationError(
                    f"mutant {mutant.identifier} names an unknown requirement")
            if mutant.test_suite not in required_suites:
                raise MutationError(
                    f"mutant {mutant.identifier} uses a suite outside the required inventory")
        mutants.append(mutant)
    return mutants


# A change to the corpus or the runner revalidates every mutant.
ALL_MUTANT_INPUTS = {"quality/mutations.json", "tools/quality_mutation.py"}


def suite_file(test_suite: str) -> str:
    target, suite = test_suite.split(".", 1)
    return f"app/Tests/{target}/{suite}.swift"


def changed_mutants(mutants: list[Mutant], changed: list[str]) -> list[Mutant]:
    paths = {line.strip() for line in changed if line.strip()}
    if paths & ALL_MUTANT_INPUTS:
        return mutants
    return [
        mutant for mutant in mutants
        if mutant.source in paths or suite_file(mutant.test_suite) in paths
    ]


def select(mutants: list[Mutant], identifier: str) -> Mutant:
    matches = [mutant for mutant in mutants if mutant.identifier == identifier]
    if len(matches) != 1:
        raise MutationError(f"unknown mutant: {identifier}")
    return matches[0]


def source_path(workspace: Path, mutant: Mutant) -> Path:
    root = workspace.resolve(strict=True)
    candidate = root / mutant.source
    regular_file(candidate, f"source for {mutant.identifier}")
    resolved = candidate.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise MutationError(f"mutant source escapes the workspace: {mutant.source}") from error
    return resolved


def verify_replacement(workspace: Path, mutant: Mutant) -> None:
    content = source_path(workspace, mutant).read_text(encoding="utf-8")
    count = content.count(mutant.before)
    if count != 1:
        raise MutationError(
            f"mutant {mutant.identifier} expected one source match and found {count}")


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def execute(command: list[str], cwd: Path, timeout: int) -> tuple[Optional[int], bytes, bool]:
    module_cache = cwd / ".build/module-cache"
    module_cache.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(module_cache)
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(module_cache)
    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as error:
        raise MutationError(f"cannot start mutation test: {error}") from error
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output, False
    except subprocess.TimeoutExpired:
        terminate_group(process)
        output = process.stdout.read() if process.stdout is not None else b""
        return process.returncode, output, True


def test_command(mutant: Mutant, test_mode: bool) -> list[str]:
    if not test_mode:
        return mutant.command
    raw = os.environ.get("DETACH_QUALITY_MUTATION_TEST_COMMAND")
    if raw is None:
        raise MutationError("test mode requires DETACH_QUALITY_MUTATION_TEST_COMMAND")
    try:
        command = json.loads(raw)
    except json.JSONDecodeError as error:
        raise MutationError(f"test command is invalid JSON: {error}") from error
    if not isinstance(command, list) or not command or not all(
        isinstance(item, str) and item for item in command
    ):
        raise MutationError("test command must be a non-empty string array")
    return command


def run_mutant(
    mutant: Mutant,
    workspace: Path,
    timeout: int,
    output_path: Path,
    log_path: Path,
    policy: Policy,
    test_mode: bool,
) -> bool:
    path = source_path(workspace, mutant)
    original = path.read_bytes()
    before = mutant.before.encode("utf-8")
    after = mutant.after.encode("utf-8")
    if original.count(before) != 1:
        raise MutationError(
            f"mutant {mutant.identifier} expected one source match and found "
            f"{original.count(before)}")
    mutated = original.replace(before, after, 1)
    command = test_command(mutant, test_mode)
    started = time.monotonic()
    exit_code: Optional[int] = None
    output = b""
    timed_out = False
    try:
        atomic_write(path, mutated)
        cwd = workspace if test_mode else workspace / "app"
        exit_code, output, timed_out = execute(command, cwd, timeout)
    finally:
        atomic_write(path, original)
        if path.read_bytes() != original:
            raise MutationError(f"failed to restore source for {mutant.identifier}")
    duration = max(0, round(time.monotonic() - started))
    decoded = output.decode("utf-8", errors="replace")
    marker = re.search(mutant.failure_regex, decoded) is not None
    if timed_out:
        status = "timeout"
    elif exit_code == 0:
        status = "survived"
    elif marker:
        status = "killed"
    else:
        status = "invalid-failure"
    result = {
        "schema": 1,
        "policy": policy.version,
        "mutant_id": mutant.identifier,
        "requirement": mutant.requirement,
        "source": mutant.source,
        "test_suite": mutant.test_suite,
        "status": status,
        "duration_seconds": duration,
        "timeout_seconds": timeout,
        "exit_code": exit_code,
        "output_sha256": hashlib.sha256(output).hexdigest(),
    }
    atomic_write(log_path, output)
    atomic_write(output_path, json_bytes(result))
    print(f"{mutant.identifier}: {status} ({duration}s)")
    return status == "killed"


def validate_result(value: Any, expected_policy: int) -> dict[str, Any]:
    required = {
        "schema", "policy", "mutant_id", "requirement", "source", "test_suite",
        "status", "duration_seconds", "timeout_seconds", "exit_code", "output_sha256",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise MutationError("mutation result fields are invalid")
    if value["schema"] != 1 or value["policy"] != expected_policy:
        raise MutationError("mutation result policy or schema is invalid")
    for key in ("mutant_id", "requirement", "source", "test_suite", "output_sha256"):
        if not isinstance(value[key], str) or not value[key]:
            raise MutationError(f"mutation result {key} is invalid")
    if value["status"] not in ("killed", "survived", "timeout", "invalid-failure"):
        raise MutationError("mutation result status is invalid")
    if not isinstance(value["duration_seconds"], int) or value["duration_seconds"] < 0:
        raise MutationError("mutation result duration is invalid")
    if not isinstance(value["timeout_seconds"], int) or value["timeout_seconds"] <= 0:
        raise MutationError("mutation result timeout is invalid")
    if value["exit_code"] is not None and not isinstance(value["exit_code"], int):
        raise MutationError("mutation result exit code is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", value["output_sha256"]):
        raise MutationError("mutation result output digest is invalid")
    return value


def validate_summary(value: Any, expected_policy: int) -> dict[str, Any]:
    required = {
        "schema", "policy", "score_percent", "floor_percent", "killed", "total",
        "status", "results",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise MutationError("mutation summary fields are invalid")
    if value["schema"] != 1 or value["policy"] != expected_policy:
        raise MutationError("mutation summary policy or schema is invalid")
    for key in ("score_percent", "floor_percent", "killed", "total"):
        if not isinstance(value[key], int) or isinstance(value[key], bool):
            raise MutationError(f"mutation summary {key} is invalid")
    if not 0 <= value["score_percent"] <= 100 or not 1 <= value["floor_percent"] <= 100:
        raise MutationError("mutation summary percentage is invalid")
    if value["total"] <= 0 or not 0 <= value["killed"] <= value["total"]:
        raise MutationError("mutation summary count is invalid")
    if value["score_percent"] != value["killed"] * 100 // value["total"]:
        raise MutationError("mutation summary score does not match its counts")
    expected_status = "passed" if value["score_percent"] >= value["floor_percent"] else "failed"
    if value["status"] != expected_status:
        raise MutationError("mutation summary status is inconsistent")
    if not isinstance(value["results"], list) or len(value["results"]) != value["total"]:
        raise MutationError("mutation summary result inventory is invalid")
    identifiers: set[str] = set()
    for result_value in value["results"]:
        result = validate_result(result_value, expected_policy)
        if result["mutant_id"] in identifiers:
            raise MutationError("mutation summary contains a duplicate mutant")
        identifiers.add(result["mutant_id"])
    if sum(result["status"] == "killed" for result in value["results"]) != value["killed"]:
        raise MutationError("mutation summary killed count is inconsistent")
    return value


def summarize(
    mutants: list[Mutant], results_root: Path, output: Path, policy: Policy
) -> bool:
    if not results_root.is_dir() or results_root.is_symlink():
        raise MutationError("mutation results root is missing or unsafe")
    expected = {mutant.identifier: mutant for mutant in mutants}
    found: dict[str, dict[str, Any]] = {}
    for path in sorted(results_root.glob("*.json")):
        if path.resolve() == output.resolve():
            continue
        result = validate_result(read_json(path, "mutation result"), policy.version)
        identifier = result["mutant_id"]
        if identifier in found:
            raise MutationError(f"duplicate mutation result: {identifier}")
        mutant = expected.get(identifier)
        if mutant is None:
            raise MutationError(f"unexpected mutation result: {identifier}")
        if (
            result["requirement"] != mutant.requirement
            or result["source"] != mutant.source
            or result["test_suite"] != mutant.test_suite
        ):
            raise MutationError(f"mutation result identity mismatch: {identifier}")
        found[identifier] = result
    missing = sorted(set(expected) - set(found))
    if missing:
        raise MutationError(f"mutation result is missing: {missing[0]}")
    killed = sum(result["status"] == "killed" for result in found.values())
    total = len(expected)
    score = killed * 100 // total
    floor = policy.limits["mutation_score_percent"]
    summary = {
        "schema": 1,
        "policy": policy.version,
        "score_percent": score,
        "floor_percent": floor,
        "killed": killed,
        "total": total,
        "status": "passed" if score >= floor else "failed",
        "results": [found[identifier] for identifier in sorted(found)],
    }
    validate_summary(summary, policy.version)
    atomic_write(output, json_bytes(summary))
    print(f"Mutation score: {score}% ({killed}/{total}); required {floor}%")
    return score >= floor


def gh_output(executable: str, arguments: list[str]) -> str:
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
        raise MutationError(f"cannot start gh: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise MutationError(f"gh failed: {detail}")
    return result.stdout.strip()


def latest_summary(
    repository: str,
    output_root: Path,
    optional: bool,
    policy: Policy,
    test_mode: bool,
) -> Optional[Path]:
    if not REPOSITORY.fullmatch(repository):
        raise MutationError("repository must identify owner/repository")
    if not test_mode and output_root.resolve() != DEFAULT_BASELINE.resolve():
        raise MutationError("mutation baseline output must use app/build/quality-mutation-baseline")
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise MutationError("mutation baseline output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    executable = os.environ.get("DETACH_QUALITY_MUTATION_GH", "gh") if test_mode else "gh"
    run_id = gh_output(
        executable,
        [
            "api",
            f"repos/{repository}/actions/workflows/quality-mutations.yml/runs"
            "?branch=main&status=success&per_page=1",
            "--jq",
            ".workflow_runs[0].id // empty",
        ],
    )
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        if optional and not run_id:
            return None
        raise MutationError("no successful main mutation run is available")
    artifact_name = gh_output(
        executable,
        [
            "api",
            f"repos/{repository}/actions/runs/{run_id}/artifacts",
            "--jq",
            ".artifacts | map(select(.expired == false and "
            "(.name | startswith(\"quality-mutation-summary-\")))) | "
            "if length == 1 then .[0].name else empty end",
        ],
    )
    if not artifact_name:
        raise MutationError(f"mutation run {run_id} has no unique summary artifact")
    destination = output_root / run_id
    if destination.exists():
        raise MutationError(f"mutation baseline destination already exists: {destination}")
    destination.mkdir()
    gh_output(
        executable,
        [
            "run", "download", run_id, "--repo", repository, "--name", artifact_name,
            "--dir", str(destination),
        ],
    )
    candidates = [
        path for path in destination.rglob("summary.json")
        if path.is_file() and not path.is_symlink()
    ]
    if len(candidates) != 1:
        raise MutationError("downloaded mutation evidence has no unique summary")
    document = read_json(candidates[0], "mutation summary")
    if optional and isinstance(document, dict) and document.get("policy") != policy.version:
        return None
    summary = validate_summary(document, policy.version)
    if summary["status"] != "passed":
        raise MutationError("successful mutation run contains a failed score")
    print(candidates[0])
    return candidates[0]


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument(
        "--manifest",
        type=Path,
        default=Path(os.environ.get("DETACH_QUALITY_MUTATIONS", DEFAULT_MANIFEST)),
    )
    subparsers = value.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    subparsers.add_parser("list")
    matrix = subparsers.add_parser("matrix")
    matrix.add_argument(
        "--changed-files", type=Path,
        help="select only mutants whose source or test suite file is listed")
    run = subparsers.add_parser("run")
    run.add_argument("--id", required=True)
    run.add_argument("--workspace", type=Path, default=ROOT)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--log", type=Path, required=True)
    run.add_argument("--timeout-seconds", type=int)
    aggregate = subparsers.add_parser("summarize")
    aggregate.add_argument("--results-root", type=Path, default=DEFAULT_RESULTS)
    aggregate.add_argument("--output", type=Path, required=True)
    latest = subparsers.add_parser("latest")
    latest.add_argument(
        "--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    latest.add_argument("--output-root", type=Path, default=DEFAULT_BASELINE)
    latest.add_argument("--optional", action="store_true")
    return value


def main() -> int:
    args = parser().parse_args()
    test_mode = os.environ.get("DETACH_QUALITY_MUTATION_TEST_MODE") == "1"
    try:
        policy = Policy(Path(os.environ.get("DETACH_QUALITY_POLICY", ROOT / "quality/policy.tsv")))
        if policy.version is None:
            raise MutationError("quality policy version is missing")
        for required_limit in ("mutation_score_percent", "mutation_timeout_seconds"):
            if required_limit not in policy.limits:
                raise MutationError(f"quality policy limit is missing: {required_limit}")
        mutants = load_corpus(args.manifest, policy, test_mode=test_mode)
        if args.command == "validate":
            if not test_mode:
                for mutant in mutants:
                    verify_replacement(ROOT, mutant)
            print(f"Mutation corpus is valid: {len(mutants)} mutants")
            return 0
        if args.command == "list":
            for mutant in mutants:
                print(mutant.identifier)
            return 0
        if args.command == "matrix":
            if args.changed_files is not None:
                mutants = changed_mutants(
                    mutants,
                    regular_file(args.changed_files, "changed file list")
                    .read_text(encoding="utf-8").splitlines(),
                )
            print(json.dumps({"include": [{"id": mutant.identifier} for mutant in mutants]}))
            return 0
        if args.command == "run":
            timeout = args.timeout_seconds or policy.limits["mutation_timeout_seconds"]
            if timeout <= 0 or (args.timeout_seconds is not None and not test_mode):
                raise MutationError("timeout override is available only in contract test mode")
            return 0 if run_mutant(
                select(mutants, args.id), args.workspace, timeout, args.output, args.log,
                policy, test_mode) else 1
        if args.command == "summarize":
            return 0 if summarize(mutants, args.results_root, args.output, policy) else 1
        if args.command == "latest":
            latest_summary(
                args.repository, args.output_root, args.optional, policy, test_mode)
            return 0
        raise MutationError("unknown command")
    except (MutationError, PolicyError, OSError, UnicodeError) as error:
        fail(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
