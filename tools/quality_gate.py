#!/usr/bin/env python3
"""Plan, execute, and validate Detach quality-gate evidence."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, NoReturn, TextIO

from quality_policy import POLICY_FILE, Policy, PolicyError
from quality_scenarios import (
    ScenarioError,
    assemble as assemble_scenarios,
    finalize_stage as finalize_scenario_stage,
    record_event as record_scenario_event,
)


ROOT = Path(__file__).resolve().parent.parent
RESULT_HEADER = (
    "policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run\n"
)
VALID_RESULTS = {
    "passed",
    "reused",
    "failed",
    "environment-failed",
    "timeout",
    "interrupted",
    "blocked",
}
FAILURE_RESULTS = {"failed", "environment-failed", "timeout", "interrupted"}
RELEASE_TARGET = re.compile(
    r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v[0-9A-Za-z._+-]+$"
)
SAFE_RUN_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")
NONNEGATIVE_INTEGER = re.compile(r"^[0-9]+$")
EXECUTION_PREREQUISITES = {
    "quality-contracts": ("swift", "ui-e2e"),
    "ui-e2e": ("app",),
    "codex": ("app",),
    "claude": ("app",),
    "tmux-runtime": ("app",),
}
PROVIDER_WAVE = (
    "codex",
    "claude",
)
CONTRACT_WAVE = (
    "tmux-runtime",
    "gate-contract",
)
RELEASE_WAVE = (
    "distribution",
    "release-preflight",
    "publish-preflight",
    "release-workflow",
)


class GateError(Exception):
    """A fail-closed quality-gate contract error."""


class InterruptedRun(Exception):
    """The gate received a terminating signal."""


@dataclass
class Options:
    mode: str
    base: str
    plan: bool
    output_format: str
    explain: bool
    resume: str
    keep_going: bool
    without_release_budget: bool
    list_stages: bool
    stage: str


@dataclass
class StageResult:
    status: str
    duration: int
    log: str
    exit_status: int
    origin_run: str = "-"


@dataclass
class ActiveStage:
    stage: str
    process: subprocess.Popen[bytes]
    log_handle: TextIO
    started_epoch: int
    started_monotonic: float
    timeout: int | None


def fail(message: str) -> NoReturn:
    print(f"quality-gate: {message}", file=sys.stderr)
    raise SystemExit(2)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_private(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)


def write_private_bytes(path: Path, value: bytes) -> None:
    path.write_bytes(value)
    path.chmod(0o600)


def run(
    arguments: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    text: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes] | subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=text,
            check=False,
        )
    except OSError as error:
        raise GateError(f"cannot start {arguments[0]}: {error}") from error
    if check and result.returncode != 0:
        stderr = result.stderr if isinstance(result.stderr, str) else result.stderr.decode(
            "utf-8", "replace"
        )
        stdout = result.stdout if isinstance(result.stdout, str) else result.stdout.decode(
            "utf-8", "replace"
        )
        detail = stderr.strip() or stdout.strip() or f"exit {result.returncode}"
        raise GateError(f"command failed ({' '.join(arguments)}): {detail}")
    return result


def git_bytes(arguments: list[str]) -> bytes:
    result = run(["git", "-C", str(ROOT), *arguments])
    assert isinstance(result.stdout, bytes)
    return result.stdout


def git_text(arguments: list[str]) -> str:
    result = run(["git", "-C", str(ROOT), *arguments], text=True)
    assert isinstance(result.stdout, str)
    return result.stdout.strip()


def parse_name_status(raw: bytes) -> list[tuple[str, str, str | None]]:
    values = raw.split(b"\0")
    if values and values[-1] == b"":
        values.pop()
    entries: list[tuple[str, str, str | None]] = []
    index = 0
    while index < len(values):
        try:
            status = os.fsdecode(values[index])
            path = os.fsdecode(values[index + 1])
        except IndexError as error:
            raise GateError("malformed path entry from Git") from error
        index += 2
        new_path: str | None = None
        if status.startswith(("R", "C")):
            if index >= len(values):
                raise GateError("malformed rename/copy entry from Git")
            new_path = os.fsdecode(values[index])
            index += 1
        entries.append((status, path, new_path))
    return entries


def untracked_paths() -> list[str]:
    raw = git_bytes(["ls-files", "-z", "--others", "--exclude-standard"])
    return [os.fsdecode(value) for value in raw.split(b"\0") if value]


def environment_flag(name: str) -> bool:
    value = os.environ.get(name, "0")
    if value not in ("0", "1"):
        raise GateError(f"{name} must be 0 or 1")
    return value == "1"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="scripts/quality-gate",
        description=(
            "Local modes produce diagnostic evidence. Hosted CI and release modes can "
            "produce authoritative evidence. --stage is a diagnostic rerun only."
        ),
    )
    result.add_argument("--mode", default="change")
    result.add_argument("--base", default="")
    result.add_argument("--plan", action="store_true")
    result.add_argument("--format", dest="output_format", default="text")
    result.add_argument("--explain", action="store_true")
    result.add_argument("--resume", default="")
    result.add_argument("--keep-going", action="store_true")
    result.add_argument("--without-release-budget", action="store_true")
    result.add_argument("--list-stages", action="store_true")
    result.add_argument("--stage", default="")
    return result


def parse_options(arguments: list[str]) -> Options:
    values = parser().parse_args(arguments)
    return Options(
        mode=values.mode,
        base=values.base,
        plan=values.plan,
        output_format=values.output_format,
        explain=values.explain,
        resume=values.resume,
        keep_going=values.keep_going,
        without_release_budget=values.without_release_budget,
        list_stages=values.list_stages,
        stage=values.stage,
    )


class QualityGate:
    def __init__(self, options: Options) -> None:
        self.options = options
        self.policy = Policy(POLICY_FILE)
        assert self.policy.version is not None
        self.policy_version = self.policy.version
        self.all_stages = [stage.name for stage in self.policy.stages]
        self.release_stages = [stage.name for stage in self.policy.stages if stage.release]
        self.test_mode = environment_flag("DETACH_QUALITY_GATE_TEST_MODE")
        self.test_real_static = environment_flag("DETACH_QUALITY_GATE_TEST_REAL_STATIC")
        self.test_direct = environment_flag("DETACH_QUALITY_GATE_TEST_DIRECT")
        self.release_timing_override = os.environ.get("DETACH_RELEASE_TIMING_OVERRIDE", "")
        self.release_timing_override_active = False
        self.authority = ""
        self.resolved_base = ""
        self.source_commit = git_text(["rev-parse", "--verify", "HEAD"])
        self.selected: list[str] = []
        self.specs: list[str] = []
        self.capabilities: list[str] = []
        self.journeys: list[str] = []
        self.explanations: list[str] = []
        self.input_fingerprint = ""
        self.fingerprint = ""
        self.effective_mode = ""
        self.resume_dir: Path | None = None
        self.resume_requested_latest = self.options.resume == "latest"
        result_root = os.environ.get(
            "DETACH_QUALITY_GATE_RESULT_ROOT", str(ROOT / "app/build/quality-gates")
        )
        self.result_root = Path(result_root)
        run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
        self.run_dir = self.result_root / run_id
        self.summary = self.run_dir / "summary.tsv"
        self.manifest = self.run_dir / "manifest.tsv"
        self.junit = self.run_dir / "junit.xml"
        self.markdown = self.run_dir / "summary.md"
        self.environment = self.run_dir / "environment.tsv"
        self.artifacts = self.run_dir / "artifacts.tsv"
        self.release_budget = ROOT / "tests/release-budget.tsv"
        self.started_epoch = int(time.time())
        self.started_at = utc_now()
        self.effective_timing_wall = 0
        self.results: dict[str, StageResult] = {}
        self.active: dict[str, ActiveStage] = {}
        self.reported: set[str] = set()
        self.overall_status = 0
        self.failure_count = 0
        self.prior_manifest: dict[str, str | None] = {}
        self.prior_results: dict[str, StageResult] = {}
        self.scenario_records: list[dict[str, object]] = []

    def validate_options(self) -> None:
        if self.test_real_static and not self.test_mode:
            raise GateError("real static fixture mode is test-only")
        if self.test_direct and not self.test_mode:
            raise GateError("direct fixture mode is test-only")
        if self.options.mode not in ("change", "repository", "release"):
            raise GateError(f"invalid mode: {self.options.mode}")
        requested = os.environ.get("DETACH_QUALITY_AUTHORITY", "")
        if not requested:
            self.authority = (
                "release" if self.options.mode == "release" else "local-diagnostic"
            )
        else:
            self.authority = requested
        if self.authority == "local-diagnostic":
            if self.options.mode == "release":
                raise GateError("release mode requires release authority")
        elif self.authority in ("ci-merge", "ci-main"):
            if os.environ.get("GITHUB_ACTIONS") != "true":
                raise GateError(f"{self.authority} authority is restricted to GitHub Actions")
            if self.options.mode != "repository":
                raise GateError(f"{self.authority} authority requires repository mode")
            if self.options.stage:
                raise GateError(f"{self.authority} authority cannot run one diagnostic stage")
        elif self.authority == "release":
            valid_hosted = (
                os.environ.get("GITHUB_ACTIONS") == "true"
                and self.options.mode == "repository"
            )
            if self.options.mode != "release" and not valid_hosted:
                raise GateError(
                    "release authority requires release mode or repository mode in GitHub Actions"
                )
            if self.options.stage:
                raise GateError("release authority cannot run one diagnostic stage")
        else:
            raise GateError(f"invalid quality authority: {self.authority}")

        if self.release_timing_override:
            if not RELEASE_TARGET.fullmatch(self.release_timing_override):
                raise GateError(
                    "DETACH_RELEASE_TIMING_OVERRIDE must be an exact owner/repository@tag"
                )
            if os.environ.get("DETACH_CONFIRM_RELEASE") != self.release_timing_override:
                raise GateError(
                    "release timing override requires matching exact release confirmation"
                )
            if self.options.mode not in ("release", "repository") or not (
                self.options.without_release_budget
            ):
                raise GateError(
                    "release timing override requires repository or release mode with "
                    "--without-release-budget"
                )
            self.release_timing_override_active = True
        if (
            self.options.without_release_budget
            and os.environ.get("GITHUB_ACTIONS") != "true"
            and not self.test_mode
            and not self.release_timing_override_active
        ):
            raise GateError("--without-release-budget is restricted to GitHub Actions")

        if not self.test_mode:
            clock_names = [
                "DETACH_QUALITY_GATE_TEST_WALL_SECONDS",
                "DETACH_QUALITY_GATE_TEST_CODEX_SECONDS",
            ]
            clock_names.extend(
                "DETACH_QUALITY_GATE_TEST_STAGE_SECONDS_"
                + stage.upper().replace("-", "_")
                for stage in self.all_stages
            )
            if any(os.environ.get(name, "") for name in clock_names):
                raise GateError("quality-gate clock overrides are test-only")
        if self.options.output_format not in ("text", "json"):
            raise GateError(f"invalid format: {self.options.output_format}")
        if self.options.stage and (
            self.options.mode != "change" or self.options.base
        ):
            raise GateError("--stage cannot be combined with another selection")
        if self.options.output_format != "text" and not self.options.plan:
            raise GateError("--format json requires --plan")
        if self.options.explain and not (
            self.options.plan and self.options.output_format == "text"
        ):
            raise GateError("--explain requires a text plan")
        if self.options.resume and (
            self.options.plan or self.options.stage
        ):
            raise GateError("--resume cannot be combined with --plan or --stage")
        if self.options.list_stages and any(
            (
                self.options.plan,
                bool(self.options.stage),
                bool(self.options.base),
                self.options.mode != "change",
                self.options.keep_going,
                bool(self.options.resume),
                self.options.output_format != "text",
                self.options.explain,
            )
        ):
            raise GateError("--list-stages cannot be combined with another option")

    def changed_entries(self) -> list[tuple[str, str, str | None]]:
        entries: list[tuple[str, str, str | None]] = []
        if self.resolved_base:
            entries.extend(
                parse_name_status(
                    git_bytes(
                        [
                            "diff",
                            "--name-status",
                            "-z",
                            "--find-renames",
                            f"{self.resolved_base}...HEAD",
                        ]
                    )
                )
            )
        entries.extend(
            parse_name_status(
                git_bytes(["diff", "--name-status", "-z", "--find-renames", "HEAD"])
            )
        )
        entries.extend(("A", path, None) for path in untracked_paths())
        return entries

    def select_all_impacts(self) -> None:
        self.specs = list(self.policy.specs)
        self.capabilities = list(self.policy.capabilities)
        self.journeys = list(self.policy.journeys)

    def add_stage(self, stage: str, reason: str = "") -> None:
        if stage not in self.selected:
            self.selected.append(stage)
        if reason:
            self.explanations.append(f"{reason} -> {stage}")

    def add_unique(self, values: list[str], value: str) -> None:
        if value and value not in values:
            values.append(value)

    def select_all(self, reason: str = "full repository policy") -> None:
        self.selected = list(self.all_stages)
        self.explanations.extend(f"{reason} -> {stage}" for stage in self.all_stages)
        self.select_all_impacts()

    def select_path(self, path: str, change: str) -> None:
        classification = self.policy.classify(path)
        if classification.status == "unknown":
            print(
                f"quality-gate: unknown impact for {path}; selecting repository gate",
                file=sys.stderr,
            )
            self.select_all(f"{change} unclassified path {path}")
            return
        for stage in classification.stages.split(","):
            self.add_stage(stage, f"{change} {classification.test_domain} domain {path}")
        spec_identifier = next(
            identifier
            for identifier, (spec_path, _) in self.policy.specs.items()
            if spec_path == classification.spec
        )
        self.add_unique(self.specs, spec_identifier)
        for capability in classification.capabilities.split(","):
            self.add_unique(self.capabilities, capability)
        for journey in classification.journeys.split(","):
            self.add_unique(self.journeys, journey)

    def select_plan(self) -> None:
        if self.options.base:
            self.resolved_base = git_text(
                ["rev-parse", "--verify", f"{self.options.base}^{{commit}}"]
            )
        if self.options.stage:
            if self.options.stage not in self.all_stages:
                raise GateError(f"unknown stage: {self.options.stage}")
            self.selected = [self.options.stage]
        elif self.options.mode == "repository":
            self.select_all()
        elif self.options.mode == "release":
            self.selected = list(self.release_stages)
            self.select_all_impacts()
        else:
            for status, path, new_path in self.changed_entries():
                if new_path is not None:
                    self.select_path(path, f"{status} old")
                    self.select_path(new_path, f"{status} new")
                else:
                    self.select_path(path, status)
            if not self.selected:
                print(
                    "quality-gate: no diff to classify; selecting repository gate",
                    file=sys.stderr,
                )
                self.select_all("empty diff fail-safe policy")

        if not self.options.stage:
            changed = True
            while changed:
                changed = False
                for prerequisite, dependent in self.policy.dependencies:
                    if prerequisite in self.selected and dependent not in self.selected:
                        self.add_stage(dependent, f"mandatory {prerequisite} prerequisite")
                        changed = True
        self.selected = [stage for stage in self.all_stages if stage in self.selected]
        if self.options.without_release_budget:
            self.selected = [stage for stage in self.selected if stage != "release-budget"]
        self.effective_mode = "diagnostic" if self.options.stage else self.options.mode
        self.compute_fingerprints()

    def compute_fingerprints(self) -> None:
        digest = hashlib.sha256()
        digest.update(
            (
                f"policy={self.policy_version}\nsource_commit={self.source_commit}\n"
                f"base_commit={self.resolved_base}\n"
            ).encode()
        )
        if self.resolved_base:
            digest.update(
                git_bytes(["diff", "--binary", f"{self.resolved_base}...HEAD"])
            )
        digest.update(git_bytes(["diff", "--binary", "HEAD"]))
        for path in untracked_paths():
            digest.update(b"untracked\0")
            digest.update(os.fsencode(path))
            digest.update(b"\0")
            digest.update(git_bytes(["hash-object", "--", path]))
        self.input_fingerprint = digest.hexdigest()
        fact = (
            f"input={self.input_fingerprint}\nmode={self.effective_mode}\n"
            f"authority={self.authority}\nstages={','.join(self.selected)}\n"
            f"specs={','.join(self.specs)}\n"
            f"capabilities={','.join(self.capabilities)}\n"
            f"journeys={','.join(self.journeys)}\n"
        )
        self.fingerprint = sha256_bytes(fact.encode())

    def print_plan(self) -> None:
        if self.options.output_format == "json":
            document = {
                "policy": self.policy_version,
                "mode": self.effective_mode,
                "authority": self.authority,
                "source_commit": self.source_commit,
                "base_commit": self.resolved_base,
                "input_fingerprint": self.input_fingerprint,
                "fingerprint": self.fingerprint,
                "specs": self.specs,
                "capabilities": self.capabilities,
                "journeys": self.journeys,
                "stages": self.selected,
            }
            print(json.dumps(document, separators=(",", ":"), ensure_ascii=False))
            return
        print(
            f"quality-gate policy={self.policy_version} mode={self.effective_mode} "
            f"authority={self.authority} fingerprint={self.fingerprint} "
            f"stages={','.join(self.selected)} specs={','.join(self.specs)} "
            f"capabilities={','.join(self.capabilities)} "
            f"journeys={','.join(self.journeys)}"
        )
        if self.options.explain:
            for explanation in self.explanations:
                print(f"quality-gate: reason {explanation}")

    def prepare_evidence(self) -> None:
        if self.result_root.exists() and (
            not self.result_root.is_dir() or self.result_root.is_symlink()
        ):
            raise GateError("result root must be a non-symlink directory")
        self.run_dir.mkdir(parents=True, exist_ok=False)
        if not self.run_dir.is_dir() or self.run_dir.is_symlink():
            raise GateError("run path must be a non-symlink directory")
        try:
            self.result_root.chmod(0o700)
            self.run_dir.chmod(0o700)
        except OSError:
            pass
        write_private(self.summary, RESULT_HEADER)
        write_private(self.environment, self.environment_document())
        write_private(self.artifacts, "schema\t1\n")
        (self.run_dir / "scenario-events").mkdir(mode=0o700)
        (self.run_dir / "stage-scenarios").mkdir(mode=0o700)
        self.write_static_files()

    def command_version(self, arguments: list[str], *, first_line: bool = False) -> str:
        result = run(arguments, text=True, check=False)
        assert isinstance(result.stdout, str)
        value = result.stdout.strip()
        if first_line:
            value = value.splitlines()[0] if value else ""
        return value or "unavailable"

    def environment_document(self) -> str:
        if self.test_mode:
            values = {
                "os_product_version": "test",
                "os_build_version": "test",
                "architecture": "test",
                "xcode": "test",
                "swift": "test",
                "github_actions": "false",
            }
        else:
            values = {
                "os_product_version": self.command_version(["sw_vers", "-productVersion"]),
                "os_build_version": self.command_version(["sw_vers", "-buildVersion"]),
                "architecture": self.command_version(["uname", "-m"]),
                "xcode": " ".join(
                    self.command_version(["xcodebuild", "-version"]).splitlines()
                ).rstrip(),
                "swift": self.command_version(["swift", "--version"], first_line=True),
                "github_actions": os.environ.get("GITHUB_ACTIONS", "false"),
            }
        lines = ["schema\t1"]
        lines.extend(f"{key}\t{value}" for key, value in values.items())
        lines.append(
            f"release_timing_override\t{int(self.release_timing_override_active)}"
        )
        lines.append(
            f"managed_sandbox_declared\t{str(bool(os.environ.get('CODEX_SANDBOX'))).lower()}"
        )
        return "\n".join(lines) + "\n"

    def static_paths(self) -> list[str]:
        if self.options.mode != "change" or self.options.stage:
            raw = git_bytes(
                ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
            )
            return [os.fsdecode(value) for value in raw.split(b"\0") if value]
        paths: list[str] = []
        for _, path, new_path in self.changed_entries():
            paths.append(path)
            if new_path is not None:
                paths.append(new_path)
        return paths

    def write_static_files(self) -> None:
        raw = b"".join(os.fsencode(path) + b"\0" for path in self.static_paths())
        write_private_bytes(self.run_dir / "static-files.z", raw)

    def artifact_inventory(self) -> None:
        files: list[Path] = []
        for name in ("quality-metrics.json", "coverage-opportunities.json"):
            evidence = self.run_dir / name
            if evidence.exists():
                files.append(evidence)
        for name in ("scenarios.jsonl", "scenarios.junit.xml", "repair-bundle.json"):
            path = self.run_dir / name
            if path.exists():
                files.append(path)
        for directory_name in (
            "ui-e2e-artifacts",
            "codex-artifacts",
            "claude-artifacts",
            "stage-scenarios",
        ):
            directory = self.run_dir / directory_name
            if directory.is_dir() and not directory.is_symlink():
                files.extend(path for path in directory.iterdir() if path.is_file())
        records = ["schema\t1"]
        for path in sorted(files, key=lambda item: str(item.relative_to(self.run_dir))):
            if not path.is_file() or path.is_symlink():
                raise GateError("diagnostic artifact is missing or unsafe")
            relative = str(path.relative_to(self.run_dir))
            if (
                "\t" in relative
                or "\n" in relative
                or relative.startswith("/")
                or relative.startswith("../")
                or "/../" in relative
            ):
                raise GateError("diagnostic artifact path is unsafe")
            records.append(f"file\t{relative}\t{sha256_file(path)}")
        temporary = self.run_dir / f".artifacts.{os.getpid()}"
        write_private(temporary, "\n".join(records) + "\n")
        os.replace(temporary, self.artifacts)

    def manifest_values(self, path: Path) -> dict[str, str | None]:
        values: dict[str, list[str]] = {}
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise GateError(f"cannot read manifest: {error}") from error
        for line in lines:
            fields = line.split("\t")
            if len(fields) != 2:
                continue
            values.setdefault(fields[0], []).append(fields[1])
        return {
            key: entries[0] if len(entries) == 1 else None
            for key, entries in values.items()
        }

    def write_manifest(self, result: str) -> None:
        if result != "running":
            self.artifact_inventory()
        finished_at = ""
        duration = ""
        summary_digest = ""
        timing_wall = ""
        if result != "running":
            finished_at = utc_now()
            measured = int(time.time()) - self.started_epoch
            duration = str(measured)
            summary_digest = sha256_file(self.summary)
            effective = self.effective_timing_wall or measured
            if effective <= 0:
                effective = measured
            timing_wall = str(effective)
        resumed_from_run = ""
        resumed_from_digest = ""
        if self.resume_dir is not None:
            resumed_from_run = self.resume_dir.name
            resumed_from_digest = sha256_file(self.resume_dir / "manifest.tsv")
        values = (
            ("schema", "4"),
            ("policy", str(self.policy_version)),
            ("mode", self.effective_mode),
            ("authority", self.authority),
            ("source_commit", self.source_commit),
            ("base_commit", self.resolved_base),
            ("input_fingerprint", self.input_fingerprint),
            ("fingerprint", self.fingerprint),
            ("stages", ",".join(self.selected)),
            ("specs", ",".join(self.specs)),
            ("capabilities", ",".join(self.capabilities)),
            ("journeys", ",".join(self.journeys)),
            ("started_at", self.started_at),
            ("finished_at", finished_at),
            ("duration_seconds", duration),
            ("timing_wall_seconds", timing_wall),
            ("resumed_from_run", resumed_from_run),
            ("resumed_from_manifest_sha256", resumed_from_digest),
            ("environment_sha256", sha256_file(self.environment)),
            ("artifacts_sha256", sha256_file(self.artifacts)),
            ("summary_sha256", summary_digest),
            ("result", result),
        )
        temporary = self.run_dir / f".manifest.{os.getpid()}"
        write_private(temporary, "".join(f"{key}\t{value}\n" for key, value in values))
        os.replace(temporary, self.manifest)

    def stage_in_csv(self, stage: str, value: str | None) -> bool:
        return value is not None and stage in value.split(",")

    def parse_summary(
        self, path: Path, prior_stages: str, prior_mode: str
    ) -> dict[str, StageResult]:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise GateError(f"cannot read resume summary: {error}") from error
        if not lines or lines[0] != RESULT_HEADER.rstrip("\n"):
            raise GateError("resume summary has an invalid schema")
        results: dict[str, StageResult] = {}
        invalid_records = False
        for line in lines[1:]:
            fields = line.split("\t")
            if len(fields) != 8:
                invalid_records = True
                continue
            policy, mode, stage, status, duration, log, log_digest, origin = fields
            if (
                policy != str(self.policy_version)
                or mode != prior_mode
                or stage in results
            ):
                invalid_records = True
                continue
            if stage not in self.all_stages:
                raise GateError(f"resume summary contains unknown stage: {stage}")
            if not self.stage_in_csv(stage, prior_stages):
                raise GateError(f"resume summary contains unplanned stage: {stage}")
            if status not in VALID_RESULTS:
                raise GateError(f"resume summary contains invalid status: {status}")
            if not NONNEGATIVE_INTEGER.fullmatch(duration):
                raise GateError(f"resume summary contains invalid duration: {stage}")
            if log == "-":
                if log_digest != "-":
                    raise GateError(f"resume summary has a digest without a log: {stage}")
                if status in ("passed", "reused"):
                    raise GateError(f"resume summary has no log for reusable stage: {stage}")
            else:
                if "/" in log or log in (".", ".."):
                    raise GateError(f"resume summary contains an unsafe log path: {stage}")
                log_path = path.parent / log
                if not log_path.is_file() or log_path.is_symlink():
                    raise GateError(f"resume summary log is missing or unsafe: {stage}")
                if sha256_file(log_path) != log_digest:
                    raise GateError(f"resume summary log digest does not match: {stage}")
            if origin != "-" and not SAFE_RUN_NAME.fullmatch(origin):
                raise GateError(f"resume summary contains an unsafe origin: {stage}")
            results[stage] = StageResult(status, int(duration), log, 0, origin)
        if invalid_records:
            raise GateError("resume summary contains invalid or duplicate stage records")
        return results

    def latest_resume(self) -> Path:
        if not self.result_root.is_dir():
            raise GateError("no previous quality-gate evidence exists")
        for candidate in sorted(self.result_root.iterdir(), reverse=True):
            if candidate == self.run_dir or not candidate.is_dir():
                continue
            manifest = candidate / "manifest.tsv"
            if not manifest.is_file() or manifest.is_symlink():
                continue
            values = self.manifest_values(manifest)
            if (
                values.get("schema") != "4"
                or values.get("policy") != str(self.policy_version)
                or values.get("authority") != self.authority
                or values.get("source_commit") != self.source_commit
                or values.get("base_commit") != self.resolved_base
                or values.get("input_fingerprint") != self.input_fingerprint
                or values.get("result") not in ("passed", "failed", "interrupted")
                or not all(
                    self.stage_in_csv(stage, values.get("stages"))
                    for stage in self.selected
                )
            ):
                continue
            print(f"quality-gate: selected latest compatible evidence {candidate}")
            return candidate
        raise GateError("no compatible previous quality-gate evidence exists")

    def validate_resume(self) -> None:
        if not self.options.resume:
            return
        self.resume_dir = (
            self.latest_resume() if self.resume_requested_latest else Path(self.options.resume)
        )
        resume = self.resume_dir
        if not resume.is_dir() or resume.is_symlink():
            raise GateError("resume path must be a non-symlink run directory")
        required = {
            "manifest.tsv": "resume manifest is missing or unsafe",
            "summary.tsv": "resume summary is missing or unsafe",
            "environment.tsv": "resume environment evidence is missing or unsafe",
            "artifacts.tsv": "resume artifact evidence is missing or unsafe",
        }
        for name, message in required.items():
            path = resume / name
            if not path.is_file() or path.is_symlink():
                raise GateError(message)
        values = self.manifest_values(resume / "manifest.tsv")
        self.prior_manifest = values
        checks = (
            ("schema", "4", "resume evidence schema is unsupported"),
            ("policy", str(self.policy_version), "resume evidence uses another policy version"),
            ("authority", self.authority, "resume evidence uses another authority"),
            ("source_commit", self.source_commit, "resume evidence uses another source commit"),
            ("base_commit", self.resolved_base, "resume evidence uses another base commit"),
            (
                "input_fingerprint",
                self.input_fingerprint,
                "resume evidence does not match the current input",
            ),
        )
        for key, expected, message in checks:
            if values.get(key) != expected:
                raise GateError(message)
        if sha256_file(resume / "environment.tsv") != values.get("environment_sha256"):
            raise GateError("resume environment digest does not match its manifest")
        if sha256_file(resume / "artifacts.tsv") != values.get("artifacts_sha256"):
            raise GateError("resume artifact inventory digest does not match its manifest")
        artifact_lines = (resume / "artifacts.tsv").read_text(encoding="utf-8").splitlines()
        if not artifact_lines or artifact_lines[0] != "schema\t1":
            raise GateError("resume artifact inventory schema is invalid")
        for line in artifact_lines[1:]:
            fields = line.split("\t")
            if len(fields) != 3 or fields[0] != "file":
                raise GateError("resume artifact inventory contains an unknown record")
            _, relative, expected_digest = fields
            if (
                relative.startswith("/")
                or relative.startswith("../")
                or "/../" in relative
                or "\n" in relative
                or "\t" in relative
            ):
                raise GateError("resume artifact inventory path is unsafe")
            if not (
                relative == "quality-metrics.json"
                or relative == "coverage-opportunities.json"
                or relative == "scenarios.jsonl"
                or relative == "scenarios.junit.xml"
                or relative == "repair-bundle.json"
                or relative.startswith("stage-scenarios/")
                or relative.startswith("ui-e2e-artifacts/")
                or relative.startswith("codex-artifacts/")
                or relative.startswith("claude-artifacts/")
            ):
                raise GateError("resume artifact inventory path is unapproved")
            if not DIGEST.fullmatch(expected_digest):
                raise GateError("resume artifact inventory digest is invalid")
            artifact = resume / relative
            if not artifact.is_file() or artifact.is_symlink():
                raise GateError("resume diagnostic artifact is missing or unsafe")
            if sha256_file(artifact) != expected_digest:
                raise GateError("resume diagnostic artifact digest does not match")
        timing_wall = values.get("timing_wall_seconds")
        if timing_wall is None or not NONNEGATIVE_INTEGER.fullmatch(timing_wall):
            raise GateError("resume evidence timing wall duration is invalid")

        chain_dir = resume
        seen = {chain_dir.name}
        while True:
            chain = self.manifest_values(chain_dir / "manifest.tsv")
            parent = chain.get("resumed_from_run")
            parent_digest = chain.get("resumed_from_manifest_sha256")
            if not parent:
                if parent_digest:
                    raise GateError("resume evidence has a parent digest without a parent run")
                break
            if not SAFE_RUN_NAME.fullmatch(parent):
                raise GateError("resume evidence parent run is unsafe")
            if parent in seen:
                raise GateError("resume evidence parent chain contains a cycle")
            if parent_digest is None or not DIGEST.fullmatch(parent_digest):
                raise GateError("resume evidence parent digest is invalid")
            parent_manifest = chain_dir.parent / parent / "manifest.tsv"
            if not parent_manifest.is_file() or parent_manifest.is_symlink():
                raise GateError("resume evidence parent manifest is missing or unsafe")
            if sha256_file(parent_manifest) != parent_digest:
                raise GateError("resume evidence parent manifest digest does not match")
            parent_values = self.manifest_values(parent_manifest)
            parent_checks = (
                ("schema", "4", "resume evidence parent schema is unsupported"),
                ("policy", str(self.policy_version), "resume evidence parent policy does not match"),
                ("authority", self.authority, "resume evidence parent authority does not match"),
                (
                    "source_commit",
                    self.source_commit,
                    "resume evidence parent source commit does not match",
                ),
                (
                    "base_commit",
                    self.resolved_base,
                    "resume evidence parent base commit does not match",
                ),
                (
                    "input_fingerprint",
                    self.input_fingerprint,
                    "resume evidence parent input does not match",
                ),
            )
            for key, expected, message in parent_checks:
                if parent_values.get(key) != expected:
                    raise GateError(message)
            seen.add(parent)
            chain_dir = chain_dir.parent / parent

        if values.get("result") not in ("passed", "failed", "interrupted"):
            raise GateError("resume evidence is not from a completed run")
        prior_stages = values.get("stages") or ""
        prior_mode = values.get("mode") or ""
        if sha256_file(resume / "summary.tsv") != values.get("summary_sha256"):
            raise GateError("resume summary digest does not match its manifest")
        for stage in self.selected:
            if not self.stage_in_csv(stage, prior_stages):
                raise GateError(f"resume evidence does not cover selected stage: {stage}")
        self.prior_results = self.parse_summary(
            resume / "summary.tsv", prior_stages, prior_mode
        )

    def stage_result_path(self, stage: str) -> Path:
        return self.run_dir / f".stage-{stage}.result"

    def record_result(
        self,
        stage: str,
        result: StageResult,
        *,
        scenario_source: Path | None = None,
    ) -> None:
        scenario_output = self.run_dir / "stage-scenarios" / f"{stage}.jsonl"
        if scenario_source is not None:
            if not scenario_source.is_file() or scenario_source.is_symlink():
                raise GateError(f"reused scenario evidence is missing or unsafe: {stage}")
            shutil.copyfile(scenario_source, scenario_output)
            scenario_output.chmod(0o600)
        else:
            errors = finalize_scenario_stage(
                policy=self.policy,
                stage=stage,
                stage_status=result.status,
                stage_duration_seconds=result.duration,
                stage_log=result.log,
                event_path=self.run_dir / "scenario-events" / f"{stage}.jsonl",
                output_path=scenario_output,
            )
            if errors and result.status in ("passed", "reused"):
                log = result.log
                if log == "-":
                    log = f"{stage}.log"
                    write_private(self.run_dir / log, "")
                with (self.run_dir / log).open("a", encoding="utf-8") as output:
                    for error in errors:
                        output.write(f"scenario evidence: {error}\n")
                result = StageResult("failed", result.duration, log, 1, result.origin_run)
        self.results[stage] = result
        write_private(
            self.stage_result_path(stage),
            (
                f"{result.status}\t{result.duration}\t{result.log}\t"
                f"{result.exit_status}\t{result.origin_run}\n"
            ),
        )

    def reusable(self, stage: str) -> bool:
        result = self.prior_results.get(stage)
        if stage == "ui-e2e" and "quality-contracts" in self.selected:
            metrics = self.prior_results.get("quality-contracts")
            if metrics is None or metrics.status not in ("passed", "reused"):
                return False
        return result is not None and result.status in ("passed", "reused")

    def prerequisite_failed(self, stage: str) -> bool:
        prerequisites = EXECUTION_PREREQUISITES.get(stage)
        if prerequisites is None:
            return False
        return any(
            self.results.get(prerequisite) is not None
            and self.results[prerequisite].status in (
                "failed",
                "environment-failed",
                "timeout",
                "interrupted",
                "blocked",
            )
            for prerequisite in prerequisites
        )

    def timeout_for_stage(self, stage: str) -> int:
        suffix = stage.upper().replace("-", "_")
        value = os.environ.get(
            f"DETACH_QUALITY_GATE_TIMEOUT_{suffix}",
            os.environ.get(
                "DETACH_QUALITY_GATE_TIMEOUT",
                str(self.policy.stages_by_name[stage].timeout),
            ),
        )
        if not POSITIVE_INTEGER.fullmatch(value):
            raise GateError(f"timeout for {stage} must be a positive integer")
        return int(value)

    def stage_environment(self, stage: str) -> dict[str, str]:
        environment = os.environ.copy()
        for name in (
            "DETACH_RELEASE_TIMING_OVERRIDE",
            "DETACH_CONFIRM_RELEASE",
            "DETACH_RELEASE_IGNORE_TIMING",
            "DETACH_VERSION",
            "DETACH_BUILD_VERSION",
            "DETACH_BUILD_ARCHS",
            "DETACH_CODESIGN_IDENTITY",
            "DETACH_RELEASE_BUILD",
            "DETACH_SPARKLE_VERSION",
            "DETACH_SPARKLE_FEED_URL",
            "DETACH_SPARKLE_PUBLIC_ED_KEY",
            "DETACH_DOWNLOAD_URL",
        ):
            environment.pop(name, None)
        module_cache = ROOT / "app/.build/module-cache"
        module_cache.mkdir(parents=True, exist_ok=True)
        environment.update(
            {
                "CLANG_MODULE_CACHE_PATH": str(module_cache),
                "SWIFTPM_MODULECACHE_OVERRIDE": str(module_cache),
                "DETACH_QUALITY_GATE_ROOT": str(ROOT),
                "DETACH_QUALITY_GATE_RUN_DIR": str(self.run_dir),
                "DETACH_QUALITY_GATE_SOURCE_COMMIT": self.source_commit,
                "DETACH_QUALITY_GATE_AUTHORITY": self.authority,
                "DETACH_QUALITY_GATE_RESOLVED_BASE": self.resolved_base,
                "DETACH_QUALITY_GATE_MODE": self.options.mode,
                "DETACH_QUALITY_GATE_DIAGNOSTIC_STAGE": self.options.stage,
                "DETACH_QUALITY_GATE_SELECTED_STAGES": ",".join(self.selected),
                "DETACH_QUALITY_GATE_TEST_MODE": str(int(self.test_mode)),
                "DETACH_QUALITY_GATE_TEST_REAL_STATIC": str(
                    int(self.test_real_static)
                ),
                "DETACH_QUALITY_SCENARIO_STAGE": stage,
                "DETACH_QUALITY_SCENARIO_EVENTS": str(
                    self.run_dir / "scenario-events" / f"{stage}.jsonl"
                ),
            }
        )
        if not self.test_direct:
            environment["DETACH_RELEASE_TESTS_DETACHED"] = "1"
        return environment

    def launch(self, stage: str) -> None:
        if stage not in self.selected or stage in self.results or stage in self.active:
            return
        if self.reusable(stage):
            assert self.resume_dir is not None
            prior = self.prior_results[stage]
            print(f"quality-gate: reusing {stage} from matching evidence {self.resume_dir}")
            origin = prior.origin_run if prior.origin_run != "-" else self.resume_dir.name
            reused_log = "-"
            if prior.log != "-":
                reused_log = f"{stage}.reused.log"
                shutil.copyfile(self.resume_dir / prior.log, self.run_dir / reused_log)
                (self.run_dir / reused_log).chmod(0o600)
            if stage == "quality-contracts":
                metrics = self.resume_dir / "quality-metrics.json"
                if not metrics.is_file() or metrics.is_symlink():
                    raise GateError(
                        "reused quality-contracts evidence has no safe quality metrics"
                    )
                shutil.copyfile(metrics, self.run_dir / "quality-metrics.json")
                (self.run_dir / "quality-metrics.json").chmod(0o600)
                opportunities = self.resume_dir / "coverage-opportunities.json"
                if not opportunities.is_file() or opportunities.is_symlink():
                    raise GateError(
                        "reused quality-contracts evidence has no safe coverage opportunities"
                    )
                shutil.copyfile(
                    opportunities, self.run_dir / "coverage-opportunities.json"
                )
                (self.run_dir / "coverage-opportunities.json").chmod(0o600)
            self.record_result(
                stage,
                StageResult("reused", prior.duration, reused_log, 0, origin),
                scenario_source=self.resume_dir / "stage-scenarios" / f"{stage}.jsonl",
            )
            return
        if self.prerequisite_failed(stage):
            print(
                f"quality-gate: blocking {stage} because its prerequisite failed",
                file=sys.stderr,
            )
            self.record_result(stage, StageResult("blocked", 0, "-", 0))
            return
        timeout = self.timeout_for_stage(stage)
        print(f"quality-gate: running {stage} (timeout {timeout}s)", flush=True)
        log_path = self.run_dir / f"{stage}.log"
        log_handle = log_path.open("w", encoding="utf-8")
        log_path.chmod(0o600)
        try:
            process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "__run-stage", stage],
                cwd=ROOT,
                env=self.stage_environment(stage),
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as error:
            log_handle.close()
            raise GateError(f"cannot start stage {stage}: {error}") from error
        started_epoch = int(time.time())
        write_private(self.run_dir / f".stage-{stage}.started", f"{started_epoch}\n")
        write_private(self.run_dir / f".stage-{stage}.pid", f"{process.pid}\n")
        self.active[stage] = ActiveStage(
            stage,
            process,
            log_handle,
            started_epoch,
            time.monotonic(),
            None if self.test_direct else timeout,
        )

    def terminate_active(self, active: ActiveStage, *, force: bool = False) -> None:
        try:
            os.killpg(active.process.pid, signal.SIGKILL if force else signal.SIGTERM)
        except ProcessLookupError:
            pass

    def finish_active(self, stage: str, *, timed_out: bool = False) -> None:
        active = self.active.pop(stage)
        status = active.process.returncode
        if status is None:
            status = active.process.wait()
        active.log_handle.close()
        (self.run_dir / f".stage-{stage}.pid").unlink(missing_ok=True)
        duration = max(0, int(time.time()) - active.started_epoch)
        result = "passed"
        exit_status = status if status >= 0 else 128 + abs(status)
        if timed_out:
            result = "timeout"
            exit_status = 124
        elif status != 0:
            result = "failed"
            log = (self.run_dir / f"{stage}.log").read_text(
                encoding="utf-8", errors="replace"
            )
            if re.search(
                r"error creating .+\.sock \(Operation not permitted\)|"
                r"sandbox\S* denied|deny\(1\)",
                log,
            ):
                result = "environment-failed"
        self.record_result(
            stage, StageResult(result, duration, f"{stage}.log", exit_status)
        )

    def poll_active(self) -> None:
        now = time.monotonic()
        for stage, active in list(self.active.items()):
            status = active.process.poll()
            if status is not None:
                self.finish_active(stage)
                continue
            if active.timeout is not None and now - active.started_monotonic >= active.timeout:
                self.terminate_active(active)
                try:
                    active.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.terminate_active(active, force=True)
                    active.process.wait()
                self.finish_active(stage, timed_out=True)

    def wait_for(self, stages: Iterable[str]) -> None:
        wanted = {stage for stage in stages if stage in self.selected}
        while any(stage not in self.results for stage in wanted):
            self.poll_active()
            if any(stage not in self.results for stage in wanted):
                time.sleep(0.05)
        for stage in stages:
            if stage in self.results:
                self.report(stage)

    def budget_values(self) -> dict[str, str | None]:
        if not self.release_budget.is_file() or self.release_budget.is_symlink():
            raise GateError("release budget is missing or unsafe")
        values: dict[str, list[str]] = {}
        for line in self.release_budget.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) == 2:
                values.setdefault(fields[0], []).append(fields[1])
        return {
            key: items[0] if len(items) == 1 else None
            for key, items in values.items()
        }

    def stage_budget_override(self, stage: str) -> str:
        suffix = stage.upper().replace("-", "_")
        value = os.environ.get(
            f"DETACH_QUALITY_GATE_TEST_STAGE_SECONDS_{suffix}", ""
        )
        if not value and stage == "codex":
            value = os.environ.get("DETACH_QUALITY_GATE_TEST_CODEX_SECONDS", "")
        return value

    def enforce_stage_budget(self, stage: str) -> None:
        if (
            self.options.without_release_budget
            or stage == "release-budget"
            or "release-budget" in self.selected
        ):
            return
        result = self.results[stage]
        if result.status not in ("passed", "reused"):
            return
        override = self.stage_budget_override(stage)
        if self.test_mode and not override:
            return
        measured = override or str(result.duration)
        if not NONNEGATIVE_INTEGER.fullmatch(measured):
            raise GateError(f"stage duration must be a non-negative integer: {stage}")
        key = f"stage_{stage.replace('-', '_')}_seconds_max"
        maximum = self.budget_values().get(key)
        if maximum is None:
            raise GateError(f"release stage budget is missing or duplicated: {stage}")
        if not POSITIVE_INTEGER.fullmatch(maximum):
            raise GateError(f"release stage budget must be a positive integer: {stage}")
        if int(measured) > int(maximum):
            log = result.log
            if log == "-":
                log = f"{stage}.log"
                write_private(self.run_dir / log, "")
            with (self.run_dir / log).open("a", encoding="utf-8") as output:
                output.write(
                    f"stage budget: {stage} regressed: {measured}s > {maximum}s\n"
                )
            self.record_result(
                stage,
                StageResult("failed", int(measured), log, 1, result.origin_run),
            )

    def report(self, stage: str) -> None:
        if stage in self.reported:
            return
        self.enforce_stage_budget(stage)
        result = self.results[stage]
        if result.status in ("failed", "environment-failed", "timeout"):
            if result.log != "-":
                sys.stdout.write(
                    (self.run_dir / result.log).read_text(
                        encoding="utf-8", errors="replace"
                    )
                )
            print(
                f"quality-gate: {stage} {result.status}; diagnostic rerun: "
                f"scripts/quality-gate --stage {stage}",
                file=sys.stderr,
            )
            print(
                f"quality-gate: readiness evidence is incomplete; log: "
                f"{self.run_dir / result.log}",
                file=sys.stderr,
            )
            self.overall_status = result.exit_status or 1
            self.failure_count += 1
        else:
            print(
                f"quality-gate: {stage} {result.status} "
                f"({result.duration}s; log={result.log})"
            )
        self.reported.add(stage)

    def evaluate_release_budget(self) -> None:
        if "release-budget" not in self.selected:
            return
        for stage in self.selected:
            if stage == "release-budget":
                continue
            result = self.results.get(stage)
            if result is None or result.status not in ("passed", "reused"):
                print(
                    f"quality-gate: blocking release-budget because {stage} is not passed",
                    file=sys.stderr,
                )
                self.record_result(
                    "release-budget", StageResult("blocked", 0, "-", 0)
                )
                return
        values = self.budget_values()
        if values.get("schema") != "2":
            raise GateError("release budget schema is unsupported")
        raw_elapsed = os.environ.get(
            "DETACH_QUALITY_GATE_TEST_WALL_SECONDS",
            str(int(time.time()) - self.started_epoch),
        )
        if not NONNEGATIVE_INTEGER.fullmatch(raw_elapsed):
            raise GateError("test wall duration must be a non-negative integer")
        elapsed = int(raw_elapsed)
        inherited = 0
        if self.resume_dir is not None:
            raw_inherited = self.prior_manifest.get("timing_wall_seconds")
            if raw_inherited is None or not NONNEGATIVE_INTEGER.fullmatch(raw_inherited):
                raise GateError("resume timing wall duration is invalid")
            inherited = int(raw_inherited)
        self.effective_timing_wall = max(elapsed, inherited)
        wall_maximum = values.get("wall_seconds_max")
        if wall_maximum is None:
            raise GateError("release wall budget is missing or duplicated")
        if not POSITIVE_INTEGER.fullmatch(wall_maximum):
            raise GateError("release wall budget must be a positive integer")
        lines = [
            f"invocation_wall_seconds\t{elapsed}",
            f"inherited_wall_seconds\t{inherited}",
            f"effective_wall_seconds\t{self.effective_timing_wall}\tmax\t{wall_maximum}",
        ]
        result = "passed"
        exit_status = 0
        if self.effective_timing_wall > int(wall_maximum):
            lines.append(
                f"release budget: wall time regressed: {self.effective_timing_wall}s > "
                f"{wall_maximum}s"
            )
            result = "failed"
            exit_status = 1
        for stage in self.selected:
            if stage == "release-budget":
                continue
            stage_result = self.results[stage]
            override = self.stage_budget_override(stage)
            duration = override or str(stage_result.duration)
            if not NONNEGATIVE_INTEGER.fullmatch(duration):
                raise GateError(f"stage duration must be a non-negative integer: {stage}")
            key = f"stage_{stage.replace('-', '_')}_seconds_max"
            maximum = values.get(key)
            if maximum is None:
                raise GateError(f"release stage budget is missing or duplicated: {stage}")
            if not POSITIVE_INTEGER.fullmatch(maximum):
                raise GateError(f"release stage budget must be a positive integer: {stage}")
            lines.append(f"{stage}_seconds\t{duration}\tmax\t{maximum}")
            if self.test_mode and not override:
                continue
            if int(duration) > int(maximum):
                lines.append(
                    f"release budget: {stage} regressed: {duration}s > {maximum}s"
                )
                result = "failed"
                exit_status = 1
        if result == "passed":
            lines.append(
                f"Release budget passed: wall={self.effective_timing_wall}s "
                f"max={wall_maximum}s"
            )
        write_private(self.run_dir / "release-budget.log", "\n".join(lines) + "\n")
        self.record_result(
            "release-budget",
            StageResult(result, 0, "release-budget.log", exit_status),
        )

    def assemble_summary(self) -> None:
        for stage in self.selected:
            if stage not in self.results:
                log = f"{stage}.log"
                log_path = self.run_dir / log
                if not log_path.exists():
                    write_private(log_path, "")
                self.record_result(
                    stage, StageResult("interrupted", 0, log, 130)
                )
        lines = [RESULT_HEADER.rstrip("\n")]
        for stage in self.selected:
            result = self.results[stage]
            log_digest = "-"
            if result.log != "-":
                log_path = self.run_dir / result.log
                if not log_path.is_file() or log_path.is_symlink():
                    raise GateError(f"stage log is missing or unsafe: {stage}")
                log_digest = sha256_file(log_path)
            lines.append(
                "\t".join(
                    (
                        str(self.policy_version),
                        self.options.mode,
                        stage,
                        result.status,
                        str(result.duration),
                        result.log,
                        log_digest,
                        result.origin_run,
                    )
                )
            )
        write_private(self.summary, "\n".join(lines) + "\n")

    def write_scenario_outputs(self) -> None:
        self.scenario_records = assemble_scenarios(
            stage_paths=(
                self.run_dir / "stage-scenarios" / f"{stage}.jsonl"
                for stage in self.selected
            ),
            output_jsonl=self.run_dir / "scenarios.jsonl",
            output_junit=self.run_dir / "scenarios.junit.xml",
            repair_bundle=self.run_dir / "repair-bundle.json",
            run_dir=self.run_dir,
            expected_stages=self.selected,
        )
        event_directory = self.run_dir / "scenario-events"
        if not event_directory.is_dir() or event_directory.is_symlink():
            raise GateError("scenario event directory is missing or unsafe")
        shutil.rmtree(event_directory)

    def write_junit(self) -> None:
        tests = len(self.selected)
        failures = sum(
            self.results[stage].status in FAILURE_RESULTS for stage in self.selected
        )
        skipped = sum(
            self.results[stage].status in ("reused", "blocked")
            for stage in self.selected
        )
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            (
                f'<testsuite name="detach-quality-gate" tests="{tests}" '
                f'failures="{failures}" skipped="{skipped}">'
            ),
        ]
        for stage in self.selected:
            result = self.results[stage]
            body = ""
            if result.status in FAILURE_RESULTS:
                body = (
                    f'<failure message="{html.escape(result.status, quote=True)}">'
                    f"See {html.escape(result.log, quote=True)}</failure>"
                )
            elif result.status == "reused":
                body = '<skipped message="reused matching passed evidence"/>'
            elif result.status == "blocked":
                body = '<skipped message="prerequisite failed"/>'
            lines.append(
                f'  <testcase classname="quality-gate" '
                f'name="{html.escape(stage, quote=True)}" time="{result.duration}">'
                f"{body}</testcase>"
            )
        lines.append("</testsuite>")
        write_private(self.junit, "\n".join(lines) + "\n")

    def write_markdown(self) -> None:
        specs = ",".join(self.specs) or "-"
        capabilities = ",".join(self.capabilities) or "-"
        journeys = ",".join(self.journeys) or "-"
        lines = [
            "# Quality gate",
            "",
            f"- Policy: `{self.policy_version}`",
            f"- Mode: `{self.effective_mode}`",
            f"- Authority: `{self.authority}`",
            f"- Source: `{self.source_commit}`",
            f"- Fingerprint: `{self.fingerprint}`",
            "",
            f"- Specifications: `{specs}`",
            f"- Capabilities: `{capabilities}`",
            f"- Journeys: `{journeys}`",
            "",
            "| Stage | Status | Seconds | Log | Origin |",
            "| --- | --- | ---: | --- | --- |",
        ]
        for stage in self.selected:
            result = self.results[stage]
            lines.append(
                f"| `{stage}` | {result.status} | {result.duration} | "
                f"`{result.log}` | `{result.origin_run}` |"
            )
        lines.extend(
            [
                "",
                "## Scenarios",
                "",
                "| Scenario | Stage | Status | Granularity | Milliseconds | Rerun |",
                "| --- | --- | --- | --- | ---: | --- |",
            ]
        )
        for record in self.scenario_records:
            lines.append(
                f"| `{record['id']}` | `{record['stage']}` | {record['status']} | "
                f"{record['granularity']} | {record['duration_ms']} | `{record['rerun']}` |"
            )
        write_private(self.markdown, "\n".join(lines) + "\n")

    def interrupt(self) -> NoReturn:
        for active in list(self.active.values()):
            self.terminate_active(active)
        for stage, active in list(self.active.items()):
            try:
                active.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.terminate_active(active, force=True)
                active.process.wait()
            active.log_handle.close()
            (self.run_dir / f".stage-{stage}.pid").unlink(missing_ok=True)
            duration = max(0, int(time.time()) - active.started_epoch)
            self.record_result(
                stage, StageResult("interrupted", duration, f"{stage}.log", 130)
            )
        self.active.clear()
        for stage in self.selected:
            if stage not in self.results:
                self.record_result(stage, StageResult("interrupted", 0, "-", 130))
        self.assemble_summary()
        self.write_scenario_outputs()
        self.write_manifest("interrupted")
        self.write_junit()
        self.write_markdown()
        print(
            f"quality-gate: interrupted; evidence is incomplete ({self.summary})",
            file=sys.stderr,
        )
        raise SystemExit(130)

    def execute(self) -> int:
        self.validate_options()
        if self.options.list_stages:
            print("\n".join(self.all_stages))
            return 0
        self.select_plan()
        self.print_plan()
        if self.options.plan:
            return 0
        self.prepare_evidence()
        self.validate_resume()
        self.write_manifest("running")

        def signal_handler(_signum: int, _frame: object) -> None:
            raise InterruptedRun

        previous_handlers = {
            signum: signal.signal(signum, signal_handler)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        try:
            self.launch("static")
            self.wait_for(("static",))
            self.launch("swift")
            self.wait_for(("swift",))
            self.launch("app")
            self.wait_for(("app",))
            self.launch("ui-e2e")
            self.wait_for(("ui-e2e",))
            self.launch("quality-contracts")
            self.wait_for(("quality-contracts",))
            for stage in PROVIDER_WAVE:
                self.launch(stage)
            self.wait_for(PROVIDER_WAVE)
            for stage in CONTRACT_WAVE:
                self.launch(stage)
            self.wait_for(CONTRACT_WAVE)
            for stage in RELEASE_WAVE:
                self.launch(stage)
            self.wait_for(RELEASE_WAVE)
            for stage in self.selected:
                if stage != "release-budget":
                    self.wait_for((stage,))
            self.evaluate_release_budget()
            self.wait_for(("release-budget",))
        except InterruptedRun:
            self.interrupt()
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)

        self.assemble_summary()
        self.write_scenario_outputs()
        self.write_junit()
        self.write_markdown()
        if self.overall_status:
            self.write_manifest("failed")
            label = "DIAGNOSTIC FAIL" if self.authority == "local-diagnostic" else "FAIL"
            print(
                f"quality-gate: {label} policy={self.policy_version} "
                f"authority={self.authority} fingerprint={self.fingerprint} "
                f"failures={self.failure_count} evidence={self.summary} "
                f"junit={self.junit} markdown={self.markdown}",
                file=sys.stderr,
            )
            return self.overall_status
        if self.options.stage:
            self.write_manifest("diagnostic")
            print("quality-gate: diagnostic stage passed; this is not readiness evidence")
            return 0
        self.write_manifest("passed")
        label = "DIAGNOSTIC PASS" if self.authority == "local-diagnostic" else "PASS"
        print(
            f"quality-gate: {label} policy={self.policy_version} authority={self.authority} "
            f"fingerprint={self.fingerprint} evidence={self.summary} junit={self.junit} "
            f"markdown={self.markdown}"
        )
        return 0


def child_run(arguments: list[str], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> int:
    try:
        process = subprocess.run(arguments, cwd=cwd, env=env, check=False)
    except OSError as error:
        print(f"quality-gate stage: cannot start {arguments[0]}: {error}", file=sys.stderr)
        return 2
    return process.returncode


def run_static_stage(root: Path, run_dir: Path, mode: str, resolved_base: str) -> int:
    static_file = run_dir / "static-files.z"
    try:
        paths = [
            os.fsdecode(value)
            for value in static_file.read_bytes().split(b"\0")
            if value
        ]
    except OSError as error:
        print(f"quality-gate stage: cannot read static file list: {error}", file=sys.stderr)
        return 2
    shell_names = {
        "bin/detach",
        "bin/detach-core",
        "scripts/quality-gate",
        "scripts/quality-scenarios",
        "scripts/quality-policy",
        "scripts/quality-metrics",
        "scripts/quality-mutation",
        "scripts/quality-baseline",
        "scripts/quality-promote",
        "scripts/quality-history",
        "scripts/quality-care",
        "scripts/release-version",
        "scripts/release-impact",
        "scripts/release-lid-probe",
    }
    for relative in paths:
        path = root / relative
        if not path.is_file():
            continue
        if relative.endswith(".sh") or relative in shell_names:
            status = child_run(["/bin/bash", "-n", str(path)], cwd=root)
            if status:
                return status
    if resolved_base:
        status = child_run(
            ["git", "-C", str(root), "diff", "--check", f"{resolved_base}...HEAD"],
            cwd=root,
        )
        if status:
            return status
    status = child_run(["git", "-C", str(root), "diff", "--check", "HEAD"], cwd=root)
    if status:
        return status
    for command in (
        [str(root / "tests/docs-contract.sh")],
        [str(root / "tests/release-budget-ratchet.sh")],
        [str(root / "tests/shell-safety.sh")],
        [str(root / "tests/test-suite-contract.sh")],
    ):
        status = child_run(command, cwd=root)
        if status:
            return status
    return 0


def gate_contract_definitions(
    root: Path, *, include_orchestrators: bool
) -> list[tuple[str, list[str], dict[str, str], str]]:
    contracts = [
        (
            "orchestrator-selection.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "selection"},
            "Quality gate selection tests passed",
        ),
        (
            "orchestrator-failures.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "failures"},
            "Quality gate failure tests passed",
        ),
        (
            "orchestrator-evidence-resume-a.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "evidence-resume-a"},
            "Quality gate resume provenance tests passed",
        ),
        (
            "orchestrator-evidence-resume-b.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "evidence-resume-b"},
            "Quality gate resume integrity tests passed",
        ),
        (
            "orchestrator-evidence-runtime-a.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "evidence-runtime-a"},
            "Quality gate runtime evidence A tests passed",
        ),
        (
            "orchestrator-evidence-runtime-b.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "evidence-runtime-b"},
            "Quality gate runtime evidence B tests passed",
        ),
        (
            "quality-metrics.log",
            [str(root / "tests/quality-metrics.sh")],
            {},
            "Quality metrics contracts passed",
        ),
        (
            "quality-baseline.log",
            [str(root / "tests/quality-baseline.sh")],
            {},
            "Quality baseline contracts passed",
        ),
        (
            "quality-promote.log",
            [str(root / "tests/quality-promote.sh")],
            {},
            "Quality promotion contracts passed",
        ),
        (
            "quality-merge.log",
            [str(root / "tests/quality-merge.sh")],
            {},
            "Quality merge contracts passed",
        ),
        (
            "security-automation.log",
            [str(root / "tests/security-contract.sh")],
            {},
            "Security automation contracts passed",
        ),
        (
            "release-sbom.log",
            [str(root / "tests/release-sbom.sh")],
            {},
            "Release SBOM contracts passed",
        ),
        (
            "release-pr.log",
            [str(root / "tests/release-pr.sh")],
            {},
            "Release PR contracts passed",
        ),
        (
            "quality-mutation.log",
            [str(root / "tests/quality-mutation.sh")],
            {},
            "Quality mutation contracts passed",
        ),
        (
            "release-budget-ratchet.log",
            [str(root / "tests/release-budget-ratchet-contract.sh")],
            {},
            "Release budget ratchet contract tests passed",
        ),
        (
            "shell-safety.log",
            [str(root / "tests/shell-safety-contract.sh")],
            {},
            "Shell safety contract tests passed",
        ),
        (
            "quality-history.log",
            [str(root / "tests/quality-history-contract.sh")],
            {},
            "Quality history contract tests passed",
        ),
        (
            "quality-care.log",
            [str(root / "tests/quality-care.sh")],
            {},
            "Quality care contracts passed",
        ),
        (
            "quality-gate-python.log",
            [sys.executable, str(root / "tests/quality_gate_contract.py")],
            {},
            "Quality gate Python contracts passed",
        ),
        (
            "quality-scenarios.log",
            [sys.executable, str(root / "tests/quality_scenarios_contract.py")],
            {},
            "Quality scenario contracts passed",
        ),
        (
            "quality-policy.log",
            [str(root / "tests/quality-policy.sh")],
            {},
            "Quality policy contracts passed",
        ),
        (
            "quality-dashboard.log",
            [str(root / "tests/quality-dashboard.sh")],
            {},
            "Quality dashboard contracts passed",
        ),
    ]
    if include_orchestrators:
        return contracts
    return [
        contract
        for contract in contracts
        if not contract[0].startswith("orchestrator-")
    ]


def include_gate_orchestrators(mode: str, diagnostic_stage: str) -> bool:
    return mode != "change" or bool(diagnostic_stage)


def run_gate_contract_stage(root: Path, *, include_orchestrators: bool) -> int:
    orchestrator_limit = 2
    contracts = gate_contract_definitions(
        root, include_orchestrators=include_orchestrators
    )
    contract_root = Path(tempfile.mkdtemp(prefix="detach-gate-contract."))
    processes: list[tuple[Path, subprocess.Popen[bytes], TextIO, str, float]] = []
    try:
        failed = False
        durations: dict[Path, int] = {}
        waiting = list(contracts)
        running: set[int] = set()
        running_orchestrators = 0
        while waiting or running:
            for contract in list(waiting):
                filename, command, additions, expected = contract
                is_orchestrator = filename.startswith("orchestrator-")
                if is_orchestrator and running_orchestrators >= orchestrator_limit:
                    continue
                path = contract_root / filename
                output = path.open("w", encoding="utf-8")
                environment = os.environ.copy()
                environment.update(additions)
                process = subprocess.Popen(
                    command,
                    cwd=root,
                    env=environment,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                )
                processes.append((path, process, output, expected, time.monotonic()))
                running.add(len(processes) - 1)
                running_orchestrators += int(is_orchestrator)
                waiting.remove(contract)
            for index in list(running):
                path, process, output, _, started = processes[index]
                status = process.poll()
                if status is None:
                    continue
                if status != 0:
                    failed = True
                durations[path] = max(0, round(time.monotonic() - started))
                output.close()
                running.remove(index)
                if path.name.startswith("orchestrator-"):
                    running_orchestrators -= 1
            if running:
                time.sleep(0.05)
        for path, _, _, expected, _ in sorted(processes, key=lambda item: item[0].name):
            content = path.read_text(encoding="utf-8", errors="replace")
            sys.stdout.write(content)
            if expected not in content.splitlines():
                failed = True
            print(f"quality-contract {path.stem} completed in {durations[path]}s")
        return 1 if failed else 0
    finally:
        for _, process, output, _, _ in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not output.closed:
                output.close()
        shutil.rmtree(contract_root)


def tmux_preflight(tmux: Path) -> int:
    preflight = Path(
        tempfile.mkdtemp(prefix="detach-quality-tmux-preflight.", dir="/private/tmp")
    )
    socket = preflight / "tmux.sock"
    try:
        status = child_run(
            [
                str(tmux),
                "-S",
                str(socket),
                "new-session",
                "-d",
                "-s",
                "detach-quality-preflight",
                "/bin/sleep",
                "1",
            ]
        )
        if status == 0:
            subprocess.run(
                [str(tmux), "-S", str(socket), "kill-server"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        else:
            print(
                "quality-gate environment preflight: bundled tmux could not create a "
                "private socket",
                file=sys.stderr,
            )
        return status
    finally:
        shutil.rmtree(preflight)


def run_stage_worker(stage: str) -> int:
    root = Path(os.environ.get("DETACH_QUALITY_GATE_ROOT", ROOT))
    run_dir = Path(os.environ["DETACH_QUALITY_GATE_RUN_DIR"])
    source_commit = os.environ.get("DETACH_QUALITY_GATE_SOURCE_COMMIT", "")
    authority = os.environ.get("DETACH_QUALITY_GATE_AUTHORITY", "")
    resolved_base = os.environ.get("DETACH_QUALITY_GATE_RESOLVED_BASE", "")
    mode = os.environ.get("DETACH_QUALITY_GATE_MODE", "change")
    test_mode = os.environ.get("DETACH_QUALITY_GATE_TEST_MODE") == "1"
    test_real_static = os.environ.get("DETACH_QUALITY_GATE_TEST_REAL_STATIC") == "1"
    if test_mode and (stage != "static" or not test_real_static):
        fixture = root / "tests/quality-gate-fixtures" / stage
        if not fixture.is_file() or not os.access(fixture, os.X_OK):
            print(f"quality-gate: missing test fixture for {stage}", file=sys.stderr)
            return 2
        environment = os.environ.copy()
        if stage == "quality-contracts":
            environment.update(
                {
                    "DETACH_QUALITY_METRICS_OUTPUT": str(
                        run_dir / "quality-metrics.json"
                    ),
                    "DETACH_QUALITY_OPPORTUNITIES_OUTPUT": str(
                        run_dir / "coverage-opportunities.json"
                    ),
                    "DETACH_QUALITY_SOURCE_COMMIT": source_commit,
                    "DETACH_QUALITY_AUTHORITY": authority,
                }
            )
        policy = Policy(POLICY_FILE)
        instrumented = [
            scenario_id
            for scenario_id, (scenario_stage, status, _) in policy.scenarios.items()
            if scenario_stage == stage and status == "instrumented"
        ]
        for scenario_id in instrumented:
            record_scenario_event("begin", scenario_id)
        status = child_run([str(fixture)], cwd=root, env=environment)
        if status == 0 and stage == "quality-contracts":
            opportunities = run_dir / "coverage-opportunities.json"
            if not opportunities.exists():
                write_private(opportunities, "{}\n")
        if status == 0:
            for scenario_id in instrumented:
                record_scenario_event("pass", scenario_id)
        return status

    if stage == "static":
        return run_static_stage(root, run_dir, mode, resolved_base)
    if stage == "gate-contract":
        include_orchestrators = include_gate_orchestrators(
            mode,
            os.environ.get("DETACH_QUALITY_GATE_DIAGNOSTIC_STAGE", ""),
        )
        return run_gate_contract_stage(
            root, include_orchestrators=include_orchestrators
        )
    if stage == "swift":
        app = root / "app"
        (app / ".build/quality-codecov").mkdir(parents=True, exist_ok=True)
        result = run(["swift", "build", "--show-bin-path"], cwd=app, text=True, check=False)
        assert isinstance(result.stdout, str)
        if result.returncode != 0:
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            return result.returncode
        profile = Path(result.stdout.strip()) / "codecov/default.profdata"
        profile.unlink(missing_ok=True)
        environment = os.environ.copy()
        environment["LLVM_PROFILE_FILE"] = str(
            app / ".build/quality-codecov/%p-%m.profraw"
        )
        return child_run(
            ["swift", "test", "--enable-code-coverage", "--disable-sandbox"],
            cwd=app,
            env=environment,
        )
    if stage == "quality-contracts":
        environment = os.environ.copy()
        environment.update(
            {
                "DETACH_SWIFT_TEST_LOG": str(run_dir / "swift.log"),
                "DETACH_QUALITY_METRICS_OUTPUT": str(run_dir / "quality-metrics.json"),
                "DETACH_QUALITY_OPPORTUNITIES_OUTPUT": str(
                    run_dir / "coverage-opportunities.json"
                ),
                "DETACH_QUALITY_SOURCE_COMMIT": source_commit,
                "DETACH_QUALITY_AUTHORITY": authority,
            }
        )
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        if "ui-e2e" in selected:
            profile_directory = (
                root / "app/build/quality-ui-coverage" / run_dir.name
            )
            environment.update(
                {
                    "DETACH_UI_COVERAGE_BINARY": str(
                        root / "app/.build/arm64-apple-macosx/release/DetachApp"
                    ),
                    "DETACH_UI_COVERAGE_PROFILE_DIR": str(profile_directory),
                }
            )
        status = child_run([str(root / "tests/quality-contracts.sh")], env=environment)
        if "ui-e2e" in selected:
            if profile_directory.is_symlink():
                print(
                    "quality-gate: refusing unsafe UI coverage cleanup",
                    file=sys.stderr,
                )
                return status or 2
            shutil.rmtree(profile_directory, ignore_errors=True)
        return status
    if stage == "app":
        status = child_run([str(root / "app/scripts/make-app.sh")])
        if status:
            return status
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        if "quality-contracts" not in selected:
            return 0
        return child_run(
            [
                "swift",
                "build",
                "--enable-code-coverage",
                "--disable-sandbox",
                "--disable-automatic-resolution",
                "-c",
                "release",
                "--triple",
                "arm64-apple-macosx15.0",
                "--scratch-path",
                ".build",
                "--product",
                "DetachApp",
            ],
            cwd=root / "app",
        )
    if stage == "ui-e2e":
        status = child_run([str(root / "tests/ui-e2e-contract.sh")])
        if status:
            return status
        environment = os.environ.copy()
        environment["DETACH_UI_E2E_ARTIFACT_DIR"] = str(run_dir / "ui-e2e-artifacts")
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        coverage_dir = root / "app/build/quality-ui-coverage" / run_dir.name
        if "quality-contracts" in selected:
            coverage_binary = (
                root / "app/.build/arm64-apple-macosx/release/DetachApp"
            )
            if not coverage_binary.is_file() or coverage_binary.is_symlink():
                print(
                    "quality-gate: app stage emitted no safe coverage executable",
                    file=sys.stderr,
                )
                return 2
            coverage_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            environment["LLVM_PROFILE_FILE"] = str(
                coverage_dir / "%p-%m.profraw"
            )
            environment["DETACH_UI_E2E_COVERAGE_BINARY"] = str(coverage_binary)
        status = child_run([str(root / "tests/ui-e2e.sh")], env=environment)
        if status == 0 and "quality-contracts" in selected:
            profiles = [
                path for path in coverage_dir.glob("*.profraw")
                if path.is_file() and not path.is_symlink()
            ]
            if not profiles:
                print("quality-gate: UI e2e emitted no coverage profile", file=sys.stderr)
                return 2
        return status
    payload = root / "app/build/Detach.app/Contents/Resources/DetachCLI"
    tmux = payload / "tmux"
    state = payload / "detach-state"
    if stage in ("codex", "claude"):
        if not tmux.is_file() or not os.access(tmux, os.X_OK):
            print(f"quality-gate: {stage} gate requires the app stage bundled tmux", file=sys.stderr)
            return 2
        if not state.is_file() or not os.access(state, os.X_OK):
            print(
                f"quality-gate: {stage} gate requires the app stage bundled state helper",
                file=sys.stderr,
            )
            return 2
        status = tmux_preflight(tmux)
        if status:
            return status
        environment = os.environ.copy()
        environment.update(
            {
                "DETACH_TEST_TMUX_BIN": str(tmux),
                "DETACH_TEST_STATE_BIN": str(state),
                "DETACH_PROVIDER_TEST_ARTIFACT_DIR": str(
                    run_dir / f"{stage}-artifacts"
                ),
            }
        )
        suite = "run.sh" if stage == "codex" else "run-claude.sh"
        return child_run([str(root / "tests" / suite)], env=environment)
    commands = {
        "distribution": [[str(root / "tests/distribution.sh")]],
        "tmux-runtime": [[str(root / "tests/tmux-runtime.sh")]],
        "release-preflight": [[str(root / "tests/release-preflight.sh")]],
        "publish-preflight": [[str(root / "tests/publish-preflight.sh")]],
        "release-workflow": [
            [str(root / "tests/release-impact.sh")],
            [str(root / "tests/release-workflow.sh")],
        ],
    }
    if stage not in commands:
        print(f"quality-gate stage: unknown stage: {stage}", file=sys.stderr)
        return 2
    for command in commands[stage]:
        status = child_run(command)
        if status:
            return status
    return 0


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "__run-stage":
        return run_stage_worker(arguments[1])
    gate = QualityGate(parse_options(arguments))
    return gate.execute()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (
        GateError,
        PolicyError,
        ScenarioError,
        OSError,
        UnicodeError,
        ValueError,
    ) as error:
        fail(str(error))
