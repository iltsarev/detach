#!/usr/bin/env python3
"""Evaluate versioned quality-cycle cases with stable deterministic graders."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time
from typing import Any, NoReturn

from quality_policy import POLICY_FILE, Policy, PolicyError


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = ROOT / "quality/evals.json"
DEFAULT_BASELINE = ROOT / "app/build/quality-care-baseline"
LATEST_RUN_LIMIT = 5
GH_TIMEOUT_SECONDS = 20
LATEST_DEADLINE_SECONDS = 60
CASE_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
CATEGORIES = {
    "escaped-defect",
    "historical-task",
    "policy-mutant",
    "scope-violation",
}
IMPACT_KEYS = {
    "status",
    "stages",
    "specs",
    "capabilities",
    "journeys",
    "release_gates",
    "unknown",
}


class CareError(Exception):
    """The quality-care corpus or its outcome is invalid."""


def fail(message: str) -> NoReturn:
    print(f"quality-care: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_json(path: Path, label: str) -> Any:
    if not path.is_file() or path.is_symlink():
        raise CareError(f"{label} is missing or unsafe: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError, OSError) as error:
        raise CareError(f"{label} is invalid: {error}") from error


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_source_commit() -> str:
    try:
        result = subprocess.run(
            ("git", "-C", str(ROOT), "rev-parse", "HEAD"),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise CareError(f"cannot inspect source commit: {error}") from error
    value = result.stdout.strip()
    if result.returncode or not COMMIT.fullmatch(value):
        raise CareError("cannot resolve the quality-care source commit")
    return value


def valid_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\t" in value or "\n" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and str(path) == value


def validate_impact(value: Any, case_id: str) -> None:
    if not isinstance(value, dict) or set(value) != IMPACT_KEYS:
        raise CareError(f"case {case_id} has an invalid impact expectation")
    if value["status"] not in ("known", "unknown") or not isinstance(value["unknown"], bool):
        raise CareError(f"case {case_id} has an invalid impact status")
    if value["unknown"] != (value["status"] == "unknown"):
        raise CareError(f"case {case_id} has inconsistent unknown impact")
    for key in IMPACT_KEYS - {"status", "unknown"}:
        values = value[key]
        if (
            not isinstance(values, list)
            or any(not isinstance(item, str) or not item for item in values)
            or len(values) != len(set(values))
        ):
            raise CareError(f"case {case_id} has an invalid {key} expectation")


def load_corpus(path: Path) -> list[dict[str, Any]]:
    value = read_json(path, "eval corpus")
    if not isinstance(value, dict) or set(value) != {"schema", "cases"}:
        raise CareError("eval corpus schema is invalid")
    if value["schema"] != 1 or not isinstance(value["cases"], list) or not value["cases"]:
        raise CareError("eval corpus must contain schema 1 cases")
    cases: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_categories: set[str] = set()
    for raw_case in value["cases"]:
        if not isinstance(raw_case, dict) or set(raw_case) != {
            "id", "category", "grader", "paths", "expected"
        }:
            raise CareError("eval case schema is invalid")
        case_id = raw_case["id"]
        category = raw_case["category"]
        grader = raw_case["grader"]
        paths = raw_case["paths"]
        if not isinstance(case_id, str) or not CASE_ID.fullmatch(case_id) or case_id in seen:
            raise CareError(f"eval case id is invalid or duplicate: {case_id}")
        if category not in CATEGORIES:
            raise CareError(f"case {case_id} has an invalid category")
        if grader not in ("impact", "ignored"):
            raise CareError(f"case {case_id} has an invalid grader")
        if category == "scope-violation" and grader != "ignored":
            raise CareError(f"scope case {case_id} must use the ignored grader")
        if category != "scope-violation" and grader != "impact":
            raise CareError(f"impact case {case_id} must use the impact grader")
        if (
            not isinstance(paths, list)
            or not paths
            or any(not valid_path(item) for item in paths)
            or len(paths) != len(set(paths))
        ):
            raise CareError(f"case {case_id} has invalid paths")
        if grader == "impact":
            validate_impact(raw_case["expected"], case_id)
        elif raw_case["expected"] != {"ignored": True}:
            raise CareError(f"case {case_id} must expect ignored paths")
        seen.add(case_id)
        seen_categories.add(category)
        cases.append(raw_case)
    missing = CATEGORIES - seen_categories
    if missing:
        raise CareError(f"eval corpus is missing category: {sorted(missing)[0]}")
    return cases


def impact(policy: Policy, paths: list[str]) -> dict[str, Any]:
    return policy.impact(paths).document()


def ignored(paths: list[str]) -> dict[str, bool]:
    results = []
    for path in paths:
        try:
            result = subprocess.run(
                ("git", "-C", str(ROOT), "check-ignore", "--quiet", "--no-index", "--", path),
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except OSError as error:
            raise CareError(f"cannot inspect ignored paths: {error}") from error
        if result.returncode not in (0, 1):
            raise CareError(f"cannot inspect ignored path: {path}")
        results.append(result.returncode == 0)
    return {"ignored": all(results)}


def evaluate(cases: list[dict[str, Any]], policy: Policy) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for case in cases:
        actual = (
            impact(policy, case["paths"])
            if case["grader"] == "impact"
            else ignored(case["paths"])
        )
        passed = actual == case["expected"]
        results.append(
            {
                "id": case["id"],
                "category": case["category"],
                "grader": case["grader"],
                "passed": passed,
                "expected": case["expected"],
                "actual": actual,
            }
        )
    passed_count = sum(result["passed"] for result in results)
    return {
        "schema": 1,
        "policy": policy.version,
        "status": "passed" if passed_count == len(results) else "failed",
        "passed": passed_count,
        "total": len(results),
        "categories": {
            category: sum(
                result["passed"]
                for result in results
                if result["category"] == category
            )
            for category in sorted(CATEGORIES)
        },
        "results": results,
    }


def assess(eval_path: Path, history_path: Path, policy: Policy) -> dict[str, Any]:
    eval_summary = read_json(eval_path, "eval summary")
    history = read_json(history_path, "history summary")
    if (
        not isinstance(eval_summary, dict)
        or set(eval_summary) != {
            "schema", "policy", "status", "passed", "total", "categories", "results"
        }
        or eval_summary.get("schema") != 1
        or eval_summary.get("policy") != policy.version
        or eval_summary.get("status") not in ("passed", "failed")
        or not isinstance(eval_summary.get("passed"), int)
        or not isinstance(eval_summary.get("total"), int)
        or not isinstance(eval_summary.get("categories"), dict)
        or not isinstance(eval_summary.get("results"), list)
    ):
        raise CareError("eval summary schema or policy is invalid")
    if (
        eval_summary["passed"] < 0
        or eval_summary["total"] < 1
        or eval_summary["passed"] > eval_summary["total"]
        or len(eval_summary["results"]) != eval_summary["total"]
        or set(eval_summary["categories"]) != CATEGORIES
        or any(
            not isinstance(value, int) or value < 0
            for value in eval_summary["categories"].values()
        )
    ):
        raise CareError("eval summary counts are invalid")
    if (
        not isinstance(history, dict)
        or set(history) != {
            "schema", "runs", "passed", "failed_or_interrupted",
            "invalid_evidence", "latest", "wall", "stages"
        }
        or history.get("schema") != 2
        or not isinstance(history.get("latest"), dict)
        or set(history["latest"]) != {"environment_failure", "result"}
        or type(history["latest"].get("environment_failure")) is not bool
        or history["latest"].get("result") not in ("passed", "failed", "interrupted")
        or not isinstance(history.get("wall"), dict)
        or set(history["wall"]) != {"samples", "p50_seconds", "p95_seconds"}
        or not isinstance(history["wall"].get("p95_seconds"), int)
        or not isinstance(history.get("invalid_evidence"), int)
        or not isinstance(history.get("stages"), list)
    ):
        raise CareError("history summary schema is invalid")
    for key in ("runs", "passed", "failed_or_interrupted", "invalid_evidence"):
        if not isinstance(history[key], int) or history[key] < 0:
            raise CareError("history summary counts are invalid")
    for key in ("samples", "p50_seconds", "p95_seconds"):
        if not isinstance(history["wall"][key], int) or history["wall"][key] < 0:
            raise CareError("history summary timing is invalid")
    if (
        history["passed"] + history["failed_or_interrupted"] != history["runs"]
        or history["wall"]["samples"] != history["runs"]
        or history["wall"]["p50_seconds"] > history["wall"]["p95_seconds"]
    ):
        raise CareError("history summary totals are inconsistent")
    stage_keys = {
        "stage", "samples", "failures", "environment_failures",
        "p50_seconds", "p95_seconds"
    }
    for stage in history["stages"]:
        if (
            not isinstance(stage, dict)
            or set(stage) != stage_keys
            or not isinstance(stage["stage"], str)
            or any(
                not isinstance(stage[key], int) or stage[key] < 0
                for key in stage_keys - {"stage"}
            )
        ):
            raise CareError("history stage summary is invalid")
        if (
            stage["failures"] > stage["samples"]
            or stage["environment_failures"] > stage["failures"]
            or stage["p50_seconds"] > stage["p95_seconds"]
        ):
            raise CareError("history stage totals are inconsistent")
    slo = policy.limits["pr_feedback_seconds"]
    alert = slo * 80 // 100
    p95 = history["wall"]["p95_seconds"]
    if p95 >= slo:
        latency_status = "breached"
    elif p95 >= alert:
        latency_status = "attention"
    else:
        latency_status = "healthy"
    environment_failures = sum(
        stage.get("environment_failures", 0)
        for stage in history["stages"]
        if isinstance(stage, dict)
    )
    status = "passed"
    reasons: list[str] = []
    if eval_summary["status"] != "passed":
        status = "attention"
        reasons.append("workflow eval regression")
    if latency_status != "healthy":
        status = "attention"
        reasons.append(f"pull-request wall p95 is {latency_status}")
    if history["invalid_evidence"]:
        status = "attention"
        reasons.append("invalid current-schema evidence was skipped")
    unresolved_failure = (
        history["latest"]["result"] != "passed"
        or history["latest"]["environment_failure"]
    )
    if unresolved_failure:
        status = "attention"
        reasons.append("the latest gate run failed or was interrupted")
    return {
        "schema": 3,
        "policy": policy.version,
        "source_commit": git_source_commit(),
        "status": status,
        "reasons": reasons,
        "inputs": {
            "eval_sha256": sha256_file(eval_path),
            "history_sha256": sha256_file(history_path),
        },
        "evals": {
            "passed": eval_summary.get("passed", 0),
            "total": eval_summary.get("total", 0),
            "categories": eval_summary.get("categories", {}),
        },
        "latency": {
            "status": latency_status,
            "wall_p95_seconds": p95,
            "alert_seconds": alert,
            "slo_seconds": slo,
        },
        "runs": {
            "total": history.get("runs", 0),
            "failed_or_interrupted": history.get("failed_or_interrupted", 0),
            "environment_failures": environment_failures,
            "invalid_evidence": history["invalid_evidence"],
            "unresolved_failure": unresolved_failure,
        },
    }


def valid_count(value: Any) -> bool:
    return type(value) is int and value >= 0


def validate_summary(
    value: Any, expected_policy: int, expected_slo_seconds: int
) -> dict[str, Any]:
    keys = {
        "schema", "policy", "source_commit", "status", "reasons", "inputs",
        "evals", "latency", "runs"
    }
    if not isinstance(value, dict) or set(value) != keys:
        raise CareError("care summary schema is invalid")
    if (
        value["schema"] != 3
        or value["policy"] != expected_policy
        or not isinstance(value["source_commit"], str)
        or not COMMIT.fullmatch(value["source_commit"])
        or value["status"] not in ("passed", "attention")
        or not isinstance(value["reasons"], list)
        or any(not isinstance(reason, str) or not reason for reason in value["reasons"])
    ):
        raise CareError("care summary identity is invalid")
    inputs = value["inputs"]
    if (
        not isinstance(inputs, dict)
        or set(inputs) != {"eval_sha256", "history_sha256"}
        or any(not isinstance(digest, str) or not DIGEST.fullmatch(digest) for digest in inputs.values())
    ):
        raise CareError("care summary input digests are invalid")
    evals = value["evals"]
    if (
        not isinstance(evals, dict)
        or set(evals) != {"passed", "total", "categories"}
        or not valid_count(evals["passed"])
        or not valid_count(evals["total"])
        or evals["total"] < 1
        or evals["passed"] > evals["total"]
        or not isinstance(evals["categories"], dict)
        or set(evals["categories"]) != CATEGORIES
        or any(not valid_count(count) for count in evals["categories"].values())
        or sum(evals["categories"].values()) != evals["passed"]
    ):
        raise CareError("care summary evals are invalid")
    latency = value["latency"]
    if (
        not isinstance(latency, dict)
        or set(latency) != {
            "status", "wall_p95_seconds", "alert_seconds", "slo_seconds"
        }
        or latency["status"] not in ("healthy", "attention", "breached")
        or any(
            not valid_count(latency[key])
            for key in ("wall_p95_seconds", "alert_seconds", "slo_seconds")
        )
        or latency["slo_seconds"] != expected_slo_seconds
        or latency["alert_seconds"] != expected_slo_seconds * 80 // 100
        or latency["alert_seconds"] >= latency["slo_seconds"]
    ):
        raise CareError("care summary latency is invalid")
    runs = value["runs"]
    if (
        not isinstance(runs, dict)
        or set(runs) != {
            "total", "failed_or_interrupted", "environment_failures",
            "invalid_evidence", "unresolved_failure"
        }
        or any(
            not valid_count(runs[key])
            for key in (
                "total", "failed_or_interrupted", "environment_failures",
                "invalid_evidence"
            )
        )
        or type(runs["unresolved_failure"]) is not bool
        or runs["failed_or_interrupted"] > runs["total"]
    ):
        raise CareError("care summary run counts are invalid")
    p95 = latency["wall_p95_seconds"]
    expected_latency = (
        "breached" if p95 >= latency["slo_seconds"]
        else "attention" if p95 >= latency["alert_seconds"]
        else "healthy"
    )
    if latency["status"] != expected_latency:
        raise CareError("care summary latency status is inconsistent")
    needs_attention = (
        evals["passed"] != evals["total"]
        or latency["status"] != "healthy"
        or runs["invalid_evidence"]
        or runs["unresolved_failure"]
    )
    if (
        (value["status"] == "attention") != needs_attention
        or (value["status"] == "attention") != bool(value["reasons"])
    ):
        raise CareError("care summary status is inconsistent")
    return value


def validate_input_bindings(path: Path, summary: dict[str, Any]) -> None:
    for filename, key in (
        ("evals.json", "eval_sha256"),
        ("history.json", "history_sha256"),
    ):
        candidate = path.parent / filename
        if not candidate.is_file() or candidate.is_symlink():
            raise CareError(f"care input is missing or unsafe: {filename}")
        if sha256_file(candidate) != summary["inputs"][key]:
            raise CareError(f"care input digest does not match: {filename}")


def gh_output(
    executable: str, arguments: list[str], *, deadline: float | None = None
) -> str:
    timeout = GH_TIMEOUT_SECONDS
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CareError(
                f"care restore exceeded its {LATEST_DEADLINE_SECONDS}-second deadline"
            )
        timeout = min(timeout, remaining)
    try:
        result = subprocess.run(
            [executable, *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        if deadline is not None:
            raise CareError("gh did not finish before the bounded care restore deadline") from error
        raise CareError(f"gh exceeded its {GH_TIMEOUT_SECONDS}-second deadline") from error
    except OSError as error:
        raise CareError(f"cannot start gh: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise CareError(f"gh failed: {detail}")
    return result.stdout.strip()


def latest_summary(
    repository: str,
    output_root: Path,
    optional: bool,
    policy: Policy,
    test_mode: bool,
) -> Path | None:
    if not REPOSITORY.fullmatch(repository):
        if optional and not repository:
            return None
        raise CareError("repository must identify owner/repository")
    if not test_mode and output_root.resolve() != DEFAULT_BASELINE.resolve():
        raise CareError("care baseline output must use app/build/quality-care-baseline")
    if output_root.exists() and (not output_root.is_dir() or output_root.is_symlink()):
        raise CareError("care baseline output is unsafe")
    output_root.mkdir(parents=True, exist_ok=True)
    executable = os.environ.get("DETACH_QUALITY_CARE_GH", "gh") if test_mode else "gh"
    deadline_seconds = LATEST_DEADLINE_SECONDS
    if test_mode and os.environ.get("DETACH_QUALITY_CARE_LATEST_SECONDS"):
        raw_deadline = os.environ["DETACH_QUALITY_CARE_LATEST_SECONDS"]
        if not raw_deadline.isdigit() or int(raw_deadline) < 1:
            raise CareError("test care restore deadline must be a positive integer")
        deadline_seconds = int(raw_deadline)
    deadline = time.monotonic() + deadline_seconds
    run_output = gh_output(
        executable,
        [
            "api",
            f"repos/{repository}/actions/workflows/quality-care.yml/runs"
            f"?branch=main&status=completed&per_page={LATEST_RUN_LIMIT}",
            "--jq",
            ".workflow_runs[].id",
        ],
        deadline=deadline,
    )
    run_ids = run_output.splitlines()
    if not run_ids:
        if optional:
            return None
        raise CareError("no completed main quality-care run is available")
    if len(run_ids) > LATEST_RUN_LIMIT or any(
        not re.fullmatch(r"[1-9][0-9]*", run_id) for run_id in run_ids
    ):
        raise CareError("quality-care run list is invalid")
    for run_id in run_ids:
        artifact_name = gh_output(
            executable,
            [
                "api",
                f"repos/{repository}/actions/runs/{run_id}/artifacts",
                "--jq",
                ".artifacts | map(select(.expired == false and "
                "(.name | startswith(\"quality-care-\")))) | "
                "if length == 0 then \"missing\" elif length == 1 then "
                ".[0].name else \"ambiguous\" end",
            ],
            deadline=deadline,
        )
        if artifact_name == "missing":
            continue
        if artifact_name == "ambiguous" or not artifact_name.startswith("quality-care-"):
            raise CareError(f"quality-care run {run_id} has ambiguous artifacts")
        destination = output_root / run_id
        if destination.exists():
            raise CareError(f"care baseline destination already exists: {destination}")
        destination.mkdir()
        gh_output(
            executable,
            [
                "run", "download", run_id, "--repo", repository,
                "--name", artifact_name, "--dir", str(destination),
            ],
            deadline=deadline,
        )
        candidates = [
            path for path in destination.rglob("summary.json")
            if path.is_file() and not path.is_symlink()
        ]
        if not candidates:
            evals = [
                path for path in destination.rglob("evals.json")
                if path.is_file() and not path.is_symlink()
            ]
            if len(evals) == 1:
                evaluation = read_json(evals[0], "care eval")
                version = evaluation.get("policy") if isinstance(evaluation, dict) else None
                if type(version) is int and 0 < version < policy.version:
                    continue
        if len(candidates) != 1:
            raise CareError("downloaded care evidence has no unique summary")
        document = read_json(candidates[0], "care summary")
        if isinstance(document, dict) and document.get("policy") != policy.version:
            continue
        summary = validate_summary(
            document, policy.version, policy.limits["pr_feedback_seconds"]
        )
        validate_input_bindings(candidates[0], summary)
        print(candidates[0])
        return candidates[0]
    if optional:
        return None
    raise CareError(
        f"no valid policy {policy.version} care artifact exists in the latest "
        f"{LATEST_RUN_LIMIT} completed runs"
    )


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    if path.exists() and path.is_symlink():
        raise CareError(f"output target is a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="scripts/quality-care")
    result.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    evaluate_parser = commands.add_parser("evaluate")
    evaluate_parser.add_argument("--output", type=Path)
    evaluate_parser.add_argument("--json", action="store_true")
    assess_parser = commands.add_parser("assess")
    assess_parser.add_argument("--eval-summary", type=Path, required=True)
    assess_parser.add_argument("--history-summary", type=Path, required=True)
    assess_parser.add_argument("--output", type=Path, required=True)
    assess_parser.add_argument("--json", action="store_true")
    latest_parser = commands.add_parser("latest")
    latest_parser.add_argument(
        "--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    latest_parser.add_argument("--output-root", type=Path, default=DEFAULT_BASELINE)
    latest_parser.add_argument("--optional", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    policy = Policy(POLICY_FILE)
    if arguments.command == "latest":
        latest_summary(
            arguments.repository,
            arguments.output_root,
            arguments.optional,
            policy,
            os.environ.get("DETACH_QUALITY_CARE_TEST_MODE") == "1",
        )
        return 0
    if arguments.command == "assess":
        document = assess(
            arguments.eval_summary.resolve(), arguments.history_summary.resolve(), policy
        )
        validate_summary(
            document, policy.version, policy.limits["pr_feedback_seconds"]
        )
        atomic_write(arguments.output.resolve(), document)
        if arguments.json:
            print(json.dumps(document, indent=2, sort_keys=True))
        else:
            print(
                f"quality-care: {document['status']} policy={document['policy']} "
                f"wall-p95={document['latency']['wall_p95_seconds']}s"
            )
        return 0 if document["status"] == "passed" else 1
    cases = load_corpus(arguments.corpus.resolve())
    if arguments.command == "validate":
        print(f"quality-care: valid corpus with {len(cases)} cases")
        return 0
    document = evaluate(cases, policy)
    if arguments.output:
        atomic_write(arguments.output.resolve(), document)
    if arguments.json:
        print(json.dumps(document, indent=2, sort_keys=True))
    else:
        print(
            f"quality-care: {document['status']} policy={document['policy']} "
            f"cases={document['passed']}/{document['total']}"
        )
        for result in document["results"]:
            if not result["passed"]:
                print(f"quality-care: failed case {result['id']}", file=sys.stderr)
    return 0 if document["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CareError, PolicyError) as error:
        fail(str(error))
