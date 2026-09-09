#!/usr/bin/env python3
"""Merge one exact pull-request head after the authoritative gate passes."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, NoReturn

from quality_policy import POLICY_FILE, Policy


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/quality-merge.json"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
GH_CALL_SECONDS = 20
GH_API_ATTEMPTS = 3
GH_API_RETRY_SECONDS = 1
POLL_SECONDS = 5
QUALITY_CHECK = "quality-gates"
GITHUB_ACTIONS_INTEGRATION_ID = 15368


class MergeError(Exception):
    """The pull request cannot be merged without weakening the contract."""


def fail(message: str) -> NoReturn:
    print(f"quality-merge: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise MergeError(f"{label} response is malformed: {error}") from error


class GitHub:
    def __init__(self, executable: str) -> None:
        self.executable = executable

    def command(self, arguments: list[str]) -> str:
        try:
            result = subprocess.run(
                [self.executable, *arguments],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=GH_CALL_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise MergeError(
                f"gh exceeded its {GH_CALL_SECONDS}-second call deadline"
            ) from error
        except OSError as error:
            raise MergeError(f"cannot start gh: {error}") from error
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise MergeError(f"gh failed: {detail or f'exit {result.returncode}'}")
        return result.stdout.strip()

    def api(self, path: str) -> Any:
        last_error: MergeError | None = None
        for attempt in range(1, GH_API_ATTEMPTS + 1):
            try:
                return parse_json(self.command(["api", path]), "GitHub API")
            except MergeError as error:
                last_error = error
                if attempt < GH_API_ATTEMPTS:
                    time.sleep(GH_API_RETRY_SECONDS * attempt)
        assert last_error is not None
        raise last_error

    def enable_auto_merge(
        self,
        repository: str,
        number: int,
        head: str,
        policy: int,
        repair_attempt: int,
    ) -> None:
        body = (
            f"Quality-Policy: {policy}\n"
            f"Quality-Repair-Attempt: {repair_attempt}"
        )
        self.command(
            [
                "pr", "merge", str(number), "--repo", repository,
                "--auto", "--merge", "--match-head-commit", head,
                "--body", body,
            ]
        )

    def disable_auto_merge(self, repository: str, number: int) -> None:
        self.command(
            ["pr", "merge", str(number), "--repo", repository, "--disable-auto"]
        )


def active_main_ruleset(document: Any) -> bool:
    if (
        not isinstance(document, dict)
        or document.get("target") != "branch"
        or document.get("enforcement") != "active"
        or document.get("bypass_actors") != []
    ):
        return False
    conditions = document.get("conditions")
    ref_name = conditions.get("ref_name") if isinstance(conditions, dict) else None
    if (
        not isinstance(ref_name, dict)
        or ref_name.get("exclude") != []
        or ref_name.get("include") not in (["~DEFAULT_BRANCH"], ["refs/heads/main"])
    ):
        return False
    rules = document.get("rules")
    if not isinstance(rules, list):
        return False
    by_type = {
        rule.get("type"): rule.get("parameters", {})
        for rule in rules
        if isinstance(rule, dict) and isinstance(rule.get("type"), str)
    }
    if not {"deletion", "non_fast_forward", "pull_request", "required_status_checks"} <= set(by_type):
        return False
    pull_request = by_type["pull_request"]
    if not isinstance(pull_request, dict):
        return False
    boolean_review_controls = (
        "dismiss_stale_reviews_on_push",
        "require_code_owner_review",
        "require_last_push_approval",
        "required_review_thread_resolution",
    )
    if (
        pull_request.get("allowed_merge_methods") != ["merge"]
        or pull_request.get("required_approving_review_count") != 0
        or any(pull_request.get(control) is not False for control in boolean_review_controls)
    ):
        return False
    status_checks = by_type["required_status_checks"]
    if (
        not isinstance(status_checks, dict)
        or status_checks.get("strict_required_status_checks_policy") is not True
        or status_checks.get("do_not_enforce_on_create") is not False
        or status_checks.get("required_status_checks")
        != [{"context": QUALITY_CHECK, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID}]
    ):
        return False
    return True


def selects_main(document: Any) -> bool:
    if (
        not isinstance(document, dict)
        or document.get("target") != "branch"
        or document.get("enforcement") != "active"
    ):
        return False
    conditions = document.get("conditions")
    ref_name = conditions.get("ref_name") if isinstance(conditions, dict) else None
    return (
        isinstance(ref_name, dict)
        and ref_name.get("exclude") == []
        and ref_name.get("include")
        in (["~DEFAULT_BRANCH"], ["refs/heads/main"])
    )


def verify_ruleset(github: GitHub, repository: str) -> int:
    listing = github.api(f"repos/{repository}/rulesets?targets=branch")
    if not isinstance(listing, list):
        raise MergeError("repository ruleset list is malformed")
    matches: list[tuple[int, Any]] = []
    for record in listing:
        identifier = record.get("id") if isinstance(record, dict) else None
        if type(identifier) is not int or identifier < 1:
            raise MergeError("repository ruleset identity is malformed")
        detail = github.api(f"repos/{repository}/rulesets/{identifier}")
        if selects_main(detail):
            matches.append((identifier, detail))
    if len(matches) != 1 or not active_main_ruleset(matches[0][1]):
        raise MergeError("one exact active PR-only main ruleset is required")
    return matches[0][0]


def pull_request(github: GitHub, repository: str, number: int) -> dict[str, Any]:
    value = github.api(f"repos/{repository}/pulls/{number}")
    if not isinstance(value, dict):
        raise MergeError("pull request response is malformed")
    return value


def validate_open_pull_request(
    value: dict[str, Any], repository: str, number: int, head: str
) -> str:
    head_value = value.get("head")
    actual_head = head_value.get("sha") if isinstance(head_value, dict) else None
    head_ref = head_value.get("ref") if isinstance(head_value, dict) else None
    head_repository = (
        head_value.get("repo") if isinstance(head_value, dict) else None
    )
    base = value.get("base")
    if (
        value.get("number") != number
        or value.get("state") != "open"
        or value.get("draft") is not False
        or value.get("merged_at") is not None
        or not isinstance(base, dict)
        or base.get("ref") != "main"
        or not isinstance(head_ref, str)
        or not head_ref
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != repository
    ):
        raise MergeError("pull request is not an open, ready change to main")
    if actual_head != head:
        raise MergeError("pull request head does not match the requested commit")
    return head_ref


def gate_run(
    github: GitHub, repository: str, head: str, head_ref: str
) -> dict[str, Any] | None:
    response = github.api(
        f"repos/{repository}/actions/workflows/quality-gates.yml/runs"
        f"?event=pull_request&head_sha={head}&per_page=20"
    )
    runs = response.get("workflow_runs") if isinstance(response, dict) else None
    if not isinstance(runs, list):
        raise MergeError("quality workflow response is malformed")
    candidates = [
        run for run in runs
        if isinstance(run, dict)
        and run.get("event") == "pull_request"
        and run.get("head_sha") == head
        and run.get("head_branch") == head_ref
        and run.get("path") == ".github/workflows/quality-gates.yml"
        and isinstance(run.get("head_repository"), dict)
        and run["head_repository"].get("full_name") == repository
        and type(run.get("id")) is int
        and type(run.get("run_attempt")) is int
    ]
    return max(candidates, key=lambda run: (run["id"], run["run_attempt"]), default=None)


def validate_gate_jobs(github: GitHub, repository: str, run: dict[str, Any]) -> None:
    response = github.api(
        f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100"
    )
    jobs = response.get("jobs") if isinstance(response, dict) else None
    if not isinstance(jobs, list):
        raise MergeError("quality job response is malformed")
    matches = [
        job for job in jobs
        if isinstance(job, dict) and job.get("name") == QUALITY_CHECK
    ]
    if len(matches) != 1 or matches[0].get("conclusion") != "success":
        raise MergeError("authoritative quality-gates job did not pass")


def sleep_until_next_poll(deadline: float, poll_seconds: float) -> None:
    remaining = deadline - time.monotonic()
    if remaining > 0:
        time.sleep(min(poll_seconds, remaining))


def wait_for_gate(
    github: GitHub,
    repository: str,
    number: int,
    head: str,
    timeout_seconds: int,
    poll_seconds: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        head_ref = validate_open_pull_request(
            pull_request(github, repository, number), repository, number, head
        )
        run = gate_run(github, repository, head, head_ref)
        if run is not None and run.get("status") == "completed":
            if run.get("conclusion") != "success":
                raise MergeError(
                    f"quality-gates run {run['id']} completed as {run.get('conclusion')}"
                )
            validate_gate_jobs(github, repository, run)
            if not isinstance(run.get("html_url"), str):
                raise MergeError("quality workflow URL is malformed")
            return run
        if time.monotonic() >= deadline:
            raise MergeError(
                f"quality-gates did not pass within {timeout_seconds} seconds"
            )
        sleep_until_next_poll(deadline, poll_seconds)


def merged_commit(
    value: dict[str, Any], repository: str, number: int, head: str, head_ref: str
) -> str | None:
    head_value = value.get("head")
    base_value = value.get("base")
    head_repository = (
        head_value.get("repo") if isinstance(head_value, dict) else None
    )
    if (
        value.get("number") != number
        or not isinstance(head_value, dict)
        or head_value.get("sha") != head
        or head_value.get("ref") != head_ref
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != repository
        or not isinstance(base_value, dict)
        or base_value.get("ref") != "main"
    ):
        raise MergeError("pull request identity changed while merge was armed")
    if value.get("state") == "open" and value.get("merged_at") is None:
        return None
    commit = value.get("merge_commit_sha")
    if (
        value.get("state") == "closed"
        and isinstance(value.get("merged_at"), str)
        and isinstance(commit, str)
        and COMMIT.fullmatch(commit)
    ):
        return commit
    raise MergeError("pull request closed without an exact merge commit")


def wait_for_merge(
    github: GitHub,
    repository: str,
    number: int,
    head: str,
    head_ref: str,
    timeout_seconds: int,
    poll_seconds: float,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    while True:
        commit = merged_commit(
            pull_request(github, repository, number),
            repository,
            number,
            head,
            head_ref,
        )
        if commit is not None:
            return commit
        if time.monotonic() >= deadline:
            try:
                github.disable_auto_merge(repository, number)
            except MergeError as error:
                raise MergeError(
                    f"merge exceeded {timeout_seconds} seconds and auto-merge could not be disabled: {error}"
                ) from error
            raise MergeError(
                f"merge exceeded {timeout_seconds} seconds; auto-merge was disabled"
            )
        sleep_until_next_poll(deadline, poll_seconds)


def prepare_summary_path(path: Path, test_mode: bool) -> None:
    if not test_mode and path.resolve() != DEFAULT_OUTPUT.resolve():
        raise MergeError("merge evidence must use app/build/quality-merge.json")
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise MergeError("merge evidence output is unsafe")
    path.parent.mkdir(parents=True, exist_ok=True)


def write_summary(path: Path, value: dict[str, Any], test_mode: bool) -> None:
    prepare_summary_path(path, test_mode)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def execute(args: argparse.Namespace, policy: Policy) -> dict[str, Any]:
    if not REPOSITORY.fullmatch(args.repository):
        raise MergeError("repository must identify owner/repository")
    if not COMMIT.fullmatch(args.head):
        raise MergeError("head must be one lowercase 40-character commit")
    if args.pull_request < 1:
        raise MergeError("pull request number must be positive")
    max_repairs = policy.limits.get("max_repair_loops")
    gate_timeout = policy.limits.get("pr_feedback_seconds")
    merge_timeout = policy.limits.get("merge_wait_seconds")
    if not all(type(value) is int and value > 0 for value in (max_repairs, gate_timeout, merge_timeout)):
        raise MergeError("quality policy merge limits are missing")
    if args.repair_attempt < 0 or args.repair_attempt > max_repairs:
        raise MergeError(f"repair attempt exceeds the policy maximum of {max_repairs}")
    test_mode = os.environ.get("DETACH_QUALITY_MERGE_TEST_MODE") == "1"
    executable = os.environ.get("DETACH_QUALITY_MERGE_GH", "gh") if test_mode else "gh"
    poll_seconds = float(os.environ.get("DETACH_QUALITY_MERGE_POLL_SECONDS", POLL_SECONDS)) if test_mode else POLL_SECONDS
    if poll_seconds <= 0:
        raise MergeError("merge poll interval must be positive")
    github = GitHub(executable)
    started = time.monotonic()
    ruleset = verify_ruleset(github, args.repository)
    validate_open_pull_request(
        pull_request(github, args.repository, args.pull_request), args.repository,
        args.pull_request,
        args.head,
    )
    run = wait_for_gate(
        github, args.repository, args.pull_request, args.head, gate_timeout, poll_seconds
    )
    verify_ruleset(github, args.repository)
    head_ref = validate_open_pull_request(
        pull_request(github, args.repository, args.pull_request), args.repository,
        args.pull_request,
        args.head,
    )
    github.enable_auto_merge(
        args.repository,
        args.pull_request,
        args.head,
        policy.version,
        args.repair_attempt,
    )
    merge_commit = wait_for_merge(
        github, args.repository, args.pull_request, args.head, head_ref,
        merge_timeout, poll_seconds
    )
    return {
        "schema": 1,
        "policy": policy.version,
        "repository": args.repository,
        "pull_request": args.pull_request,
        "source_commit": args.head,
        "repair_attempt": args.repair_attempt,
        "ruleset": ruleset,
        "gate_run": run["id"],
        "gate_run_attempt": run["run_attempt"],
        "gate_url": run["html_url"],
        "merge_commit": merge_commit,
        "status": "passed",
        "finished_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_seconds": math.ceil(time.monotonic() - started),
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    value.add_argument("--pull-request", type=int, required=True)
    value.add_argument("--head", required=True)
    value.add_argument("--repair-attempt", type=int, default=0)
    value.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        policy = Policy(POLICY_FILE)
        prepare_summary_path(
            args.output, os.environ.get("DETACH_QUALITY_MERGE_TEST_MODE") == "1")
        summary = execute(args, policy)
        write_summary(
            args.output,
            summary,
            os.environ.get("DETACH_QUALITY_MERGE_TEST_MODE") == "1",
        )
    except (MergeError, OSError, ValueError) as error:
        fail(str(error))
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
