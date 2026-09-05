#!/usr/bin/env python3
"""Contract tests for hosted quality evidence retrieval."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/quality-evidence"

FAKE_GH = '''#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
mode = os.environ.get("FAKE_GH_MODE", "direct")
commit = os.environ["FAKE_GH_COMMIT"]
tree = os.environ["FAKE_GH_TREE"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


if arguments[0] == "api" and "workflows/quality-gates.yml/runs" in arguments[1]:
    if mode == "no-runs":
        print(json.dumps({"workflow_runs": []}))
    else:
        assert f"head_sha={commit}" in arguments[1]
        print(json.dumps({"workflow_runs": [{"id": 321}]}))
elif arguments[0] == "api" and "/artifacts" in arguments[1]:
    print(json.dumps({"artifacts": [{"expired": False, "name": "quality-gate-evidence-321-1"}]}))
elif arguments[:2] == ["run", "download"]:
    run = Path(arguments[arguments.index("--dir") + 1]) / "20260905T120000Z-1"
    run.mkdir()
    (run / "codex.log").write_text("codex passed\\n")
    (run / "environment.tsv").write_text("schema\\t1\\ngithub_actions\\ttrue\\n")
    (run / "artifacts.tsv").write_text("schema\\t1\\n")
    direct = mode in ("direct", "tampered", "failed")
    tested = commit if direct else "b" * 40
    summary = (
        "policy\\tmode\\tstage\\tstatus\\tduration_seconds\\tlog\\tlog_sha256\\torigin_run\\n"
        f"59\\timpact\\tcodex\\tpassed\\t10\\tcodex.log\\t{digest(run / 'codex.log')}\\t-\\n"
    )
    (run / "summary.tsv").write_text(summary)
    authority = "ci-main" if direct else "ci-merge"
    result = "failed" if mode == "failed" else "passed"
    manifest = "\\n".join(
        [
            "schema\\t4", "policy\\t59", "mode\\timpact", f"authority\\t{authority}",
            f"source_commit\\t{tested}", "base_commit\\t" + "c" * 40,
            "stages\\tcodex", f"result\\t{result}",
            f"environment_sha256\\t{digest(run / 'environment.tsv')}",
            f"artifacts_sha256\\t{digest(run / 'artifacts.tsv')}",
            f"summary_sha256\\t{digest(run / 'summary.tsv')}",
        ]
    ) + "\\n"
    (run / "manifest.tsv").write_text(manifest)
    if mode in ("promoted", "wrong-tree", "wrong-repository"):
        main_tree = "d" * 40 if mode == "wrong-tree" else tree
        repository = "other/repository" if mode == "wrong-repository" else "owner/repository"
        (run / "promotion.tsv").write_text(
            "\\n".join(
                [
                    "schema\\t1", "authority\\tci-main", "result\\tpassed",
                    f"repository\\t{repository}", f"main_commit\\t{commit}",
                    f"main_tree\\t{main_tree}", f"tested_commit\\t{tested}",
                    f"tested_tree\\t{main_tree}",
                    f"source_manifest_sha256\\t{digest(run / 'manifest.tsv')}",
                ]
            ) + "\\n"
        )
    if mode == "tampered":
        with (run / "summary.tsv").open("a") as handle:
            handle.write("59\\timpact\\tclaude\\tpassed\\t1\\tcodex.log\\t-\\t-\\n")
else:
    raise SystemExit(3)
'''


def git(*arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        stdout=subprocess.PIPE, text=True, check=True,
    ).stdout.strip()


def invoke(
    fake_gh: Path, output_root: Path, commit: str, tree: str, *, mode: str, expected: int = 0
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "DETACH_QUALITY_EVIDENCE_GH": str(fake_gh),
            "DETACH_QUALITY_EVIDENCE_TEST_MODE": "1",
            "FAKE_GH_MODE": mode,
            "FAKE_GH_COMMIT": commit,
            "FAKE_GH_TREE": tree,
        }
    )
    result = subprocess.run(
        [
            str(SCRIPT), "fetch", "--repository", "owner/repository",
            "--commit", commit, "--output-root", str(output_root),
        ],
        cwd=ROOT, env=environment, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"unexpected exit {result.returncode}, expected {expected}\n{result.stdout}")
    return result


def require(result: subprocess.CompletedProcess[str], value: str) -> None:
    if value not in result.stdout:
        raise AssertionError(f"missing diagnostic {value!r}:\n{result.stdout}")


def main() -> int:
    commit = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    with tempfile.TemporaryDirectory(prefix="detach-quality-evidence-") as raw:
        root = Path(raw)
        fake_gh = root / "fake-gh"
        fake_gh.write_text(FAKE_GH, encoding="utf-8")
        fake_gh.chmod(0o755)

        direct = invoke(fake_gh, root / "direct", commit, tree, mode="direct")
        run_dir = Path(direct.stdout.strip())
        if run_dir != root / "direct/321/20260905T120000Z-1" or not (run_dir / "manifest.tsv").is_file():
            raise AssertionError("direct ci-main evidence was not fetched deterministically")
        cached = invoke(fake_gh, root / "direct", commit, tree, mode="direct")
        if Path(cached.stdout.strip()) != run_dir:
            raise AssertionError("cached evidence changed the selected run")

        promoted = invoke(fake_gh, root / "promoted", commit, tree, mode="promoted")
        if not Path(promoted.stdout.strip()).joinpath("promotion.tsv").is_file():
            raise AssertionError("promoted evidence was not fetched")

        wrong_tree = invoke(
            fake_gh, root / "wrong-tree", commit, tree, mode="wrong-tree", expected=2)
        require(wrong_tree, "promotion main_tree does not bind the commit")
        wrong_repository = invoke(
            fake_gh, root / "wrong-repository", commit, tree,
            mode="wrong-repository", expected=2)
        require(wrong_repository, "promotion names another repository")
        unbound = invoke(fake_gh, root / "unbound", commit, tree, mode="unbound", expected=2)
        require(unbound, "run is not bound to the commit")
        failed = invoke(fake_gh, root / "failed", commit, tree, mode="failed", expected=2)
        require(failed, "run did not pass")
        tampered = invoke(
            fake_gh, root / "tampered", commit, tree, mode="tampered", expected=2)
        require(tampered, "summary.tsv digest does not match the manifest")
        missing = invoke(fake_gh, root / "no-runs", commit, tree, mode="no-runs", expected=2)
        require(missing, "no successful main quality run")
        bad_commit = subprocess.run(
            [str(SCRIPT), "fetch", "--repository", "owner/repository", "--commit", "HEAD",
             "--output-root", str(root / "bad")],
            cwd=ROOT, env={**os.environ, "DETACH_QUALITY_EVIDENCE_TEST_MODE": "1",
                           "DETACH_QUALITY_EVIDENCE_GH": str(fake_gh)},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        if bad_commit.returncode != 2 or "full lowercase SHA-1" not in bad_commit.stdout:
            raise AssertionError(f"symbolic commit was accepted:\n{bad_commit.stdout}")
    print("Quality evidence contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
