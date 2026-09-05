#!/usr/bin/env python3
"""Deterministic contracts for exact pull-request evidence promotion."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import POLICY_FILE, Policy  # noqa: E402
from quality_promote import (  # noqa: E402
    PromotionError, read_tsv, validate_evidence, validate_promotion,
)


POLICY = Policy(POLICY_FILE)
BASE = "a" * 40
HEAD = "b" * 40
TESTED = "c" * 40
MAIN = "d" * 40
TREE = "e" * 40
BASELINE = "f" * 40
RUN_ID = 123
ATTEMPT = 2


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def metrics_document() -> dict[str, object]:
    return {
        "schema": 1,
        "policy": POLICY.version,
        "source_commit": TESTED,
        "suites": {
            "business": {
                "line_coverage": {"covered": 9, "percent": 90.0, "total": 10},
                "test_count": 1,
                "tests": ["DetachKitTests.Sample/testOne"],
            },
            "ui": {
                "line_coverage": {"covered": 3, "percent": 30.0, "total": 10},
                "test_count": 1,
                "tests": ["DetachAppTests.Sample/testOne"],
            },
        },
        "critical_files": [],
        "changed_lines": {
            "base_commit": BASE,
            "files": [],
            "line_coverage": {"covered": 0, "percent": 100.0, "total": 0},
            "minimum_percent": 90,
            "status": "not-applicable",
        },
        "comparison": {
            "baseline_policy": max(1, (POLICY.version or 1) - 1),
            "baseline_source_commit": BASELINE,
            "mode": "green-main-artifact",
            "regressions": [],
            "status": "passed",
        },
    }


def opportunities_document() -> dict[str, object]:
    return {
        "schema": 1,
        "policy": POLICY.version,
        "source_commit": TESTED,
        "suite": "ui",
        "observed": {"covered": 3, "percent": 30.0, "total": 10},
        "next_milestone_percent": 35,
        "lines_to_milestone": 1,
        "opportunities": [
            {
                "rank": 1,
                "path": "app/Sources/DetachApp/Synthetic.swift",
                "risk": "user-journey",
                "risk_tier": 1,
                "line_coverage": {"covered": 3, "percent": 30.0, "total": 10},
                "uncovered": 7,
                "capabilities": [],
                "requirements": [],
                "journeys": [],
                "recommended_evidence": "behavioral-unit-test",
            }
        ],
    }


def spec_sizes_document() -> dict[str, object]:
    warning = POLICY.limits["routed_spec_warning_bytes"]
    limit = POLICY.limits["routed_spec_limit_bytes"]
    return {
        "input_fingerprint": "1" * 64,
        "limit_bytes": limit,
        "policy": POLICY.version,
        "schema": 1,
        "source_commit": TESTED,
        "specifications": [
            {
                "bytes": 1,
                "headroom_bytes": limit - 1,
                "id": identifier,
                "path": path,
                "status": "healthy",
            }
            for identifier, (path, _) in POLICY.specs.items()
        ],
        "status": "healthy",
        "warning_bytes": warning,
    }


def create_evidence(
    root: Path,
    paths: list[str] | None = None,
    *,
    include_spec_sizes: bool = True,
) -> Path:
    paths = paths or ["tools/quality_gate.py"]
    impact = POLICY.impact(paths)
    run_dir = root / "20260812T120000Z-1"
    run_dir.mkdir(parents=True)
    summary_lines = [
        "policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run"
    ]
    stages = list(impact.stages)
    for stage in stages:
        log = run_dir / f"{stage}.log"
        log.write_text(f"{stage} passed\n", encoding="utf-8")
        summary_lines.append(
            f"{POLICY.version}\timpact\t{stage}\tpassed\t1\t{stage}.log\t"
            f"{digest(log)}\t-"
        )
    summary = run_dir / "summary.tsv"
    summary.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    environment = run_dir / "environment.tsv"
    environment.write_text("schema\t1\narchitecture\ttest\n", encoding="utf-8")
    metric_names: tuple[str, ...] = ()
    if "quality-contracts" in stages:
        write_json(run_dir / "quality-metrics.json", metrics_document())
        write_json(run_dir / "coverage-opportunities.json", opportunities_document())
        metric_names = ("coverage-opportunities.json", "quality-metrics.json")
    (run_dir / "scenarios.jsonl").write_text("{}\n", encoding="utf-8")
    (run_dir / "scenarios.junit.xml").write_text(
        '<testsuite name="quality" tests="0"/>\n', encoding="utf-8"
    )
    if include_spec_sizes:
        write_json(run_dir / "spec-sizes.json", spec_sizes_document())
    required_names = ["scenarios.jsonl", "scenarios.junit.xml"]
    if include_spec_sizes:
        required_names.append("spec-sizes.json")
    artifacts = run_dir / "artifacts.tsv"
    artifacts.write_text(
        "schema\t1\n"
        + "".join(
            f"file\t{name}\t{digest(run_dir / name)}\n"
            for name in (*metric_names, *required_names)
        ),
        encoding="utf-8",
    )
    manifest = run_dir / "manifest.tsv"
    manifest.write_text(
        "schema\t4\n"
        f"policy\t{POLICY.version}\n"
        "mode\timpact\n"
        "authority\tci-merge\n"
        f"source_commit\t{TESTED}\n"
        f"base_commit\t{BASE}\n"
        f"input_fingerprint\t{'1' * 64}\n"
        f"fingerprint\t{'2' * 64}\n"
        f"stages\t{','.join(stages)}\n"
        f"specs\t{','.join(impact.specs)}\n"
        f"capabilities\t{','.join(impact.capabilities)}\n"
        f"journeys\t{','.join(impact.journeys)}\n"
        "started_at\t2026-08-12T12:00:00Z\n"
        "finished_at\t2026-08-12T12:03:00Z\n"
        "duration_seconds\t180\n"
        "timing_wall_seconds\t180\n"
        "resumed_from_run\t\n"
        "resumed_from_manifest_sha256\t\n"
        f"environment_sha256\t{digest(environment)}\n"
        f"artifacts_sha256\t{digest(artifacts)}\n"
        f"summary_sha256\t{digest(summary)}\n"
        "result\tpassed\n",
        encoding="utf-8",
    )
    return run_dir


def fake_tools(root: Path) -> tuple[Path, Path]:
    fake_git = root / "fake-git"
    fake_git.write_text(
        f"""#!/usr/bin/env python3
import os
import sys
mode = os.environ.get("FAKE_PROMOTE_MODE", "success")
if len(sys.argv) > 1 and sys.argv[1] == "diff":
    path = "README.md" if mode == "docs-impact" else "tools/quality_gate.py"
    sys.stdout.write("M\\0" + path + "\\0")
    raise SystemExit(0)
parents = "{BASE} {HEAD}" if mode != "one-parent" else "{BASE}"
print("{MAIN}")
print("{TREE}")
print(parents)
""",
        encoding="utf-8",
    )
    fake_git.chmod(0o755)
    fake_gh = root / "fake-gh"
    fake_gh.write_text(
        f"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

arguments = sys.argv[1:]
mode = os.environ.get("FAKE_PROMOTE_MODE", "success")
if arguments[0] == "api":
    path = arguments[1]
    if path.endswith("/commits/{MAIN}/pulls"):
        marker = Path(os.environ["FAKE_PROMOTE_EVIDENCE"]).parent / "eventual-pr-seen"
        missing = mode == "no-pr" or (mode == "eventual-pr" and not marker.exists())
        if mode == "eventual-pr": marker.write_text("yes")
        records = [] if missing else [{{
            "number": 25,
            "state": "closed",
            "merged_at": "2026-08-12T12:04:00Z",
            "merge_commit_sha": "{MAIN}",
            "base": {{"sha": "{BASE}"}},
            "head": {{"sha": "{HEAD}"}},
        }}]
        print(json.dumps(records))
    elif "workflows/quality-gates.yml/runs" in path:
        updated = "2026-08-12T12:05:00Z" if mode == "stale-run" else "2026-08-12T12:03:30Z"
        print(json.dumps({{"workflow_runs": [{{
            "id": {RUN_ID},
            "run_attempt": {ATTEMPT},
            "event": "pull_request",
            "conclusion": "success",
            "head_sha": "{HEAD}",
            "updated_at": updated,
            "html_url": "https://github.com/owner/repository/actions/runs/{RUN_ID}",
        }}]}}))
    elif path.endswith("/actions/runs/{RUN_ID}/artifacts"):
        artifacts = [{{
            "name": "quality-gate-evidence-{RUN_ID}-{ATTEMPT}",
            "expired": False,
        }}]
        if mode == "duplicate-artifact": artifacts.append(artifacts[0])
        print(json.dumps({{"artifacts": artifacts}}))
    elif path.endswith("/git/commits/{TESTED}"):
        tree = "{{}}".format("{'0' * 40}" if mode == "tree-mismatch" else "{TREE}")
        head = "{'0' * 40}" if mode == "parent-mismatch" else "{HEAD}"
        print(json.dumps({{
            "sha": "{TESTED}",
            "tree": {{"sha": tree}},
            "parents": [{{"sha": "{BASE}"}}, {{"sha": head}}],
        }}))
    else:
        raise SystemExit(3)
elif arguments[:2] == ["run", "download"]:
    destination = Path(arguments[arguments.index("--dir") + 1])
    source = Path(os.environ["FAKE_PROMOTE_EVIDENCE"])
    target = destination / source.name
    shutil.copytree(source, target)
    if mode == "symlinked-run":
        shutil.rmtree(target)
        target.symlink_to(source, target_is_directory=True)
    if mode == "tampered-artifact":
        with (target / "quality-metrics.json").open("a", encoding="utf-8") as stream:
            stream.write(" ")
else:
    raise SystemExit(3)
""",
        encoding="utf-8",
    )
    fake_gh.chmod(0o755)
    return fake_gh, fake_git


def invoke(
    fake_gh: Path,
    fake_git: Path,
    evidence: Path,
    output: Path,
    *,
    mode: str = "success",
    expected: int = 0,
    test_mode: bool = True,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "DETACH_QUALITY_PROMOTE_GH": str(fake_gh),
            "DETACH_QUALITY_PROMOTE_GIT": str(fake_git),
            "FAKE_PROMOTE_EVIDENCE": str(evidence),
            "FAKE_PROMOTE_MODE": mode,
            "DETACH_QUALITY_PROMOTE_RETRY_SECONDS": "0.01",
        }
    )
    if test_mode:
        environment["DETACH_QUALITY_PROMOTE_TEST_MODE"] = "1"
    else:
        environment.pop("DETACH_QUALITY_PROMOTE_TEST_MODE", None)
        for name in ("GITHUB_ACTIONS", "GITHUB_EVENT_NAME", "GITHUB_REF"):
            environment.pop(name, None)
    result = subprocess.run(
        [
            str(ROOT / "scripts/quality-promote"),
            "--repository", "owner/repository",
            "--commit", MAIN,
            "--output-root", str(output),
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"promotion returned {result.returncode}, expected {expected}\n{result.stdout}"
        )
    return result


def require(result: subprocess.CompletedProcess[str], text: str) -> None:
    if text not in result.stdout:
        raise AssertionError(f"missing diagnostic {text!r}:\n{result.stdout}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="detach-quality-promote-contract.") as raw:
        root = Path(raw)
        evidence = create_evidence(root / "source")
        fake_gh, fake_git = fake_tools(root)

        mixed_paths = [
            "tools/quality_gate.py", "tests/run-claude.sh", "tests/release-workflow.sh",
        ]
        mixed = create_evidence(root / "mixed-impact", mixed_paths)
        mixed_manifest_path = mixed / "manifest.tsv"
        mixed_manifest = read_tsv(mixed_manifest_path, "mixed manifest")
        expected_mixed = POLICY.impact(mixed_paths).document()
        for field in ("specs", "capabilities", "journeys"):
            members = mixed_manifest[field].split(",")
            assert len(members) > 1
            for variant, values, accepted in (
                ("reordered", list(reversed(members)), True),
                ("duplicate", members + [members[0]], False),
                ("missing", members[1:], False),
                ("extra", members + ["unknown-identity"], False),
            ):
                candidate = dict(mixed_manifest, **{field: ",".join(values)})
                mixed_manifest_path.write_text(
                    "".join(f"{key}\t{value}\n" for key, value in candidate.items()),
                    encoding="utf-8",
                )
                try:
                    validate_evidence(mixed, POLICY, BASE, expected_mixed)
                except PromotionError as error:
                    if accepted or f"quality manifest {field} is not exact" not in str(error):
                        raise AssertionError(f"unexpected {field}/{variant} failure: {error}") from error
                else:
                    if not accepted:
                        raise AssertionError(f"accepted {field}/{variant} impact")

        first = root / "first"
        result = invoke(fake_gh, fake_git, evidence, first)
        if Path(result.stdout.strip()) != first:
            raise AssertionError("promotion output root is not deterministic")
        run_dir = next(path.parent for path in first.glob("*/manifest.tsv"))
        manifest = read_tsv(run_dir / "manifest.tsv", "manifest")
        promotion = validate_promotion(run_dir, manifest)
        if promotion is None or promotion["main_commit"] != MAIN:
            raise AssertionError("promotion does not bind the main commit")

        second = root / "second"
        invoke(fake_gh, fake_git, evidence, second)
        second_run = next(path.parent for path in second.glob("*/manifest.tsv"))
        if (run_dir / "promotion.tsv").read_bytes() != (second_run / "promotion.tsv").read_bytes():
            raise AssertionError("promotion evidence is not deterministic")
        if (run_dir / "promotion.md").read_bytes() != (second_run / "promotion.md").read_bytes():
            raise AssertionError("promotion summary is not deterministic")

        docs_evidence = create_evidence(root / "docs-source", ["README.md"])
        docs_output = root / "docs-impact"
        invoke(fake_gh, fake_git, docs_evidence, docs_output, mode="docs-impact")
        docs_run = next(path.parent for path in docs_output.glob("*/manifest.tsv"))
        if (docs_run / "quality-metrics.json").exists():
            raise AssertionError("documentation impact fabricated quality metrics")
        if validate_promotion(
            docs_run, read_tsv(docs_run / "manifest.tsv", "docs manifest")
        ) is None:
            raise AssertionError("documentation impact was not promoted")

        missing_spec_sizes = create_evidence(
            root / "missing-spec-sizes-source", include_spec_sizes=False
        )
        missing_output = root / "missing-spec-sizes"
        missing = invoke(
            fake_gh,
            fake_git,
            missing_spec_sizes,
            missing_output,
            expected=2,
        )
        require(missing, "required evidence artifact is missing: spec-sizes.json")

        for field, value, diagnostic in (
            ("source_commit", "f" * 40, "source identity does not match"),
            ("input_fingerprint", "f" * 64, "source identity does not match"),
            ("limit_bytes", 16385, "limits do not match"),
            ("specifications", [], "identities do not match"),
            ("status", "over-limit", "size status is invalid"),
        ):
            invalid = create_evidence(root / f"invalid-spec-{field}")
            document = spec_sizes_document()
            document[field] = value
            write_json(invalid / "spec-sizes.json", document)
            inventory = invalid / "artifacts.tsv"
            inventory.write_text(
                "\n".join(
                    f"file\tspec-sizes.json\t{digest(invalid / 'spec-sizes.json')}"
                    if line.startswith("file\tspec-sizes.json\t") else line
                    for line in inventory.read_text(encoding="utf-8").splitlines()
                ) + "\n", encoding="utf-8",
            )
            invalid_manifest = invalid / "manifest.tsv"
            invalid_manifest.write_text(
                "\n".join(
                    f"artifacts_sha256\t{digest(inventory)}"
                    if line.startswith("artifacts_sha256\t") else line
                    for line in invalid_manifest.read_text(encoding="utf-8").splitlines()
                ) + "\n", encoding="utf-8",
            )
            rejected = invoke(
                fake_gh, fake_git, invalid, root / f"rejected-spec-{field}",
                expected=2,
            )
            require(rejected, diagnostic)

        eventual = root / "eventual-pr"
        invoke(fake_gh, fake_git, evidence, eventual, mode="eventual-pr")
        if not next(eventual.glob("*/promotion.tsv"), None):
            raise AssertionError("promotion did not retry eventual PR association")

        for mode, diagnostic in (
            ("one-parent", "not an exact two-parent merge"),
            ("no-pr", "no unique exact merged pull request"),
            ("stale-run", "no successful pre-merge"),
            ("duplicate-artifact", "no unique exact evidence artifact"),
            ("tree-mismatch", "do not have the same tree and parents"),
            ("parent-mismatch", "do not have the same tree and parents"),
            ("tampered-artifact", "artifact digest does not match"),
            ("symlinked-run", "evidence run directory is unsafe"),
        ):
            output = root / mode
            failed = invoke(
                fake_gh, fake_git, evidence, output, mode=mode, expected=2
            )
            require(failed, diagnostic)
            if output.exists():
                raise AssertionError(f"failed promotion retained output: {mode}")

        promotion_path = run_dir / "promotion.tsv"
        original = promotion_path.read_text(encoding="utf-8")
        promotion_path.write_text(
            original.replace(f"main_tree\t{TREE}", f"main_tree\t{'0' * 40}"),
            encoding="utf-8",
        )
        try:
            validate_promotion(run_dir, manifest)
        except PromotionError as error:
            if "does not bind" not in str(error):
                raise
        else:
            raise AssertionError("tampered promotion evidence was accepted")

        production = invoke(
            fake_gh,
            fake_git,
            evidence,
            root / "production",
            expected=2,
            test_mode=False,
        )
        require(production, "restricted to a GitHub main push")

    print("Quality promotion contracts passed")


if __name__ == "__main__":
    main()
