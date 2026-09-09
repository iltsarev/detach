#!/usr/bin/env python3
"""Contract tests for hosted quality baseline restoration."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/quality-baseline"


def invoke(
    fake_gh: Path,
    output_root: Path,
    *,
    mode: str = "success",
    profile: str = "combined",
    expected: int = 0,
    test_mode: bool = True,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["DETACH_QUALITY_BASELINE_GH"] = str(fake_gh)
    environment["FAKE_GH_MODE"] = mode
    if test_mode:
        environment["DETACH_QUALITY_BASELINE_TEST_MODE"] = "1"
    else:
        environment.pop("DETACH_QUALITY_BASELINE_TEST_MODE", None)
    result = subprocess.run(
        [
            str(SCRIPT), "--repository", "owner/repository",
            "--output-root", str(output_root),
            "--profile", profile,
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
            f"unexpected exit {result.returncode}, expected {expected}\n{result.stdout}")
    return result


def require(result: subprocess.CompletedProcess[str], value: str) -> None:
    if value not in result.stdout:
        raise AssertionError(f"missing diagnostic {value!r}:\n{result.stdout}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="detach-quality-baseline-") as raw:
        root = Path(raw)
        fake_gh = root / "fake-gh"
        fake_gh.write_text(
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
arguments = sys.argv[1:]
mode = os.environ.get("FAKE_GH_MODE", "success")
if arguments[0] == "api" and "workflows/quality-gates.yml/runs" in arguments[1]:
    if mode == "malformed": print("{")
    elif mode == "no-runs": print(json.dumps({"workflow_runs": []}))
    elif mode == "partial-latest": print(json.dumps({"workflow_runs": [{"id": 124}, {"id": 123}]}))
    elif mode == "profile-selection": print(json.dumps({"workflow_runs": [{"id": 125}, {"id": 124}]}))
    elif mode == "dual-profile": print(json.dumps({"workflow_runs": [{"id": 126}]}))
    else: print(json.dumps({"workflow_runs": [{"id": 123}]}))
elif arguments[0] == "api" and "/artifacts" in arguments[1]:
    run_id = arguments[1].split("/actions/runs/")[1].split("/")[0]
    values = [{"expired": False, "name": f"quality-gate-evidence-{run_id}-1"}]
    if mode == "duplicate":
        values.append({"expired": False, "name": "quality-gate-evidence-123-2"})
    print(json.dumps({"artifacts": values}))
elif arguments[:2] == ["run", "download"]:
    if mode != "missing-manifest":
        destination = Path(arguments[arguments.index("--dir") + 1]) / "run"
        destination.mkdir()
        (destination / "manifest.tsv").write_text("schema\\t4\\n")
        run_id = arguments[2]
        if mode != "no-metrics" and not (mode == "partial-latest" and run_id == "124"):
            if mode == "legacy":
                metrics = {"schema": 1}
            elif mode == "invalid-profile":
                metrics = {"schema": 2, "coverage_profile": "other"}
            else:
                profile = "swift" if mode == "profile-selection" and run_id == "125" else "combined"
                metrics = {"schema": 2, "coverage_profile": profile}
            (destination / "quality-metrics.json").write_text(json.dumps(metrics) + "\\n")
            if mode == "dual-profile":
                (destination / "quality-metrics-swift.json").write_text(
                    json.dumps({"schema": 2, "coverage_profile": "swift"}) + "\\n")
else:
    raise SystemExit(3)
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)

        success_root = root / "success"
        success = invoke(fake_gh, success_root)
        restored = Path(success.stdout.strip())
        if restored != success_root / "123" or not (restored / "run/manifest.tsv").is_file():
            raise AssertionError("baseline artifact was not restored deterministically")
        collision = invoke(fake_gh, success_root)
        if Path(collision.stdout.strip()) != restored:
            raise AssertionError("baseline cache reuse changed the selected evidence")

        partial_root = root / "partial-latest"
        partial = invoke(fake_gh, partial_root, mode="partial-latest")
        if Path(partial.stdout.strip()) != partial_root / "123":
            raise AssertionError("baseline did not skip a valid metrics-free main run")
        if not (partial_root / "124/run/manifest.tsv").is_file():
            raise AssertionError("partial main evidence was not inspected")

        profile_root = root / "profile-selection"
        combined = invoke(
            fake_gh, profile_root, mode="profile-selection", profile="combined")
        if Path(combined.stdout.strip()) != profile_root / "124":
            raise AssertionError("baseline did not skip a newer mismatched profile")
        swift = invoke(
            fake_gh, profile_root, mode="profile-selection", profile="swift")
        if Path(swift.stdout.strip()) != profile_root / "125":
            raise AssertionError("baseline did not select the newest Swift profile")

        dual_root = root / "dual-profile"
        dual_swift = invoke(
            fake_gh, dual_root, mode="dual-profile", profile="swift")
        if Path(dual_swift.stdout.strip()) != dual_root / "126":
            raise AssertionError("baseline did not select the auxiliary Swift profile")
        dual_combined = invoke(
            fake_gh, dual_root, mode="dual-profile", profile="combined")
        if Path(dual_combined.stdout.strip()) != dual_root / "126":
            raise AssertionError("baseline did not select the primary combined profile")

        legacy = invoke(fake_gh, root / "legacy", mode="legacy")
        if Path(legacy.stdout.strip()) != root / "legacy/123":
            raise AssertionError("schema-1 metrics did not retain combined continuity")

        malformed = invoke(fake_gh, root / "malformed", mode="malformed", expected=2)
        require(malformed, "response is malformed")
        missing = invoke(fake_gh, root / "no-runs", mode="no-runs", expected=2)
        require(missing, "no successful main quality run")
        duplicate = invoke(fake_gh, root / "duplicate", mode="duplicate", expected=2)
        require(duplicate, "no unique evidence artifact")
        no_manifest = invoke(
            fake_gh, root / "missing-manifest", mode="missing-manifest", expected=2)
        require(no_manifest, "no unique quality manifest")
        no_metrics = invoke(
            fake_gh, root / "no-metrics", mode="no-metrics", expected=2)
        require(no_metrics, "no successful main quality run has combined quality metrics")
        invalid_profile = invoke(
            fake_gh, root / "invalid-profile", mode="invalid-profile", expected=2)
        require(invalid_profile, "coverage profile is invalid")
        override = invoke(
            fake_gh, root / "production-override", expected=2, test_mode=False)
        require(override, "baseline output must use")

    print("Quality baseline contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
