#!/usr/bin/env python3
"""Deterministic contracts for bounded exact-head pull-request merge."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
HEAD = "a" * 40
MERGE = "b" * 40
POLICY = int(next(
    line.split("\t", 1)[1]
    for line in (ROOT / "quality/policy.tsv").read_text(encoding="utf-8").splitlines()
    if line.startswith("policy\t")
))


def fake_gh(path: Path) -> None:
    path.write_text(
        f'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
mode = os.environ.get("MERGE_MODE", "success")
state = Path(os.environ["MERGE_STATE"])
state.mkdir(parents=True, exist_ok=True)
(state / "calls.log").open("a", encoding="utf-8").write(json.dumps(arguments) + "\\n")

if (
    mode == "transient-api"
    and arguments[:1] == ["api"]
    and not (state / "transient").exists()
):
    (state / "transient").write_text("yes")
    print("unexpected end of JSON input", file=sys.stderr)
    raise SystemExit(1)

rules = [
    {{"type": "deletion"}},
    {{"type": "non_fast_forward"}},
    {{"type": "pull_request", "parameters": {{
        "allowed_merge_methods": ["merge"],
        "dismiss_stale_reviews_on_push": False,
        "require_code_owner_review": False,
        "require_last_push_approval": False,
        "required_approving_review_count": 0,
        "required_review_thread_resolution": False,
    }}}},
    {{"type": "required_status_checks", "parameters": {{
        "do_not_enforce_on_create": False,
        "strict_required_status_checks_policy": True,
        "required_status_checks": [{{
            "context": "quality-gates", "integration_id": 15368,
        }}],
    }}}},
]
if mode == "unprotected":
    rules = [rule for rule in rules if rule["type"] != "pull_request"]
if mode == "review-required":
    next(rule for rule in rules if rule["type"] == "pull_request")["parameters"]["required_approving_review_count"] = 1

if arguments[:1] == ["api"]:
    endpoint = arguments[1]
    if endpoint.endswith("/rulesets?targets=branch"):
        records = [{{"id": 77}}]
        if mode == "extra-main-ruleset":
            records.append({{"id": 78}})
        print(json.dumps(records))
    elif endpoint.endswith("/rulesets/77") or endpoint.endswith("/rulesets/78"):
        print(json.dumps({{
            "target": "branch", "enforcement": "active", "bypass_actors": [],
            "conditions": {{"ref_name": {{"include": ["~DEFAULT_BRANCH"], "exclude": []}}}},
            "rules": rules,
        }}))
    elif endpoint.endswith("/pulls/9"):
        count_path = state / "pull-count"
        count = int(count_path.read_text() if count_path.exists() else "0") + 1
        count_path.write_text(str(count))
        head = "{'c' * 40}" if mode == "stale-head" or (mode == "stale-after-gate" and count >= 3) else "{HEAD}"
        merged = (state / "merged").exists()
        print(json.dumps({{
            "number": 9,
            "state": "closed" if merged else "open",
            "draft": False,
            "merged_at": "2026-08-12T12:05:00Z" if merged else None,
            "merge_commit_sha": "{MERGE}" if merged else None,
            "head": {{"sha": head, "ref": "quality/test", "repo": {{"full_name": "owner/repository"}}}},
            "base": {{"ref": "main", "sha": "{'d' * 40}"}},
        }}))
    elif "workflows/quality-gates.yml/runs" in endpoint:
        conclusion = "failure" if mode == "failed-gate" else "success"
        print(json.dumps({{"workflow_runs": [{{
            "id": 123, "run_attempt": 1, "event": "pull_request",
            "head_sha": "{HEAD}", "status": "completed", "conclusion": conclusion,
            "html_url": "https://github.example/actions/runs/123",
            "head_branch": "quality/test",
            "head_repository": {{"full_name": "owner/repository"}},
            "path": ".github/workflows/quality-gates.yml",
            "pull_requests": [],
        }}]}}))
    elif endpoint.endswith("/actions/runs/123/jobs?filter=latest&per_page=100"):
        print(json.dumps({{"jobs": [{{"name": "quality-gates", "conclusion": "success"}}]}}))
    else:
        raise SystemExit(f"unexpected API endpoint: {{endpoint}}")
elif arguments[:2] == ["pr", "merge"]:
    if "--disable-auto" in arguments:
        (state / "disabled").write_text("yes")
    else:
        required = {{"9", "--repo", "owner/repository", "--auto", "--merge", "--match-head-commit", "{HEAD}"}}
        if not required <= set(arguments):
            raise SystemExit("exact-head auto-merge arguments are missing")
        if "Quality-Policy: {POLICY}\\nQuality-Repair-Attempt: 0" not in arguments:
            raise SystemExit("bounded merge evidence trailers are missing")
        if mode != "merge-timeout":
            (state / "merged").write_text("yes")
else:
    raise SystemExit(f"unexpected gh arguments: {{arguments}}")
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def invoke(
    root: Path,
    fake: Path,
    mode: str = "success",
    repair: int = 0,
    policy: Path | None = None,
    test_mode: bool = True,
    output: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    output = output or root / f"{mode}-{repair}.json"
    environment = os.environ.copy()
    environment.update(
        {
            "DETACH_QUALITY_MERGE_TEST_MODE": "1",
            "DETACH_QUALITY_MERGE_GH": str(fake),
            "DETACH_QUALITY_MERGE_POLL_SECONDS": "0.01",
            "MERGE_MODE": mode,
            "MERGE_STATE": str(root / f"state-{mode}-{repair}"),
        }
    )
    if not test_mode:
        environment.pop("DETACH_QUALITY_MERGE_TEST_MODE", None)
        environment["PATH"] = str(fake.parent) + os.pathsep + environment.get("PATH", "")
    if policy is not None:
        environment["DETACH_QUALITY_POLICY"] = str(policy)
    return subprocess.run(
        [
            str(ROOT / "scripts/quality-merge"),
            "--repository", "owner/repository",
            "--pull-request", "9",
            "--head", HEAD,
            "--repair-attempt", str(repair),
            "--output", str(output),
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=10,
    )


def require_failure(result: subprocess.CompletedProcess[str], message: str) -> None:
    assert result.returncode == 2, result.stdout
    assert message in result.stdout, result.stdout


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="detach-quality-merge.") as directory:
        root = Path(directory)
        fake = root / "gh"
        fake_gh(fake)

        forbidden = invoke(root, fake, "forbidden-output", test_mode=False)
        require_failure(forbidden, "merge evidence must use app/build/quality-merge.json")
        assert not (root / "state-forbidden-output-0/calls.log").exists(), (
            "invalid output reached GitHub before validation")

        for mode in ["directory-output", "symlink-output", "dangling-output"]:
            output = root / f"{mode}-0.json"
            if mode == "directory-output":
                output.mkdir()
            else:
                target = root / f"{mode}-target"
                if mode == "symlink-output":
                    target.write_text("preserve", encoding="utf-8")
                output.symlink_to(target)
            require_failure(invoke(root, fake, mode), "merge evidence output is unsafe")
            assert not (root / f"state-{mode}-0/calls.log").exists()

        parent_file = root / "parent-file"
        parent_file.write_text("preserve", encoding="utf-8")
        parent_result = invoke(root, fake, "parent-file", output=parent_file / "summary.json")
        assert parent_result.returncode == 2, parent_result.stdout
        assert not (root / "state-parent-file-0/calls.log").exists()

        result = invoke(root, fake)
        assert result.returncode == 0, result.stdout
        summary = json.loads((root / "success-0.json").read_text(encoding="utf-8"))
        assert summary["schema"] == 1
        assert summary["status"] == "passed"
        assert summary["source_commit"] == HEAD
        assert summary["merge_commit"] == MERGE
        assert summary["repair_attempt"] == 0
        assert summary["gate_run"] == 123
        assert summary["ruleset"] == 77

        transient = invoke(root, fake, "transient-api")
        assert transient.returncode == 0, transient.stdout
        transient_summary = json.loads(
            (root / "transient-api-0.json").read_text(encoding="utf-8")
        )
        assert transient_summary["status"] == "passed"

        require_failure(invoke(root, fake, "unprotected"), "one exact active PR-only")
        require_failure(invoke(root, fake, "review-required"), "one exact active PR-only")
        require_failure(invoke(root, fake, "extra-main-ruleset"), "one exact active PR-only")
        require_failure(invoke(root, fake, "stale-head"), "head does not match")
        require_failure(invoke(root, fake, "stale-after-gate"), "head does not match")
        require_failure(invoke(root, fake, "failed-gate"), "completed as failure")
        require_failure(invoke(root, fake, repair=3), "policy maximum of 2")

        short_policy = root / "policy.tsv"
        short_policy.write_text(
            (ROOT / "quality/policy.tsv").read_text(encoding="utf-8").replace(
                "limit\tmerge_wait_seconds\t300", "limit\tmerge_wait_seconds\t1"
            ),
            encoding="utf-8",
        )
        timed_out = invoke(root, fake, "merge-timeout", policy=short_policy)
        require_failure(timed_out, "auto-merge was disabled")
        assert (root / "state-merge-timeout-0/disabled").read_text() == "yes"

    print("Quality merge contracts passed")


if __name__ == "__main__":
    main()
