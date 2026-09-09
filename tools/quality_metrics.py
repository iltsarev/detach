#!/usr/bin/env python3
"""Collect and compare Detach quality metrics without manual floors."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, NoReturn, Optional

from quality_policy import POLICY_FILE, Policy, PolicyError, ROOT
from quality_promote import PromotionError, validate_promotion


HEX_COMMIT = re.compile(r"^[0-9a-f]{40}$")
TEST_ID = re.compile(r"^(Detach(?:App|Kit)Tests\.[A-Za-z0-9_]+/[A-Za-z0-9_]+)$")
SWIFT_LOG_TEST = re.compile(
    r"^Test Case '-\[(Detach(?:App|Kit)Tests\.[^ ]+) ([^]]+)\]' started\.$"
)
HUNK = re.compile(r"^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@")
UI_PREFIX = "app/Sources/DetachApp/"
BUSINESS_PREFIX = "app/Sources/DetachKit/"
COVERAGE_PROFILES = ("swift", "combined")


class MetricsError(Exception):
    """Invalid, incomplete, or regressed quality evidence."""


def fail(message: str) -> NoReturn:
    print(f"quality-metrics: {message}", file=sys.stderr)
    raise SystemExit(2)


def safe_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise MetricsError(f"{label} is missing or unsafe: {path}")
    return path


def read_json(path: Path, label: str) -> Any:
    safe_file(path, label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MetricsError(f"{label} is malformed: {error}") from error


def write_json(path: Path, value: Any) -> None:
    path = path.resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink() or (path.exists() and path.is_symlink()):
        raise MetricsError(f"output path is unsafe: {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_text(
        json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def run(arguments: list[str], *, text: bool = True) -> subprocess.CompletedProcess[Any]:
    try:
        return subprocess.run(
            arguments,
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=text,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError):
            stderr = error.stderr
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            detail = str(stderr or "").strip()
        suffix = f": {detail}" if detail else ""
        raise MetricsError(f"command failed: {' '.join(arguments)}{suffix}") from error


def normalize_source(filename: str) -> Optional[str]:
    normalized = filename.replace("\\", "/")
    marker = "/app/Sources/"
    if marker in normalized:
        return "app/Sources/" + normalized.split(marker, 1)[1]
    if normalized.startswith("app/Sources/"):
        return normalized
    return None


def integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MetricsError(f"{label} must be a non-negative integer")
    return value


def percent(covered: int, total: int) -> float:
    return round(100.0 if total == 0 else 100.0 * covered / total, 2)


def coverage_value(covered: int, total: int) -> dict[str, Any]:
    return {"covered": covered, "total": total, "percent": percent(covered, total)}


def segment_lines(raw_segments: Any, label: str) -> dict[int, bool]:
    if not isinstance(raw_segments, list):
        raise MetricsError(f"{label} segments are malformed")
    segments: list[tuple[int, int, int, bool, bool]] = []
    for index, raw in enumerate(raw_segments):
        if not isinstance(raw, list) or len(raw) < 6:
            raise MetricsError(f"{label} segment {index} is malformed")
        line = integer(raw[0], f"{label} segment line")
        column = integer(raw[1], f"{label} segment column")
        count = integer(raw[2], f"{label} segment count")
        has_count, is_gap = raw[3], raw[5]
        if line == 0 or column == 0 or not isinstance(has_count, bool) or not isinstance(is_gap, bool):
            raise MetricsError(f"{label} segment {index} is invalid")
        segments.append((line, column, count, has_count, is_gap))
    if segments != sorted(segments, key=lambda item: (item[0], item[1])):
        raise MetricsError(f"{label} segments are not ordered")

    lines: dict[int, bool] = {}
    for index, (start_line, start_column, count, has_count, is_gap) in enumerate(segments):
        if not has_count or is_gap:
            continue
        if index + 1 < len(segments):
            end_line, end_column = segments[index + 1][0:2]
        else:
            end_line, end_column = start_line, start_column + 1
        if (end_line, end_column) <= (start_line, start_column):
            raise MetricsError(f"{label} contains an empty coverage segment")
        last_line = end_line if end_line > start_line and end_column > 1 else end_line - 1
        if end_line == start_line:
            last_line = start_line
        for line in range(start_line, last_line + 1):
            # LLVM's line view uses the first active region on a source line.
            # Nested regions can have a non-zero count while their outer line
            # remains uncovered, so a later segment must not replace it.
            lines.setdefault(line, count > 0)
    return lines


def collect_coverage(document: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(document, dict) or document.get("type") != "llvm.coverage.json.export":
        raise MetricsError("LLVM coverage document type is unsupported")
    data = document.get("data")
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
        raise MetricsError("LLVM coverage data is malformed")
    raw_files = data[0].get("files")
    if not isinstance(raw_files, list):
        raise MetricsError("LLVM coverage file list is malformed")
    files: dict[str, dict[str, Any]] = {}
    for raw_file in raw_files:
        if not isinstance(raw_file, dict) or not isinstance(raw_file.get("filename"), str):
            raise MetricsError("LLVM coverage file record is malformed")
        path = normalize_source(raw_file["filename"])
        if path is None:
            continue
        if path in files:
            raise MetricsError(f"LLVM coverage contains a duplicate source: {path}")
        try:
            raw_summary = raw_file["summary"]["lines"]
        except (KeyError, TypeError) as error:
            raise MetricsError(f"LLVM coverage summary is missing: {path}") from error
        covered = integer(raw_summary.get("covered"), f"{path} covered lines")
        total = integer(raw_summary.get("count"), f"{path} total lines")
        if covered > total or total == 0:
            raise MetricsError(f"LLVM coverage summary is invalid: {path}")
        lines = segment_lines(raw_file.get("segments"), path)
        if not lines:
            raise MetricsError(f"LLVM coverage line map is empty: {path}")
        files[path] = {"covered": covered, "total": total, "lines": lines}
    if not files:
        raise MetricsError("LLVM coverage contains no Detach sources")
    return files


def references(value: str) -> list[str]:
    return [] if value in ("", "-") else value.split(",")


def opportunity_risk(
    path: str, policy: Policy, release_domain: str
) -> tuple[int, str]:
    if any(source == path for source, _ in policy.critical):
        return 5, "critical"
    return {
        "both": (4, "power-and-installation"),
        "install": (3, "installation-sensitive"),
        "unknown": (2, "unclassified"),
        "safe": (1, "user-journey"),
    }[release_domain]


def next_coverage_milestone(current_percent: float) -> int:
    if current_percent >= 100:
        return 100
    milestone = min(100, int(math.ceil(current_percent / 5.0) * 5))
    return min(100, milestone + 5) if milestone <= current_percent else milestone


def build_opportunities(
    coverage: dict[str, dict[str, Any]],
    metrics: dict[str, Any],
    policy: Policy,
    source_commit: str,
) -> dict[str, Any]:
    observed = metrics["suites"]["ui"]["line_coverage"]
    current_percent = observed["percent"]
    milestone = next_coverage_milestone(current_percent)
    lines_to_milestone = max(
        0,
        math.ceil(milestone * observed["total"] / 100) - observed["covered"],
    )
    entries: list[dict[str, Any]] = []
    for path, value in coverage.items():
        if group_for_source(path, policy) != "ui":
            continue
        uncovered = value["total"] - value["covered"]
        if uncovered == 0:
            continue
        classification = policy.classify(path)
        capabilities = sorted(references(classification.capabilities))
        journeys = sorted(references(classification.journeys))
        requirements = sorted(
            {
                requirement
                for capability in capabilities
                for requirement in references(policy.capabilities[capability][1])
            }
            | {
                requirement
                for journey in journeys
                for requirement in references(policy.journeys[journey][1])
            }
        )
        scenario_stages = {
            policy.scenarios[scenario][0]
            for journey in journeys
            for scenario in references(policy.journeys[journey][2])
            if policy.scenarios[scenario][1] not in ("planned", "manual-release")
        }
        risk_tier, risk = opportunity_risk(
            path, policy, classification.release_domain
        )
        entries.append(
            {
                "path": path,
                "risk": risk,
                "risk_tier": risk_tier,
                "line_coverage": coverage_value(value["covered"], value["total"]),
                "uncovered": uncovered,
                "capabilities": capabilities,
                "requirements": requirements,
                "journeys": journeys,
                "recommended_evidence": (
                    "packaged-user-journey"
                    if "ui-e2e" in scenario_stages
                    else "behavioral-unit-test"
                ),
            }
        )
    entries.sort(
        key=lambda item: (
            -item["risk_tier"],
            -len(item["requirements"]),
            -len(item["journeys"]),
            -item["uncovered"],
            item["path"],
        )
    )
    for rank, entry in enumerate(entries, 1):
        entry["rank"] = rank
    return {
        "schema": 1,
        "policy": policy.version,
        "source_commit": source_commit,
        "suite": "ui",
        "observed": observed,
        "next_milestone_percent": milestone,
        "lines_to_milestone": lines_to_milestone,
        "opportunities": entries,
    }


def validate_opportunities(
    document: Any, *, expected_policy: Optional[int] = None
) -> dict[str, Any]:
    required = {
        "schema",
        "policy",
        "source_commit",
        "suite",
        "observed",
        "next_milestone_percent",
        "lines_to_milestone",
        "opportunities",
    }
    if (
        not isinstance(document, dict)
        or set(document) != required
        or document.get("schema") != 1
        or document.get("suite") != "ui"
    ):
        raise MetricsError("coverage opportunities schema is unsupported")
    policy_version = document.get("policy")
    if not isinstance(policy_version, int) or policy_version <= 0:
        raise MetricsError("coverage opportunities policy is invalid")
    if expected_policy is not None and policy_version != expected_policy:
        raise MetricsError("coverage opportunities use another policy")
    if not HEX_COMMIT.fullmatch(document.get("source_commit", "")):
        raise MetricsError("coverage opportunities source commit is invalid")
    covered, total = validate_coverage(document.get("observed"), "opportunity observed")
    milestone = document.get("next_milestone_percent")
    if not isinstance(milestone, int) or not 1 <= milestone <= 100:
        raise MetricsError("coverage opportunity milestone is invalid")
    if milestone != next_coverage_milestone(document["observed"]["percent"]):
        raise MetricsError("coverage opportunity milestone is inconsistent")
    expected_lines = max(0, math.ceil(milestone * total / 100) - covered)
    if integer(document.get("lines_to_milestone"), "lines to milestone") != expected_lines:
        raise MetricsError("coverage opportunity milestone line count is inconsistent")
    entries = document.get("opportunities")
    if not isinstance(entries, list):
        raise MetricsError("coverage opportunities are malformed")
    paths: set[str] = set()
    fields = {
        "rank",
        "path",
        "risk",
        "risk_tier",
        "line_coverage",
        "uncovered",
        "capabilities",
        "requirements",
        "journeys",
        "recommended_evidence",
    }
    risk_names = {
        1: "user-journey",
        2: "unclassified",
        3: "installation-sensitive",
        4: "power-and-installation",
        5: "critical",
    }
    for expected_rank, entry in enumerate(entries, 1):
        if not isinstance(entry, dict) or set(entry) != fields:
            raise MetricsError("coverage opportunity record is malformed")
        path = entry.get("path")
        risk_tier = entry.get("risk_tier")
        if (
            entry.get("rank") != expected_rank
            or not isinstance(path, str)
            or not path.startswith(UI_PREFIX)
            or path in paths
            or risk_tier not in risk_names
            or entry.get("risk") != risk_names[risk_tier]
            or entry.get("recommended_evidence")
            not in ("packaged-user-journey", "behavioral-unit-test")
        ):
            raise MetricsError("coverage opportunity identity is invalid")
        paths.add(path)
        entry_covered, entry_total = validate_coverage(
            entry.get("line_coverage"), path
        )
        if (
            integer(entry.get("uncovered"), f"{path} uncovered")
            != entry_total - entry_covered
            or entry_covered == entry_total
        ):
            raise MetricsError("coverage opportunity uncovered count is inconsistent")
        for key in ("capabilities", "requirements", "journeys"):
            values = entry.get(key)
            if (
                not isinstance(values, list)
                or values != sorted(set(values))
                or any(not isinstance(value, str) or not value for value in values)
            ):
                raise MetricsError(f"coverage opportunity {key} are malformed")
    return document


def collect_tests(path: Path) -> set[str]:
    safe_file(path, "Swift test evidence")
    tests: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="strict").splitlines():
        candidate = line.strip()
        direct = TEST_ID.fullmatch(candidate)
        if direct:
            tests.add(direct.group(1))
            continue
        logged = SWIFT_LOG_TEST.fullmatch(candidate)
        if logged:
            candidate = f"{logged.group(1)}/{logged.group(2)}"
            if TEST_ID.fullmatch(candidate):
                tests.add(candidate)
    if not tests:
        raise MetricsError("Swift test evidence contains no Detach tests")
    return tests


def tracked_sources() -> set[str]:
    output = run(["git", "ls-files", "app/Sources/DetachApp/*.swift", "app/Sources/DetachKit/*.swift"]).stdout
    return {line for line in output.splitlines() if line}


def group_for_source(path: str, policy: Policy) -> Optional[str]:
    if policy.coverage_exclusion(path) is not None:
        return None
    if path.startswith(UI_PREFIX):
        return "ui"
    if path.startswith(BUSINESS_PREFIX):
        return "business"
    return None


def changed_lines(base: str) -> dict[str, set[int]]:
    if not base:
        return {}
    if not HEX_COMMIT.fullmatch(base):
        raise MetricsError("changed-line base commit is invalid")
    run(["git", "cat-file", "-e", f"{base}^{{commit}}"])
    output = run(
        [
            "git",
            "diff",
            "--no-ext-diff",
            "--unified=0",
            "--diff-filter=ACMR",
            base,
            "--",
            "app/Sources",
        ]
    ).stdout
    result: dict[str, set[int]] = {}
    current_path = ""
    for line in output.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        match = HUNK.match(line)
        if not match or not current_path:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        if count:
            result.setdefault(current_path, set()).update(range(start, start + count))
    untracked = run(
        ["git", "ls-files", "--others", "--exclude-standard", "app/Sources"]
    ).stdout.splitlines()
    for relative in untracked:
        source = ROOT / relative
        if source.is_file() and not source.is_symlink():
            line_count = len(source.read_text(encoding="utf-8").splitlines())
            result.setdefault(relative, set()).update(range(1, line_count + 1))
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_tsv_map(path: Path, label: str) -> dict[str, str]:
    safe_file(path, label)
    values: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or fields[0] in values:
            raise MetricsError(f"{label} has a malformed record at line {line_number}")
        values[fields[0]] = fields[1]
    return values


def load_baseline_run(root: Path) -> tuple[Path, dict[str, str], str]:
    if not root.is_dir() or root.is_symlink():
        raise MetricsError(f"baseline root is missing or unsafe: {root}")
    manifests = sorted(root.glob("*/manifest.tsv"))
    if len(manifests) != 1:
        raise MetricsError("baseline root must contain exactly one quality run")
    run_dir = manifests[0].parent
    manifest = read_tsv_map(manifests[0], "baseline manifest")
    required = {"schema": "4", "result": "passed"}
    for key, expected in required.items():
        if manifest.get(key) != expected:
            raise MetricsError(f"baseline manifest {key} is not {expected}")
    if not HEX_COMMIT.fullmatch(manifest.get("source_commit", "")):
        raise MetricsError("baseline manifest source commit is invalid")
    if not manifest.get("policy", "").isdigit():
        raise MetricsError("baseline manifest policy is invalid")
    artifacts = safe_file(run_dir / "artifacts.tsv", "baseline artifact inventory")
    if sha256(artifacts) != manifest.get("artifacts_sha256"):
        raise MetricsError("baseline artifact inventory digest does not match its manifest")
    try:
        promotion = validate_promotion(run_dir, manifest)
    except PromotionError as error:
        raise MetricsError(str(error)) from error
    if manifest.get("authority") == "ci-main":
        if promotion is not None:
            raise MetricsError("direct ci-main evidence cannot contain a promotion")
        effective_source = manifest["source_commit"]
    elif manifest.get("authority") == "ci-merge" and promotion is not None:
        effective_source = promotion["main_commit"]
    else:
        raise MetricsError("baseline has no direct or promoted ci-main authority")
    return run_dir, manifest, effective_source


def artifact_digest(run_dir: Path, relative: str) -> Optional[str]:
    values: list[str] = []
    for line in (run_dir / "artifacts.tsv").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if fields == ["schema", "1"]:
            continue
        if (
            len(fields) != 3
            or fields[0] != "file"
            or not re.fullmatch(r"[0-9a-f]{64}", fields[2])
        ):
            raise MetricsError("baseline artifact inventory is malformed")
        if fields[1] == relative:
            values.append(fields[2])
    if len(values) > 1:
        raise MetricsError(f"baseline artifact is duplicated: {relative}")
    return values[0] if values else None


def baseline_metrics_file(run_dir: Path, coverage_profile: str) -> Path:
    matches: list[Path] = []
    for name in ("quality-metrics.json", "quality-metrics-swift.json"):
        candidate = run_dir / name
        digest = artifact_digest(run_dir, name)
        if not candidate.exists() and digest is None:
            continue
        if digest is None or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise MetricsError(f"baseline metrics digest is missing or invalid: {name}")
        if sha256(safe_file(candidate, "baseline metrics")) != digest:
            raise MetricsError(f"baseline metrics digest does not match its inventory: {name}")
        document = validate_metrics(read_json(candidate, "baseline metrics"))
        if metrics_coverage_profile(document) == coverage_profile:
            matches.append(candidate)
    if not matches:
        raise MetricsError(
            f"last green main artifact has no {coverage_profile} quality metrics"
        )
    if len(matches) > 1:
        raise MetricsError(
            f"baseline contains duplicate {coverage_profile} metrics artifacts"
        )
    return matches[0]


def validate_coverage(value: Any, label: str, *, allow_empty: bool = False) -> tuple[int, int]:
    if not isinstance(value, dict) or set(value) != {"covered", "percent", "total"}:
        raise MetricsError(f"{label} coverage is malformed")
    covered = integer(value["covered"], f"{label} covered")
    total = integer(value["total"], f"{label} total")
    if (total == 0 and not allow_empty) or covered > total or value["percent"] != percent(covered, total):
        raise MetricsError(f"{label} coverage is inconsistent")
    return covered, total


def metrics_coverage_profile(document: dict[str, Any]) -> str:
    """Return the measured profile, including the schema-1 migration rule."""
    if document.get("schema") == 1:
        return "combined"
    profile = document.get("coverage_profile")
    if profile not in COVERAGE_PROFILES:
        raise MetricsError("quality metrics coverage profile is invalid")
    return profile


def validate_metrics(
    document: Any,
    *,
    expected_policy: Optional[int] = None,
    expected_profile: Optional[str] = None,
) -> dict[str, Any]:
    required_fields = {
        "schema", "policy", "source_commit", "suites", "critical_files",
        "changed_lines", "comparison",
    }
    schema = document.get("schema") if isinstance(document, dict) else None
    if schema == 2:
        required_fields.add("coverage_profile")
    if (
        not isinstance(document, dict)
        or set(document) != required_fields
        or schema not in (1, 2)
    ):
        raise MetricsError("quality metrics schema is unsupported")
    coverage_profile = metrics_coverage_profile(document)
    if expected_profile is not None and coverage_profile != expected_profile:
        raise MetricsError(
            "quality metrics coverage profile does not match the selected profile"
        )
    if not isinstance(document.get("policy"), int) or document["policy"] <= 0:
        raise MetricsError("quality metrics policy is invalid")
    if expected_policy is not None and document["policy"] != expected_policy:
        raise MetricsError("quality metrics use another policy")
    if not HEX_COMMIT.fullmatch(document.get("source_commit", "")):
        raise MetricsError("quality metrics source commit is invalid")
    suites = document.get("suites")
    if not isinstance(suites, dict) or set(suites) != {"business", "ui"}:
        raise MetricsError("quality metrics suites are malformed")
    for name in ("ui", "business"):
        suite = suites[name]
        if not isinstance(suite, dict) or set(suite) != {"line_coverage", "test_count", "tests"}:
            raise MetricsError(f"quality metrics {name} suite is malformed")
        tests = suite["tests"]
        if (
            not isinstance(tests, list)
            or tests != sorted(set(tests))
            or any(not isinstance(test, str) or not TEST_ID.fullmatch(test) for test in tests)
            or integer(suite["test_count"], f"{name} test count") != len(tests)
        ):
            raise MetricsError(f"quality metrics {name} tests are malformed")
        validate_coverage(suite["line_coverage"], name)
    critical = document.get("critical_files")
    if not isinstance(critical, list):
        raise MetricsError("quality metrics critical files are malformed")
    critical_paths: set[str] = set()
    for entry in critical:
        if not isinstance(entry, dict) or set(entry) != {"line_coverage", "path", "requirement"}:
            raise MetricsError("quality metrics critical file record is malformed")
        path = entry["path"]
        if (
            not isinstance(path, str)
            or not path.startswith("app/Sources/")
            or not isinstance(entry["requirement"], str)
            or not entry["requirement"].startswith("QC-")
            or path in critical_paths
        ):
            raise MetricsError("quality metrics critical path is invalid or duplicated")
        critical_paths.add(path)
        validate_coverage(entry["line_coverage"], path)
    changed = document.get("changed_lines")
    if not isinstance(changed, dict):
        raise MetricsError("quality metrics changed lines are malformed")
    required_changed = {"base_commit", "files", "line_coverage", "minimum_percent", "status"}
    if set(changed) != required_changed:
        raise MetricsError("quality metrics changed-line fields are malformed")
    if changed["base_commit"] and not HEX_COMMIT.fullmatch(changed["base_commit"]):
        raise MetricsError("quality metrics changed-line base is invalid")
    changed_covered, changed_total = validate_coverage(
        changed["line_coverage"], "changed-line", allow_empty=True
    )
    if changed["status"] not in ("not-available", "not-applicable", "passed", "failed"):
        raise MetricsError("quality metrics changed-line status is invalid")
    if not isinstance(changed["minimum_percent"], int) or not 1 <= changed["minimum_percent"] <= 100:
        raise MetricsError("quality metrics changed-line minimum is invalid")
    files = changed["files"]
    if not isinstance(files, list):
        raise MetricsError("quality metrics changed-line files are malformed")
    for item in files:
        if (
            not isinstance(item, dict)
            or set(item) != {"covered", "executable", "path"}
            or not isinstance(item["path"], str)
            or not item["path"].startswith("app/Sources/")
        ):
            raise MetricsError("quality metrics changed-line file record is malformed")
        executable = integer(item["executable"], "changed executable lines")
        covered = integer(item["covered"], "changed covered lines")
        if executable == 0 or covered > executable:
            raise MetricsError("quality metrics changed-line file counts are invalid")
    if sum(item["executable"] for item in files) != changed_total:
        raise MetricsError("quality metrics changed executable totals disagree")
    if sum(item["covered"] for item in files) != changed_covered:
        raise MetricsError("quality metrics changed covered totals disagree")
    expected_changed_status = (
        "not-available"
        if not changed["base_commit"]
        else "not-applicable"
        if changed_total == 0
        else "passed"
        if changed["line_coverage"]["percent"] >= changed["minimum_percent"]
        else "failed"
    )
    if changed["status"] != expected_changed_status:
        raise MetricsError("quality metrics changed-line status is inconsistent")
    comparison = document.get("comparison")
    if not isinstance(comparison, dict) or set(comparison) != {
        "baseline_policy",
        "baseline_source_commit",
        "mode",
        "regressions",
        "status",
    }:
        raise MetricsError("quality metrics comparison is malformed")
    if comparison["status"] not in ("not-available", "passed", "failed"):
        raise MetricsError("quality metrics comparison status is invalid")
    if not isinstance(comparison["regressions"], list) or any(
        not isinstance(item, str) or not item for item in comparison["regressions"]
    ):
        raise MetricsError("quality metrics regressions are malformed")
    baseline_source = comparison["baseline_source_commit"]
    baseline_policy = comparison["baseline_policy"]
    if (
        not isinstance(baseline_policy, int)
        or baseline_policy < 0
        or (baseline_source and not HEX_COMMIT.fullmatch(baseline_source))
        or comparison["mode"] not in ("none", "green-main-artifact")
    ):
        raise MetricsError("quality metrics comparison baseline is invalid")
    if comparison["mode"] == "none":
        if baseline_source or baseline_policy != 0:
            raise MetricsError("quality metrics no-baseline comparison is inconsistent")
    elif not baseline_source or baseline_policy <= 0:
        raise MetricsError("quality metrics baseline comparison is incomplete")
    expected_comparison_status = (
        "not-available"
        if not baseline_source
        else "failed"
        if comparison["regressions"]
        else "passed"
    )
    if comparison["status"] != expected_comparison_status:
        raise MetricsError("quality metrics comparison status is inconsistent")
    return document


def load_baseline(
    root: Optional[Path], coverage_profile: str
) -> tuple[Optional[dict[str, Any]], str, str]:
    if root is None:
        return None, "none", ""
    run_dir, manifest, effective_source = load_baseline_run(root)
    metrics_path = baseline_metrics_file(run_dir, coverage_profile)
    if metrics_path.exists():
        document = validate_metrics(
            read_json(metrics_path, "baseline metrics"),
            expected_profile=coverage_profile,
        )
        if document["source_commit"] != manifest["source_commit"]:
            raise MetricsError("baseline metrics source does not match its manifest")
        if document["policy"] != int(manifest["policy"]):
            raise MetricsError("baseline metrics policy does not match its manifest")
        effective_document = {**document, "source_commit": effective_source}
        return effective_document, "green-main-artifact", effective_source
    raise MetricsError("last green main artifact has no quality metrics")


def ratio_regressed(current: dict[str, Any], baseline: dict[str, Any]) -> bool:
    current_covered, current_total = validate_coverage(current, "current")
    baseline_covered, baseline_total = validate_coverage(baseline, "baseline")
    return current_covered * baseline_total < baseline_covered * current_total


def build_metrics(
    coverage: dict[str, dict[str, Any]],
    tests: set[str],
    policy: Policy,
    source_commit: str,
    base_commit: str,
    baseline: Optional[dict[str, Any]],
    baseline_mode: str,
    *,
    coverage_profile: str = "swift",
    changed_override: Optional[dict[str, set[int]]] = None,
    allow_incomplete_sources: bool = False,
) -> tuple[dict[str, Any], list[str]]:
    if coverage_profile not in COVERAGE_PROFILES:
        raise MetricsError("coverage profile is invalid")
    if not HEX_COMMIT.fullmatch(source_commit):
        raise MetricsError("source commit is invalid")
    if not allow_incomplete_sources:
        missing_sources = sorted(
            source
            for source in tracked_sources()
            if group_for_source(source, policy) is not None and source not in coverage
        )
        if missing_sources:
            raise MetricsError(f"LLVM coverage is missing tracked source: {missing_sources[0]}")

    suites: dict[str, Any] = {}
    for name, prefix in (("ui", "DetachAppTests."), ("business", "DetachKitTests.")):
        selected_tests = sorted(test for test in tests if test.startswith(prefix))
        selected_files = [
            value
            for path, value in coverage.items()
            if group_for_source(path, policy) == name
        ]
        covered = sum(value["covered"] for value in selected_files)
        total = sum(value["total"] for value in selected_files)
        if not selected_tests or total == 0:
            raise MetricsError(f"{name} metrics are empty")
        suites[name] = {
            "test_count": len(selected_tests),
            "tests": selected_tests,
            "line_coverage": coverage_value(covered, total),
        }

    for suite in policy.required_suites:
        if not any(test.startswith(f"{suite}/") for test in tests):
            raise MetricsError(f"required Swift suite is missing: {suite}")

    critical_files = []
    for source, requirement in policy.critical:
        value = coverage.get(source)
        if value is None:
            raise MetricsError(f"critical coverage source is missing: {source}")
        critical_files.append(
            {
                "path": source,
                "requirement": requirement,
                "line_coverage": coverage_value(value["covered"], value["total"]),
            }
        )

    minimum = policy.limits.get("changed_line_coverage_percent")
    if minimum is None or not 1 <= minimum <= 100:
        raise MetricsError("changed-line coverage minimum is missing or invalid")
    changed_by_path = (
        changed_override
        if changed_override is not None
        else (changed_lines(base_commit) if base_commit else {})
    )
    changed_files: list[dict[str, Any]] = []
    changed_covered = 0
    changed_total = 0
    for path in sorted(changed_by_path):
        if not path.endswith(".swift"):
            continue
        if policy.coverage_exclusion(path) is not None:
            continue
        excluded_lines = policy.coverage_region_lines(path)
        value = coverage.get(path)
        executable = 0
        covered = 0
        if value is not None:
            for line in changed_by_path[path]:
                if line in excluded_lines:
                    continue
                if line in value["lines"]:
                    executable += 1
                    covered += int(value["lines"][line])
        if executable:
            changed_files.append({"path": path, "executable": executable, "covered": covered})
            changed_total += executable
            changed_covered += covered
    changed_percent = percent(changed_covered, changed_total)
    if not base_commit:
        changed_status = "not-available"
    elif changed_total == 0:
        changed_status = "not-applicable"
    elif changed_percent >= minimum:
        changed_status = "passed"
    else:
        changed_status = "failed"

    # Blocking regressions cover the policy-critical sources only. Aggregate
    # ratios, test identities, and changed-line coverage are advisory: they
    # are reported but never turn functional evidence into a failure.
    regressions: list[str] = []
    advisories: list[str] = []
    if baseline is not None:
        for name in ("ui", "business"):
            current_suite = suites[name]
            baseline_suite = baseline["suites"][name]
            if current_suite["test_count"] < baseline_suite["test_count"]:
                advisories.append(
                    f"{name} test count regressed: {current_suite['test_count']} < "
                    f"{baseline_suite['test_count']}"
                )
            baseline_tests = baseline_suite.get("tests")
            if isinstance(baseline_tests, list):
                removed = sorted(set(baseline_tests) - set(current_suite["tests"]))
                if removed:
                    advisories.append(f"{name} test was removed: {removed[0]}")
            baseline_coverage = baseline_suite["line_coverage"]
            if ratio_regressed(current_suite["line_coverage"], baseline_coverage):
                advisories.append(
                    f"{name} line coverage regressed: "
                    f"{current_suite['line_coverage']['percent']:.2f} < "
                    f"{baseline_coverage['percent']:.2f}"
                )

        baseline_critical = {item["path"]: item for item in baseline["critical_files"]}
        current_critical = {item["path"]: item for item in critical_files}
        removed_critical = sorted(set(baseline_critical) - set(current_critical))
        if removed_critical:
            regressions.append(f"critical source left the inventory: {removed_critical[0]}")
        for path, current in current_critical.items():
            prior = baseline_critical.get(path)
            if prior is None:
                if current["line_coverage"]["covered"] != current["line_coverage"]["total"]:
                    regressions.append(f"new critical source is not fully covered: {path}")
                continue
            prior_coverage = prior["line_coverage"]
            if ratio_regressed(current["line_coverage"], prior_coverage):
                regressions.append(
                    f"critical line coverage regressed for {path}: "
                    f"{current['line_coverage']['percent']:.2f} < "
                    f"{prior_coverage['percent']:.2f}"
                )

    if changed_status == "failed":
        advisories.append(
            f"changed-line coverage regressed: {changed_percent:.2f} < {minimum:.2f}"
        )
    comparison_status = "not-available" if baseline is None else ("failed" if regressions else "passed")
    baseline_source = baseline.get("source_commit", "") if baseline else ""
    baseline_policy = baseline.get("policy", 0) if baseline else 0
    return {
        "schema": 2,
        "policy": policy.version,
        "source_commit": source_commit,
        "coverage_profile": coverage_profile,
        "suites": suites,
        "critical_files": critical_files,
        "changed_lines": {
            "base_commit": base_commit,
            "minimum_percent": minimum,
            "status": changed_status,
            "line_coverage": coverage_value(changed_covered, changed_total),
            "files": changed_files,
        },
        "comparison": {
            "status": comparison_status,
            "mode": baseline_mode,
            "baseline_source_commit": baseline_source,
            "baseline_policy": baseline_policy,
            "regressions": regressions,
        },
    }, advisories


def export_coverage(
    binary: Path,
    profile: Path,
    additional_objects: list[Path],
    additional_profile_directory: Optional[Path],
) -> Any:
    safe_file(binary, "Swift test binary")
    safe_file(profile, "Swift coverage profile")
    for additional in additional_objects:
        safe_file(additional, "additional coverage object")
    with tempfile.TemporaryDirectory(prefix="detach-quality-coverage.") as temporary:
        export_profile = profile
        if additional_profile_directory is not None:
            if (
                not additional_profile_directory.is_dir()
                or additional_profile_directory.is_symlink()
            ):
                raise MetricsError("additional coverage profile directory is missing or unsafe")
            additional_profiles = sorted(
                additional_profile_directory.glob("*.profraw")
            )
            if not additional_profiles:
                raise MetricsError("additional coverage profile directory is empty")
            for additional_profile in additional_profiles:
                safe_file(additional_profile, "additional coverage profile")
            export_profile = Path(temporary) / "combined.profdata"
            run(
                [
                    "xcrun",
                    "llvm-profdata",
                    "merge",
                    "-sparse",
                    str(profile),
                    *(str(path) for path in additional_profiles),
                    "-o",
                    str(export_profile),
                ]
            )
            safe_file(export_profile, "combined coverage profile")
        arguments = ["xcrun", "llvm-cov", "export", str(binary)]
        for additional in additional_objects:
            arguments.extend(("-object", str(additional)))
        arguments.extend(("-instr-profile", str(export_profile)))
        result = run(arguments, text=False)
        try:
            return json.loads(result.stdout.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise MetricsError(f"LLVM coverage export is malformed: {error}") from error


def evaluate(arguments: argparse.Namespace) -> int:
    policy = Policy(POLICY_FILE)
    test_mode = os.environ.get("DETACH_QUALITY_METRICS_TEST_MODE", "0")
    if test_mode not in ("0", "1"):
        raise MetricsError("DETACH_QUALITY_METRICS_TEST_MODE must be 0 or 1")
    if arguments.test_changed_lines and test_mode != "1":
        raise MetricsError("test changed-line evidence is test-only")
    if arguments.coverage_json:
        if arguments.additional_object or arguments.additional_profile_directory:
            raise MetricsError("additional coverage inputs require a test binary")
        coverage_document = read_json(Path(arguments.coverage_json), "LLVM coverage")
        inferred_profile = arguments.coverage_profile or "swift"
    else:
        if not arguments.test_binary or not arguments.profile:
            raise MetricsError("test binary and profile are required")
        additional_objects = [Path(path) for path in arguments.additional_object]
        profile_directory = (
            Path(arguments.additional_profile_directory)
            if arguments.additional_profile_directory
            else None
        )
        if bool(additional_objects) != bool(profile_directory):
            raise MetricsError(
                "additional coverage objects and profile directory must occur together"
            )
        coverage_document = export_coverage(
            Path(arguments.test_binary),
            Path(arguments.profile),
            additional_objects,
            profile_directory,
        )
        inferred_profile = "combined" if additional_objects else "swift"
    coverage_profile = arguments.coverage_profile or inferred_profile
    if not arguments.coverage_json and coverage_profile != inferred_profile:
        raise MetricsError("coverage profile does not match the supplied coverage inputs")
    coverage = collect_coverage(coverage_document)
    tests = collect_tests(Path(arguments.tests))
    baseline_root = Path(arguments.baseline_root) if arguments.baseline_root else None
    baseline, baseline_mode, baseline_commit = load_baseline(
        baseline_root, coverage_profile
    )
    if arguments.authority != "local-diagnostic" and baseline is None:
        raise MetricsError("authoritative quality metrics require last green main evidence")
    base_commit = baseline_commit or arguments.base_commit
    if arguments.base_commit and baseline_commit and arguments.base_commit != baseline_commit:
        raise MetricsError("last green main commit does not match the pull-request base")
    if baseline_commit and test_mode != "1":
        run(["git", "merge-base", "--is-ancestor", baseline_commit, arguments.source_commit])
    changed_override = None
    if arguments.test_changed_lines:
        raw_changed = read_json(Path(arguments.test_changed_lines), "test changed lines")
        if not isinstance(raw_changed, dict):
            raise MetricsError("test changed lines are malformed")
        changed_override = {}
        for path, raw_lines in raw_changed.items():
            if not isinstance(path, str) or not isinstance(raw_lines, list):
                raise MetricsError("test changed lines are malformed")
            changed_override[path] = {
                integer(line, "test changed line") for line in raw_lines
            }
    document, advisories = build_metrics(
        coverage,
        tests,
        policy,
        arguments.source_commit,
        base_commit,
        baseline,
        baseline_mode,
        coverage_profile=coverage_profile,
        changed_override=changed_override,
        allow_incomplete_sources=test_mode == "1",
    )
    validate_metrics(document, expected_policy=policy.version)
    write_json(Path(arguments.output), document)
    if arguments.opportunities_output:
        opportunities = build_opportunities(
            coverage, document, policy, arguments.source_commit
        )
        validate_opportunities(opportunities, expected_policy=policy.version)
        write_json(Path(arguments.opportunities_output), opportunities)
    suites = document["suites"]
    changed = document["changed_lines"]
    print(
        "Quality metrics evaluated: "
        f"profile={coverage_profile}; "
        f"UI tests={suites['ui']['test_count']} coverage={suites['ui']['line_coverage']['percent']:.2f}%; "
        f"business tests={suites['business']['test_count']} "
        f"coverage={suites['business']['line_coverage']['percent']:.2f}%; "
        f"changed={changed['line_coverage']['percent']:.2f}% "
        f"baseline={document['comparison']['mode']}"
    )
    for advisory in advisories:
        print(f"quality-metrics: advisory: {advisory}", file=sys.stderr)
    regressions = document["comparison"]["regressions"]
    if regressions:
        for regression in regressions:
            print(f"quality-metrics: {regression}", file=sys.stderr)
        return 1
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    evaluate_parser = subcommands.add_parser("evaluate")
    source = evaluate_parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--coverage-json")
    source.add_argument("--test-binary")
    evaluate_parser.add_argument("--profile")
    evaluate_parser.add_argument("--additional-object", action="append", default=[])
    evaluate_parser.add_argument("--additional-profile-directory", default="")
    evaluate_parser.add_argument(
        "--coverage-profile", choices=COVERAGE_PROFILES, default=""
    )
    evaluate_parser.add_argument("--tests", required=True)
    evaluate_parser.add_argument("--output", required=True)
    evaluate_parser.add_argument("--opportunities-output", default="")
    evaluate_parser.add_argument("--source-commit", required=True)
    evaluate_parser.add_argument("--base-commit", default="")
    evaluate_parser.add_argument("--baseline-root", default="")
    evaluate_parser.add_argument(
        "--authority",
        choices=("local-diagnostic", "ci-shard", "ci-merge", "ci-main", "release"),
        default="local-diagnostic",
    )
    evaluate_parser.add_argument("--test-changed-lines", default="", help=argparse.SUPPRESS)
    validate_parser = subcommands.add_parser("validate")
    validate_parser.add_argument("path")
    validate_opportunities_parser = subcommands.add_parser("validate-opportunities")
    validate_opportunities_parser.add_argument("path")
    return result


def main(arguments: list[str]) -> int:
    parsed = parser().parse_args(arguments)
    if parsed.command == "evaluate":
        return evaluate(parsed)
    if parsed.command == "validate":
        document = validate_metrics(read_json(Path(parsed.path), "quality metrics"))
        print(
            f"Quality metrics are valid: policy={document['policy']} "
            f"source={document['source_commit']}"
        )
        return 0
    if parsed.command == "validate-opportunities":
        document = validate_opportunities(
            read_json(Path(parsed.path), "coverage opportunities")
        )
        print(
            f"Coverage opportunities are valid: policy={document['policy']} "
            f"source={document['source_commit']}"
        )
        return 0
    raise MetricsError(f"unsupported command: {parsed.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (MetricsError, PolicyError) as error:
        fail(str(error))
