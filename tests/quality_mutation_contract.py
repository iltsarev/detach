#!/usr/bin/env python3
"""Contract tests for the deterministic mutation runner."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/quality-mutation"
WORKFLOW = ROOT / ".github/workflows/quality-mutations.yml"
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import POLICY_FILE, Policy  # noqa: E402


POLICY = Policy(POLICY_FILE)


def fail(message: str) -> None:
    raise AssertionError(message)


def invoke(
    manifest: Path,
    arguments: list[str],
    *,
    command: Optional[list[str]] = None,
    extra_environment: Optional[dict[str, str]] = None,
    expected: int = 0,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["DETACH_QUALITY_MUTATION_TEST_MODE"] = "1"
    if command is not None:
        environment["DETACH_QUALITY_MUTATION_TEST_COMMAND"] = json.dumps(command)
    if extra_environment is not None:
        environment.update(extra_environment)
    result = subprocess.run(
        [str(SCRIPT), "--manifest", str(manifest), *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != expected:
        fail(
            f"unexpected exit {result.returncode}, expected {expected}: "
            f"{' '.join(arguments)}\n{result.stdout}")
    return result


def command_for(token: str, exit_code: int, marker: bool = True) -> list[str]:
    program = (
        "from pathlib import Path; import sys; "
        "value=Path('app/Sources/Test.swift').read_text(); "
        f"print('MUTANT_KILLED' if {marker!r} else 'COMPILER_ERROR'); "
        f"sys.exit({exit_code} if {token!r} in value else 0)"
    )
    return [sys.executable, "-c", program]


def corpus() -> dict[str, object]:
    return {
        "schema": 1,
        "mutants": [
            {
                "id": "first-safety-check",
                "requirement": "QC-TEST-FIRST",
                "source": "app/Sources/Test.swift",
                "before": "SAFE_A",
                "after": "MUTATED_A",
                "test_suite": "TestModule.FirstTests",
                "failure_regex": "MUTANT_KILLED",
            },
            {
                "id": "second-safety-check",
                "requirement": "QC-TEST-SECOND",
                "source": "app/Sources/Test.swift",
                "before": "SAFE_B",
                "after": "MUTATED_B",
                "test_suite": "TestModule.SecondTests",
                "failure_regex": "MUTANT_KILLED",
            },
        ],
    }


def main() -> int:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    for required in (
        "schedule:",
        'cron: "17 5 * * 1"',
        "timeout-minutes: 8",
        "scripts/quality-mutation run",
        "scripts/quality-mutation summarize",
        "fail-fast: false",
        "if: github.ref == 'refs/heads/main'",
        "scripts/quality-care latest --optional",
        "care_args+=(--care-summary",
        "CARE_SUMMARY:",
        'delimiter="detach-$(uuidgen)"',
        "printf 'summary<<%s\\n'",
    ):
        if required not in workflow:
            fail(f"mutation workflow is missing: {required}")
    if 'if [ -n "${{' in workflow or "printf 'summary=%s\\n'" in workflow:
        fail("mutation dashboard interpolates downloaded paths into the shell")
    if "<<EOF" in workflow:
        fail("mutation dashboard uses a predictable output delimiter")
    if re.search(r"uses:\s+\S+@v[0-9]", workflow):
        fail("mutation workflow contains a mutable Action tag")
    with tempfile.TemporaryDirectory(prefix="detach-quality-mutation-") as raw:
        workspace = Path(raw) / "workspace"
        source = workspace / "app/Sources/Test.swift"
        source.parent.mkdir(parents=True)
        original = "let first = SAFE_A\nlet second = SAFE_B\n"
        source.write_text(original, encoding="utf-8")
        manifest = Path(raw) / "mutations.json"
        manifest.write_text(json.dumps(corpus()), encoding="utf-8")

        invoke(manifest, ["validate"])
        listed = invoke(manifest, ["list"]).stdout.splitlines()
        if listed != ["first-safety-check", "second-safety-check"]:
            fail(f"mutation order changed: {listed}")
        matrix = json.loads(invoke(manifest, ["matrix"]).stdout)
        if matrix != {
            "include": [{"id": "first-safety-check"}, {"id": "second-safety-check"}]
        }:
            fail("mutation matrix is not deterministic")

        results = Path(raw) / "results"
        killed = results / "first.json"
        invoke(
            manifest,
            [
                "run", "--id", "first-safety-check", "--workspace", str(workspace),
                "--output", str(killed), "--log", str(results / "first.log"),
            ],
            command=command_for("MUTATED_A", 1),
        )
        if json.loads(killed.read_text(encoding="utf-8"))["status"] != "killed":
            fail("a marked test failure did not kill the mutant")
        if source.read_text(encoding="utf-8") != original:
            fail("source was not restored after a killed mutant")

        survived = results / "second.json"
        invoke(
            manifest,
            [
                "run", "--id", "second-safety-check", "--workspace", str(workspace),
                "--output", str(survived), "--log", str(results / "second.log"),
            ],
            command=command_for("MUTATED_B", 0),
            expected=1,
        )
        if json.loads(survived.read_text(encoding="utf-8"))["status"] != "survived":
            fail("a passing mutation test did not report a survivor")
        if source.read_text(encoding="utf-8") != original:
            fail("source was not restored after a surviving mutant")

        summary = Path(raw) / "summary.json"
        invoke(
            manifest,
            ["summarize", "--results-root", str(results), "--output", str(summary)],
            expected=1,
        )
        summary_value = json.loads(summary.read_text(encoding="utf-8"))
        if summary_value["score_percent"] != 50 or summary_value["status"] != "failed":
            fail("mutation score floor was not enforced")

        passed_summary = Path(raw) / "passed-summary.json"
        killed_value = json.loads(killed.read_text(encoding="utf-8"))
        passed_summary.write_text(
            json.dumps({
                "schema": 1,
                "policy": POLICY.version,
                "score_percent": 100,
                "floor_percent": 100,
                "killed": 1,
                "total": 1,
                "status": "passed",
                "results": [killed_value],
            }),
            encoding="utf-8",
        )
        fake_gh = Path(raw) / "fake-gh"
        fake_gh.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
arguments = sys.argv[1:]
if arguments[0] == "api" and "workflows/quality-mutations.yml/runs" in arguments[1]:
    print("123")
elif arguments[0] == "api" and "/artifacts" in arguments[1]:
    print("quality-mutation-summary-123-1")
elif arguments[:2] == ["run", "download"]:
    destination = Path(arguments[arguments.index("--dir") + 1])
    shutil.copyfile(os.environ["FAKE_MUTATION_SUMMARY"], destination / "summary.json")
else:
    raise SystemExit(3)
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        latest = invoke(
            manifest,
            [
                "latest", "--repository", "owner/repository",
                "--output-root", str(Path(raw) / "latest"),
            ],
            extra_environment={
                "DETACH_QUALITY_MUTATION_GH": str(fake_gh),
                "FAKE_MUTATION_SUMMARY": str(passed_summary),
            },
        )
        latest_path = Path(latest.stdout.strip())
        if not latest_path.is_file() or latest_path.name != "summary.json":
            fail("latest hosted mutation summary was not restored")

        invalid = Path(raw) / "invalid.json"
        invoke(
            manifest,
            [
                "run", "--id", "first-safety-check", "--workspace", str(workspace),
                "--output", str(invalid), "--log", str(Path(raw) / "invalid.log"),
            ],
            command=command_for("MUTATED_A", 2, marker=False),
            expected=1,
        )
        if json.loads(invalid.read_text(encoding="utf-8"))["status"] != "invalid-failure":
            fail("an infrastructure-like failure was counted as a killed mutant")

        timeout = Path(raw) / "timeout.json"
        invoke(
            manifest,
            [
                "run", "--id", "first-safety-check", "--workspace", str(workspace),
                "--output", str(timeout), "--log", str(Path(raw) / "timeout.log"),
                "--timeout-seconds", "1",
            ],
            command=[sys.executable, "-c", "import time; time.sleep(30)"],
            expected=1,
        )
        if json.loads(timeout.read_text(encoding="utf-8"))["status"] != "timeout":
            fail("a timed-out mutant did not fail closed")
        if source.read_text(encoding="utf-8") != original:
            fail("source was not restored after timeout")

        duplicate = corpus()
        duplicate["mutants"][1]["id"] = "first-safety-check"  # type: ignore[index]
        duplicate_manifest = Path(raw) / "duplicate.json"
        duplicate_manifest.write_text(json.dumps(duplicate), encoding="utf-8")
        error = invoke(duplicate_manifest, ["validate"], expected=2).stdout
        if "invalid or duplicate id" not in error:
            fail("duplicate mutant failure is unclear")

    print("Quality mutation contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
