#!/usr/bin/env python3
"""Deterministic contracts for the automated release pull request."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
HEAD = "a" * 40
MERGE = "b" * 40


def fake_gh(path: Path) -> None:
    path.write_text(
        f'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
mode = os.environ.get("RELEASE_PR_MODE", "success")
state = Path(os.environ["RELEASE_PR_STATE"])
state.mkdir(parents=True, exist_ok=True)
(state / "calls").open("a", encoding="utf-8").write(json.dumps(args) + "\\n")

def pr():
    merged = (state / "merged").exists() or mode in ("already-merged", "already-merged-failed")
    head = "{'c' * 40}" if mode == "wrong-head" else "{HEAD}"
    return {{
        "number": 19, "state": "closed" if merged else "open", "draft": False,
        "merged_at": "2026-08-12T12:05:00Z" if merged else None,
        "merge_commit_sha": "{MERGE}" if merged else None,
        "head": {{"ref": "detach-release/v9.8.7", "sha": head,
                   "repo": {{"full_name": "owner/repository"}}}},
        "base": {{"ref": "main", "sha": "{'d' * 40}"}},
    }}

rules = [
    {{"type": "deletion"}}, {{"type": "non_fast_forward"}},
    {{"type": "pull_request", "parameters": {{
        "allowed_merge_methods": ["merge"], "dismiss_stale_reviews_on_push": False,
        "require_code_owner_review": False, "require_last_push_approval": False,
        "required_approving_review_count": 0, "required_review_thread_resolution": False,
    }}}},
    {{"type": "required_status_checks", "parameters": {{
        "do_not_enforce_on_create": False, "strict_required_status_checks_policy": True,
        "required_status_checks": [{{"context": "quality-gates", "integration_id": 15368}}],
    }}}},
]

if args[:1] == ["api"] and "--method" not in args:
    endpoint = args[1]
    if "/pulls?state=all" in endpoint:
        exists = (state / "created").exists() or mode in ("already-merged", "already-merged-failed", "wrong-head")
        print(json.dumps([pr()] if exists else []))
    elif endpoint.endswith("/rulesets?targets=branch"):
        print(json.dumps([{{"id": 77}}]))
    elif endpoint.endswith("/rulesets/77"):
        print(json.dumps({{
            "target": "branch", "enforcement": "active", "bypass_actors": [],
            "conditions": {{"ref_name": {{"include": ["refs/heads/main"], "exclude": []}}}},
            "rules": rules,
        }}))
    elif endpoint.endswith("/pulls/19"):
        print(json.dumps(pr()))
    elif "workflows/quality-gates.yml/runs" in endpoint:
        conclusion = "failure" if mode == "already-merged-failed" else "success"
        print(json.dumps({{"workflow_runs": [{{
            "id": 123, "run_attempt": 1, "event": "pull_request", "head_sha": "{HEAD}",
            "status": "completed", "conclusion": conclusion,
            "html_url": "https://github.example/actions/runs/123",
            "head_branch": "detach-release/v9.8.7",
            "head_repository": {{"full_name": "owner/repository"}},
            "path": ".github/workflows/quality-gates.yml",
            "pull_requests": [],
        }}]}}))
    elif endpoint.endswith("/actions/runs/123/jobs?filter=latest&per_page=100"):
        print(json.dumps({{"jobs": [{{"name": "quality-gates", "conclusion": "success"}}]}}))
    else:
        raise SystemExit(f"unexpected API endpoint: {{endpoint}}")
elif args[:3] == ["api", "--method", "POST"]:
    if mode == "create-failed":
        raise SystemExit("injected create failure")
    (state / "created").write_text("yes")
    print(json.dumps(pr()))
elif args[:2] == ["pr", "merge"]:
    if "--disable-auto" in args:
        (state / "disabled").write_text("yes")
    else:
        (state / "merged").write_text("yes")
else:
    raise SystemExit(f"unexpected gh arguments: {{args}}")
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def invoke(
    root: Path, fake: Path, mode: str, *, test_mode: bool = True
) -> subprocess.CompletedProcess[str]:
    output = root / f"{mode}.json"
    environment = os.environ.copy()
    environment.update(
        {
            "DETACH_RELEASE_PR_TEST_MODE": "1",
            "DETACH_RELEASE_PR_GH": str(fake),
            "DETACH_QUALITY_MERGE_TEST_MODE": "1",
            "DETACH_QUALITY_MERGE_GH": str(fake),
            "DETACH_QUALITY_MERGE_POLL_SECONDS": "0.01",
            "RELEASE_PR_MODE": mode,
            "RELEASE_PR_STATE": str(root / f"state-{mode}"),
        }
    )
    if not test_mode:
        environment.pop("DETACH_RELEASE_PR_TEST_MODE", None)
        environment.pop("DETACH_QUALITY_MERGE_TEST_MODE", None)
        environment["PATH"] = str(fake.parent) + os.pathsep + environment.get("PATH", "")
    return subprocess.run(
        [
            str(ROOT / "scripts/release-pr"),
            "--repository", "owner/repository",
            "--version", "9.8.7",
            "--branch", "detach-release/v9.8.7",
            "--head", HEAD,
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


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="detach-release-pr.") as directory:
        root = Path(directory)
        fake = root / "gh"
        fake_gh(fake)
        forbidden = invoke(root, fake, "forbidden-output", test_mode=False)
        assert forbidden.returncode == 2, forbidden.stdout
        assert "release PR evidence must use app/build/release-pr.json" in forbidden.stdout
        assert not (root / "state-forbidden-output/calls").exists()

        for mode in ["directory-output", "dangling-output"]:
            output = root / f"{mode}.json"
            if mode == "directory-output":
                output.mkdir()
            else:
                output.symlink_to(root / "absent-target")
            invalid = invoke(root, fake, mode)
            assert invalid.returncode == 2, invalid.stdout
            assert "release PR evidence output is unsafe" in invalid.stdout
            assert not (root / f"state-{mode}/calls").exists()

        success = invoke(root, fake, "success")
        assert success.returncode == 0, success.stdout
        summary = json.loads((root / "success.json").read_text(encoding="utf-8"))
        assert summary["created"] is True
        assert summary["pull_request"] == 19
        assert summary["source_commit"] == HEAD
        assert summary["merge_commit"] == MERGE
        assert summary["gate_run"] == 123

        resumed = invoke(root, fake, "already-merged")
        assert resumed.returncode == 0, resumed.stdout
        resumed_summary = json.loads(
            (root / "already-merged.json").read_text(encoding="utf-8")
        )
        assert resumed_summary["created"] is False
        assert resumed_summary["gate_run"] == 123
        assert resumed_summary["merge_commit"] == MERGE

        failed_resume = invoke(root, fake, "already-merged-failed")
        assert failed_resume.returncode == 2
        assert "no exact successful quality-gates run" in failed_resume.stdout

        wrong = invoke(root, fake, "wrong-head")
        assert wrong.returncode == 2
        assert "exact branch and head" in wrong.stdout
        failed = invoke(root, fake, "create-failed")
        assert failed.returncode == 2
        assert "gh failed" in failed.stdout

    print("Release PR contracts passed")


if __name__ == "__main__":
    main()
