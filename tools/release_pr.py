#!/usr/bin/env python3
"""Create or resume one release PR and merge its exact tested head."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, NoReturn
from urllib.parse import quote

from quality_merge import (
    COMMIT,
    GitHub,
    MergeError,
    execute as merge_exact_head,
    gate_run,
    validate_gate_jobs,
    verify_ruleset,
)
from quality_policy import POLICY_FILE, Policy


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "app/build/release-pr.json"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
BRANCH = re.compile(r"^detach-release/v[0-9A-Za-z._+-]+$")
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)


class ReleasePrError(Exception):
    """The release pull request cannot satisfy the PR-only contract."""


def fail(message: str) -> NoReturn:
    print(f"release-pr: {message}", file=sys.stderr)
    raise SystemExit(2)


def pull_requests(github: GitHub, repository: str, branch: str) -> list[dict[str, Any]]:
    owner = repository.split("/", 1)[0]
    endpoint = (
        f"repos/{repository}/pulls?state=all&base=main&"
        f"head={quote(f'{owner}:{branch}', safe=':')}&per_page=10"
    )
    value = github.api(endpoint)
    if not isinstance(value, list) or any(not isinstance(record, dict) for record in value):
        raise ReleasePrError("release pull-request list is malformed")
    return value


def exact_pull_request(
    records: list[dict[str, Any]], branch: str, head: str
) -> dict[str, Any] | None:
    matches = [
        record for record in records
        if isinstance(record.get("head"), dict)
        and isinstance(record.get("base"), dict)
        and record["head"].get("ref") == branch
        and record["head"].get("sha") == head
        and record["base"].get("ref") == "main"
    ]
    if len(matches) > 1:
        raise ReleasePrError("multiple pull requests match the exact release head")
    return matches[0] if matches else None


def create_pull_request(
    github: GitHub,
    repository: str,
    branch: str,
    version: str,
) -> dict[str, Any]:
    value = github.command(
        [
            "api", "--method", "POST", f"repos/{repository}/pulls",
            "-f", f"title=Prepare {version} release",
            "-f", f"head={branch}",
            "-f", "base=main",
            "-f", "body=Automated release metadata change. Publication remains a separate owner-confirmed step.",
        ]
    )
    try:
        document = json.loads(value)
    except json.JSONDecodeError as error:
        raise ReleasePrError(f"created pull-request response is malformed: {error}") from error
    if not isinstance(document, dict):
        raise ReleasePrError("created pull-request response is malformed")
    return document


def validate_identity(
    value: dict[str, Any], repository: str, branch: str, head: str
) -> tuple[int, str | None]:
    head_value = value.get("head")
    base_value = value.get("base")
    head_repository = (
        head_value.get("repo") if isinstance(head_value, dict) else None
    )
    number = value.get("number")
    if (
        type(number) is not int
        or number < 1
        or not isinstance(head_value, dict)
        or head_value.get("ref") != branch
        or head_value.get("sha") != head
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != repository
        or not isinstance(base_value, dict)
        or base_value.get("ref") != "main"
        or value.get("draft") is not False
    ):
        raise ReleasePrError("release pull request does not match the exact branch and head")
    if value.get("state") == "open" and value.get("merged_at") is None:
        return number, None
    commit = value.get("merge_commit_sha")
    if (
        value.get("state") == "closed"
        and isinstance(value.get("merged_at"), str)
        and isinstance(commit, str)
        and COMMIT.fullmatch(commit)
    ):
        return number, commit
    raise ReleasePrError("release pull request is closed without a merge")


def validate_completed_gate(
    github: GitHub, repository: str, branch: str, head: str
) -> int:
    verify_ruleset(github, repository)
    run = gate_run(github, repository, head, branch)
    if (
        run is None
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or not isinstance(run.get("html_url"), str)
    ):
        raise ReleasePrError("merged release pull request has no exact successful quality-gates run")
    validate_gate_jobs(github, repository, run)
    return run["id"]


def prepare_summary_path(path: Path, test_mode: bool) -> None:
    if not test_mode and path.resolve() != DEFAULT_OUTPUT.resolve():
        raise ReleasePrError("release PR evidence must use app/build/release-pr.json")
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ReleasePrError("release PR evidence output is unsafe")
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
        raise ReleasePrError("repository must identify owner/repository")
    if not BRANCH.fullmatch(args.branch) or args.branch != f"detach-release/v{args.version}":
        raise ReleasePrError("branch must identify the target release version")
    if not SEMVER.fullmatch(args.version):
        raise ReleasePrError("version must be valid SemVer")
    if not COMMIT.fullmatch(args.head):
        raise ReleasePrError("head must be one lowercase 40-character commit")
    test_mode = os.environ.get("DETACH_RELEASE_PR_TEST_MODE") == "1"
    executable = os.environ.get("DETACH_RELEASE_PR_GH", "gh") if test_mode else "gh"
    github = GitHub(executable)
    started = time.monotonic()
    record = exact_pull_request(
        pull_requests(github, args.repository, args.branch), args.branch, args.head
    )
    if args.merged_only and record is None:
        raise ReleasePrError("no exact merged release pull request is available")
    created = record is None
    if record is None:
        record = create_pull_request(
            github, args.repository, args.branch, args.version
        )
    number, merge_commit = validate_identity(
        record, args.repository, args.branch, args.head
    )
    if args.merged_only and merge_commit is None:
        raise ReleasePrError("the exact release pull request is not merged")
    gate_run_id: int | None = None
    if merge_commit is None:
        merge_args = argparse.Namespace(
            repository=args.repository,
            pull_request=number,
            head=args.head,
            repair_attempt=args.repair_attempt,
        )
        result = merge_exact_head(merge_args, policy)
        merge_commit = result["merge_commit"]
        gate_run_id = result["gate_run"]
    else:
        gate_run_id = validate_completed_gate(
            github, args.repository, args.branch, args.head
        )
    return {
        "schema": 1,
        "policy": policy.version,
        "repository": args.repository,
        "version": args.version,
        "branch": args.branch,
        "pull_request": number,
        "source_commit": args.head,
        "repair_attempt": args.repair_attempt,
        "created": created,
        "gate_run": gate_run_id,
        "merge_commit": merge_commit,
        "status": "passed",
        "finished_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_seconds": math.ceil(time.monotonic() - started),
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--repository", required=True)
    value.add_argument("--version", required=True)
    value.add_argument("--branch", required=True)
    value.add_argument("--head", required=True)
    value.add_argument("--repair-attempt", type=int, default=0)
    value.add_argument("--merged-only", action="store_true")
    value.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return value


def main() -> int:
    args = parser().parse_args()
    test_mode = os.environ.get("DETACH_RELEASE_PR_TEST_MODE") == "1"
    try:
        prepare_summary_path(args.output, test_mode)
        summary = execute(args, Policy(POLICY_FILE))
        write_summary(args.output, summary, test_mode)
    except (ReleasePrError, MergeError, OSError, ValueError) as error:
        fail(str(error))
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
