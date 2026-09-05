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
import stat
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
# Typical measured stage seconds on the reference Mac. The scheduler starts
# the longest ready post-UI stage first. These are scheduling hints only; no
# verdict compares a measured duration with them.
POST_UI_STAGE_WEIGHTS = {
    "gate-contract": 120,
    "codex": 110,
    "release-workflow": 110,
    "distribution": 80,
    "claude": 60,
    "publish-preflight": 30,
    "release-preflight": 15,
    "tmux-runtime": 8,
}
POST_UI_STAGES = (
    "gate-contract",
    "codex",
    "claude",
    "distribution",
    "tmux-runtime",
    "release-preflight",
    "publish-preflight",
    "release-workflow",
)
PROCESS_HEAVY_LIMIT = 2
INTEGRATION_LANE_LIMIT = 1
PROCESS_POLL_SECONDS = 0.01
PROCESS_HEAVY_STAGES = {"gate-contract", "codex", "claude", "release-workflow"}
EXCLUSIVE_PROCESS_HEAVY_STAGES = {"gate-contract"}
GATE_COMPATIBLE_INTEGRATION_STAGES = {
    "tmux-runtime",
    "release-preflight",
    "publish-preflight",
}
RELEASE_COMPETING_INTEGRATION_STAGES = {"distribution"}
UI_COVERAGE_SCRATCH = "quality-ui-release"
SWIFT_TEST_SCRATCH = "quality-swift-tests"
QUALITY_TEST_BUNDLE = Path(
    "app/.build/quality-swift-tests/arm64-apple-macosx/debug/"
    "DetachAppPackageTests.xctest"
)
QUALITY_TEST_BINARY = (
    QUALITY_TEST_BUNDLE / "Contents/MacOS/DetachAppPackageTests"
)
QUALITY_UI_BINARY = Path(
    "app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp"
)
PROVIDER_TEST_PARTS = {
    # The Codex lane admits three parts at a time. Start the longest measured
    # independent parts first so a short part cannot delay the critical path.
    "codex": (
        "delete",
        "resume",
        "crash",
        "lifecycle",
        "preflight",
        "recovery",
        "identity",
    ),
    "claude": (
        "lifecycle-guardrails",
        "recovery",
        "history",
    ),
}
DISTRIBUTION_TEST_PARTS = ("runtime", "shells")
DISTRIBUTION_SCENARIOS = (
    "SC-INSTALL-CLEAN",
    "SC-INSTALL-REPAIR",
    "SC-DOCTOR-REPORT",
    "SC-INSTALL-UNINSTALL",
)
COMPACT_CODEX_TEST_PARTS = (
    "guardrails",
    "lifecycle-recovery",
    "resume-identity",
)
COMPACT_CLAUDE_TEST_PARTS = (
    "session",
    "history",
)
PROVIDER_PART_SCENARIOS = {
    "codex": {
        "lifecycle": (
            "SC-SESSION-CREATE-CODEX",
            "SC-SESSION-PERSIST-CODEX",
            "SC-SESSION-STOP-CODEX",
        ),
        "recovery": ("SC-SESSION-RECOVER-CODEX",),
        "delete": ("SC-SESSION-DELETE-CODEX",),
        "lifecycle-recovery": (
            "SC-SESSION-CREATE-CODEX",
            "SC-SESSION-PERSIST-CODEX",
            "SC-SESSION-STOP-CODEX",
            "SC-SESSION-RECOVER-CODEX",
        ),
        "resume-identity": (
            "SC-SESSION-DELETE-CODEX",
        ),
    },
    "claude": {
        "session": (
            "SC-SESSION-CREATE-CLAUDE",
            "SC-SESSION-PERSIST-CLAUDE",
            "SC-SESSION-STOP-CLAUDE",
            "SC-SESSION-RECOVER-CLAUDE",
        ),
        "lifecycle": (
            "SC-SESSION-CREATE-CLAUDE",
            "SC-SESSION-PERSIST-CLAUDE",
            "SC-SESSION-STOP-CLAUDE",
        ),
        "lifecycle-guardrails": (
            "SC-SESSION-CREATE-CLAUDE",
            "SC-SESSION-PERSIST-CLAUDE",
            "SC-SESSION-STOP-CLAUDE",
        ),
        "recovery": ("SC-SESSION-RECOVER-CLAUDE",),
        "history": ("SC-SESSION-DELETE-CLAUDE",),
    },
}


def provider_test_parts(stage: str) -> tuple[str, ...] | None:
    parts = PROVIDER_TEST_PARTS.get(stage)
    if stage == "codex" and (os.cpu_count() or 0) < 6:
        return COMPACT_CODEX_TEST_PARTS
    if stage == "claude" and (os.cpu_count() or 0) < 6:
        return COMPACT_CLAUDE_TEST_PARTS
    return parts


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
    reuse_hosted: str
    list_stages: bool
    stage: str
    shard: str


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
    result.add_argument("--reuse-hosted", default="")
    result.add_argument("--list-stages", action="store_true")
    result.add_argument("--stage", default="")
    result.add_argument("--shard", default="")
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
        reuse_hosted=values.reuse_hosted,
        list_stages=values.list_stages,
        stage=values.stage,
        shard=values.shard,
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
        self.resume_requested_auto = self.options.resume == "auto"
        result_root = os.environ.get(
            "DETACH_QUALITY_GATE_RESULT_ROOT", str(ROOT / "app/build/quality-gates")
        )
        self.result_root = Path(result_root).absolute()
        run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
        self.run_dir = self.result_root / run_id
        self.summary = self.run_dir / "summary.tsv"
        self.manifest = self.run_dir / "manifest.tsv"
        self.junit = self.run_dir / "junit.xml"
        self.markdown = self.run_dir / "summary.md"
        self.environment = self.run_dir / "environment.tsv"
        self.artifacts = self.run_dir / "artifacts.tsv"
        self.started_epoch = int(time.time())
        self.started_at = utc_now()
        self.results: dict[str, StageResult] = {}
        self.active: dict[str, ActiveStage] = {}
        self.reported: set[str] = set()
        self.overall_status = 0
        self.failure_count = 0
        self.prior_manifest: dict[str, str | None] = {}
        self.prior_results: dict[str, StageResult] = {}
        self.hosted_dir: Path | None = None
        self.hosted_results: dict[str, StageResult] = {}
        self.scenario_records: list[dict[str, object]] = []

    def validate_options(self) -> None:
        if self.test_real_static and not self.test_mode:
            raise GateError("real static fixture mode is test-only")
        if self.test_direct and not self.test_mode:
            raise GateError("direct fixture mode is test-only")
        if self.options.mode not in ("change", "impact", "repository", "release"):
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
        elif self.authority in ("ci-merge", "ci-main", "ci-shard"):
            if os.environ.get("GITHUB_ACTIONS") != "true":
                raise GateError(f"{self.authority} authority is restricted to GitHub Actions")
            required_mode = (
                "impact" if self.authority in ("ci-merge", "ci-shard") else "repository"
            )
            if self.options.mode != required_mode:
                raise GateError(f"{self.authority} authority requires {required_mode} mode")
            if self.options.stage:
                raise GateError(f"{self.authority} authority cannot run one diagnostic stage")
            if (self.authority == "ci-shard") != bool(self.options.shard):
                raise GateError("ci-shard authority and --shard must be used together")
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

        if self.options.reuse_hosted:
            if self.options.mode != "release":
                raise GateError("--reuse-hosted requires release mode")
            if self.options.stage or self.options.shard:
                raise GateError("--reuse-hosted cannot be combined with --stage or --shard")
        if self.options.output_format not in ("text", "json"):
            raise GateError(f"invalid format: {self.options.output_format}")
        if self.options.stage and (
            self.options.mode != "change" or self.options.base or self.options.shard
        ):
            raise GateError("--stage cannot be combined with another selection")
        if self.options.shard and self.options.mode != "impact":
            raise GateError("--shard requires impact mode")
        if self.options.shard and self.authority != "ci-shard":
            raise GateError("--shard requires ci-shard authority")
        if self.options.output_format != "text" and not self.options.plan:
            raise GateError("--format json requires --plan")
        if self.options.explain and not (
            self.options.plan and self.options.output_format == "text"
        ):
            raise GateError("--explain requires a text plan")
        if self.options.resume and (
            self.options.plan or self.options.stage or self.options.shard
        ):
            raise GateError("--resume cannot be combined with --plan, --stage, or --shard")
        if self.options.list_stages and any(
            (
                self.options.plan,
                bool(self.options.stage),
                bool(self.options.shard),
                bool(self.options.base),
                self.options.mode != "change",
                self.options.keep_going,
                bool(self.options.resume),
                self.options.output_format != "text",
                self.options.explain,
            )
        ):
            raise GateError("--list-stages cannot be combined with another option")

    def changed_entries(
        self, *, include_worktree: bool = True
    ) -> list[tuple[str, str, str | None]]:
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
        if include_worktree:
            entries.extend(
                parse_name_status(
                    git_bytes(["diff", "--name-status", "-z", "--find-renames", "HEAD"])
                )
            )
            entries.extend(("A", path, None) for path in untracked_paths())
        return entries

    def validate_authoritative_impact(self) -> None:
        if self.authority not in ("ci-merge", "ci-shard"):
            return
        github_sha = os.environ.get("GITHUB_SHA", "")
        if github_sha != self.source_commit:
            raise GateError(f"{self.authority} source does not match GITHUB_SHA")
        parents = git_text(["show", "-s", "--format=%P", "HEAD"]).split()
        if len(parents) != 2 or parents[0] != self.resolved_base:
            raise GateError(
                f"{self.authority} base is not the tested merge first parent"
            )
        if git_bytes(["diff", "--binary", "HEAD"]) or untracked_paths():
            raise GateError(f"{self.authority} impact checkout must be clean")

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
        if self.options.mode == "impact" and not self.resolved_base:
            raise GateError("impact mode requires --base")
        self.validate_authoritative_impact()
        if self.options.stage:
            if self.options.stage not in self.all_stages:
                raise GateError(f"unknown stage: {self.options.stage}")
            self.selected = [self.options.stage]
        elif self.options.mode == "repository":
            self.select_all()
        elif self.options.mode == "release" and not self.resolved_base:
            self.selected = list(self.release_stages)
            self.select_all_impacts()
        else:
            include_worktree = self.options.mode == "change"
            for status, path, new_path in self.changed_entries(
                include_worktree=include_worktree
            ):
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
        if self.options.mode == "release":
            self.selected = [stage for stage in self.selected if stage in self.release_stages]
        self.selected = [stage for stage in self.all_stages if stage in self.selected]
        if self.options.shard:
            requested = self.options.shard.split(",")
            if (
                any(not value or value not in self.all_stages for value in requested)
                or len(requested) != len(set(requested))
            ):
                raise GateError("--shard must contain unique known stages")
            unplanned = [stage for stage in requested if stage not in self.selected]
            if unplanned:
                raise GateError(
                    f"shard contains an unplanned stage: {unplanned[0]}"
                )
            self.selected = [stage for stage in self.all_stages if stage in requested]
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
        self.write_specification_sizes()
        (self.run_dir / "scenario-events").mkdir(mode=0o700)
        (self.run_dir / "stage-scenarios").mkdir(mode=0o700)
        self.write_static_files()

    def command_version(self, arguments: list[str], *, first_line: bool = False) -> str:
        try:
            result = run(arguments, text=True, check=False)
        except GateError:
            return "unavailable"
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

    def write_specification_sizes(self) -> None:
        warning = self.policy.limits["routed_spec_warning_bytes"]
        limit = self.policy.limits["routed_spec_limit_bytes"]
        specification_root = ROOT / "docs/specs"
        try:
            root_mode = specification_root.lstat().st_mode
        except OSError as error:
            raise GateError(
                f"routed specification root is missing or unsafe: {error}"
            ) from error
        if not stat.S_ISDIR(root_mode):
            raise GateError("routed specification root is missing or unsafe")
        resolved_root = specification_root.resolve()
        if resolved_root != ROOT / "docs/specs":
            raise GateError("routed specification root is missing or unsafe")
        records: list[dict[str, object]] = []
        for identifier, (raw_path, _) in self.policy.specs.items():
            relative = Path(raw_path)
            path = ROOT / relative
            try:
                if (
                    relative.is_absolute()
                    or relative.parts != ("docs", "specs", f"{identifier}.md")
                    or path.parent.resolve() != resolved_root
                ):
                    raise GateError(
                        f"routed specification path is unsafe: {raw_path}"
                    )
                try:
                    file_status = path.lstat()
                except FileNotFoundError as error:
                    raise GateError(
                        f"routed specification is missing or unsafe: {raw_path}"
                    ) from error
                if not stat.S_ISREG(file_status.st_mode):
                    raise GateError(
                        f"routed specification is missing or unsafe: {raw_path}"
                    )
                size = file_status.st_size
            except OSError as error:
                raise GateError(
                    f"cannot measure routed specification {identifier}: {error}"
                ) from error
            status = (
                "over-limit" if size > limit
                else "warning" if size > warning
                else "healthy"
            )
            records.append(
                {
                    "bytes": size,
                    "headroom_bytes": max(0, limit - size),
                    "id": identifier,
                    "path": raw_path,
                    "status": status,
                }
            )
        statuses = {record["status"] for record in records}
        overall = (
            "over-limit" if "over-limit" in statuses
            else "warning" if "warning" in statuses
            else "healthy"
        )
        document = {
            "input_fingerprint": self.input_fingerprint,
            "limit_bytes": limit,
            "policy": self.policy_version,
            "schema": 1,
            "source_commit": self.source_commit,
            "specifications": records,
            "status": overall,
            "warning_bytes": warning,
        }
        write_private(
            self.run_dir / "spec-sizes.json",
            json.dumps(
                document, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ) + "\n",
        )

    def artifact_inventory(self) -> None:
        files: list[Path] = []
        for name in (
            "quality-metrics.json",
            "quality-metrics-swift.json",
            "coverage-opportunities.json",
            "spec-sizes.json",
            "shards.tsv",
        ):
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
            timing_wall = str(max(measured, self.inherited_timing_wall()))
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
        if self.resume_requested_auto:
            try:
                self.resume_dir = self.latest_resume()
            except GateError as error:
                print(f"quality-gate: {error}; starting a fresh compatible run")
                return
        else:
            self.resume_dir = (
                self.latest_resume()
                if self.resume_requested_latest
                else Path(self.options.resume)
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
        self.validate_artifact_inventory(resume, "resume")
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

    def validate_artifact_inventory(self, root: Path, label: str) -> None:
        artifact_lines = (root / "artifacts.tsv").read_text(encoding="utf-8").splitlines()
        if not artifact_lines or artifact_lines[0] != "schema\t1":
            raise GateError(f"{label} artifact inventory schema is invalid")
        for line in artifact_lines[1:]:
            fields = line.split("\t")
            if len(fields) != 3 or fields[0] != "file":
                raise GateError(f"{label} artifact inventory contains an unknown record")
            _, relative, expected_digest = fields
            if (
                relative.startswith("/")
                or relative.startswith("../")
                or "/../" in relative
                or "\n" in relative
                or "\t" in relative
            ):
                raise GateError(f"{label} artifact inventory path is unsafe")
            if not (
                relative == "quality-metrics.json"
                or relative == "quality-metrics-swift.json"
                or relative == "coverage-opportunities.json"
                or relative == "spec-sizes.json"
                or relative == "scenarios.jsonl"
                or relative == "scenarios.junit.xml"
                or relative == "repair-bundle.json"
                or relative.startswith("stage-scenarios/")
                or relative.startswith("ui-e2e-artifacts/")
                or relative.startswith("codex-artifacts/")
                or relative.startswith("claude-artifacts/")
            ):
                raise GateError(f"{label} artifact inventory path is unapproved")
            if not DIGEST.fullmatch(expected_digest):
                raise GateError(f"{label} artifact inventory digest is invalid")
            artifact = root / relative
            if not artifact.is_file() or artifact.is_symlink():
                raise GateError(f"{label} diagnostic artifact is missing or unsafe")
            if sha256_file(artifact) != expected_digest:
                raise GateError(f"{label} diagnostic artifact digest does not match")

    def validate_hosted_reuse(self) -> None:
        """Bind hosted ci-main evidence to the exact source commit before reuse.

        Release mode may reuse a stage that hosted CI already proved for the
        same tree. The evidence must be digest-bound, must have passed, and
        must name this commit directly (ci-main) or through a promotion
        record whose tested and merged trees are equal.
        """
        if not self.options.reuse_hosted:
            return
        hosted = Path(self.options.reuse_hosted).absolute()
        if not hosted.is_dir() or hosted.is_symlink():
            raise GateError("hosted evidence path must be a non-symlink run directory")
        for name in ("manifest.tsv", "summary.tsv", "environment.tsv", "artifacts.tsv"):
            path = hosted / name
            if not path.is_file() or path.is_symlink():
                raise GateError(f"hosted evidence {name} is missing or unsafe")
        values = self.manifest_values(hosted / "manifest.tsv")
        if values.get("schema") != "4":
            raise GateError("hosted evidence schema is unsupported")
        if values.get("policy") != str(self.policy_version):
            raise GateError("hosted evidence uses another policy version")
        if values.get("result") != "passed":
            raise GateError("hosted evidence did not pass")
        if values.get("mode") not in ("impact", "repository"):
            raise GateError("hosted evidence mode is not a hosted plan")
        authority = values.get("authority")
        if authority not in ("ci-merge", "ci-main"):
            raise GateError("hosted evidence authority is not hosted")
        for name, key in (
            ("environment.tsv", "environment_sha256"),
            ("artifacts.tsv", "artifacts_sha256"),
            ("summary.tsv", "summary_sha256"),
        ):
            if sha256_file(hosted / name) != values.get(key):
                raise GateError(f"hosted evidence {name} digest does not match its manifest")
        self.validate_artifact_inventory(hosted, "hosted evidence")
        tested_commit = values.get("source_commit") or ""
        if not (authority == "ci-main" and tested_commit == self.source_commit):
            self.validate_hosted_promotion(hosted, values)
        results = self.parse_summary(
            hosted / "summary.tsv", values.get("stages") or "", values.get("mode") or ""
        )
        self.hosted_results = {
            stage: result for stage, result in results.items() if result.status == "passed"
        }
        self.hosted_dir = hosted
        proven = [
            stage
            for stage in self.selected
            if stage in self.hosted_results and stage not in self.prior_results
        ]
        print(
            f"quality-gate: hosted evidence {hosted.name} proves "
            f"{','.join(proven) if proven else 'no selected stage'} for {self.source_commit}"
        )

    def validate_hosted_promotion(self, hosted: Path, values: dict[str, str | None]) -> None:
        promotion = hosted / "promotion.tsv"
        if not promotion.is_file() or promotion.is_symlink():
            raise GateError("hosted evidence is not bound to the source commit")
        record = self.manifest_values(promotion)
        tree = git_text(["rev-parse", f"{self.source_commit}^{{tree}}"])
        checks = (
            ("schema", "1", "hosted promotion schema is unsupported"),
            ("authority", "ci-main", "hosted promotion authority is not ci-main"),
            ("result", "passed", "hosted promotion did not pass"),
            ("main_commit", self.source_commit, "hosted promotion names another main commit"),
            (
                "tested_commit",
                values.get("source_commit") or "",
                "hosted promotion names another tested commit",
            ),
            (
                "source_manifest_sha256",
                sha256_file(hosted / "manifest.tsv"),
                "hosted promotion does not bind this manifest",
            ),
            ("main_tree", tree, "hosted promotion tree does not match the source tree"),
            ("tested_tree", tree, "hosted promotion tested tree does not match the source tree"),
        )
        for key, expected, message in checks:
            if not expected or record.get(key) != expected:
                raise GateError(message)
        repository = os.environ.get("DETACH_QUALITY_REPOSITORY", "")
        if repository and record.get("repository") != repository:
            raise GateError("hosted promotion names another repository")

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

    def reuse_source(self, stage: str) -> tuple[Path, StageResult] | None:
        prior = self.prior_results.get(stage)
        if (
            prior is not None
            and prior.status in ("passed", "reused")
            and self.resume_dir is not None
        ):
            return self.resume_dir, prior
        hosted = self.hosted_results.get(stage)
        if hosted is not None and self.hosted_dir is not None:
            return self.hosted_dir, hosted
        return None

    def reusable(self, stage: str) -> bool:
        source = self.reuse_source(stage)
        if source is None:
            return False
        if stage == "ui-e2e" and "quality-contracts" in self.selected:
            # The UI profile only counts with the metrics that merged it, so
            # both must come from the same evidence.
            metrics = self.reuse_source("quality-contracts")
            if metrics is None or metrics[0] != source[0]:
                return False
        return True

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
        exact_app = environment.pop("DETACH_QUALITY_EXACT_APP", "")
        exact_products = environment.pop("DETACH_QUALITY_EXACT_PRODUCTS", "")
        for name in (
            "DETACH_CONFIRM_RELEASE",
            "DETACH_VERSION",
            "DETACH_BUILD_VERSION",
            "DETACH_BUILD_ARCHS",
            "DETACH_CODESIGN_IDENTITY",
            "DETACH_RELEASE_BUILD",
            "DETACH_QUALITY_GATE_RESULT_ROOT",
            "DETACH_SPARKLE_VERSION",
            "DETACH_SPARKLE_FEED_URL",
            "DETACH_SPARKLE_PUBLIC_ED_KEY",
            "DETACH_DOWNLOAD_URL",
        ):
            environment.pop(name, None)
        module_cache = ROOT / "app/.build/module-cache" / stage
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
        if stage == "app" and exact_app:
            environment["DETACH_QUALITY_EXACT_APP"] = exact_app
        # Provider suites read tmux and detach-state from the exact runtime
        # products when a hosted shard bound them.
        if stage in (
            "swift", "app", "ui-e2e", "quality-contracts", "codex", "claude"
        ) and exact_products:
            environment["DETACH_QUALITY_EXACT_PRODUCTS"] = exact_products
        if not self.test_direct:
            environment["DETACH_RELEASE_TESTS_DETACHED"] = "1"
        return environment

    def launch(self, stage: str) -> None:
        if stage not in self.selected or stage in self.results or stage in self.active:
            return
        if self.reusable(stage):
            source = self.reuse_source(stage)
            assert source is not None
            source_dir, prior = source
            kind = "hosted" if source_dir == self.hosted_dir else "matching"
            print(f"quality-gate: reusing {stage} from {kind} evidence {source_dir}")
            origin = prior.origin_run if prior.origin_run != "-" else source_dir.name
            reused_log = "-"
            if prior.log != "-":
                reused_log = f"{stage}.reused.log"
                shutil.copyfile(source_dir / prior.log, self.run_dir / reused_log)
                (self.run_dir / reused_log).chmod(0o600)
            if stage == "quality-contracts":
                metrics = source_dir / "quality-metrics.json"
                if not metrics.is_file() or metrics.is_symlink():
                    raise GateError(
                        "reused quality-contracts evidence has no safe quality metrics"
                    )
                shutil.copyfile(metrics, self.run_dir / "quality-metrics.json")
                (self.run_dir / "quality-metrics.json").chmod(0o600)
                swift_metrics = source_dir / "quality-metrics-swift.json"
                if swift_metrics.exists():
                    if not swift_metrics.is_file() or swift_metrics.is_symlink():
                        raise GateError(
                            "reused quality-contracts evidence has unsafe Swift metrics"
                        )
                    shutil.copyfile(
                        swift_metrics, self.run_dir / "quality-metrics-swift.json"
                    )
                    (self.run_dir / "quality-metrics-swift.json").chmod(0o600)
                opportunities = source_dir / "coverage-opportunities.json"
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
                scenario_source=source_dir / "stage-scenarios" / f"{stage}.jsonl",
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
                r"sandbox\S* denied|deny\(1\)|"
                r"UI e2e: environment denied",
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
                time.sleep(PROCESS_POLL_SECONDS)
        for stage in stages:
            if stage in self.results:
                self.report(stage)

    def run_post_ui_stages(self) -> None:
        pending = [stage for stage in POST_UI_STAGES if stage in self.selected]
        pending.sort(
            key=lambda stage: (
                stage != "gate-contract",
                -POST_UI_STAGE_WEIGHTS.get(stage, 0),
                self.all_stages.index(stage),
            )
        )
        while pending or any(stage in self.active for stage in POST_UI_STAGES):
            while pending:
                active_heavy = sum(
                    stage in self.active for stage in PROCESS_HEAVY_STAGES
                )
                active_integration = sum(
                    stage in self.active
                    for stage in POST_UI_STAGES
                    if stage not in PROCESS_HEAVY_STAGES
                )
                candidate = next(
                    (
                        stage for stage in pending
                        if (
                            active_heavy < PROCESS_HEAVY_LIMIT
                            and (
                                active_heavy == 0
                                if stage in EXCLUSIVE_PROCESS_HEAVY_STAGES
                                else not any(
                                    peer in self.active
                                    for peer in EXCLUSIVE_PROCESS_HEAVY_STAGES
                                )
                            )
                            if stage in PROCESS_HEAVY_STAGES
                            else (
                                active_integration < INTEGRATION_LANE_LIMIT
                                and not (
                                    stage in RELEASE_COMPETING_INTEGRATION_STAGES
                                    and (
                                        "release-workflow" in self.active
                                        or "release-workflow" in pending
                                    )
                                )
                                and (
                                    "gate-contract" not in self.active
                                    or stage in GATE_COMPATIBLE_INTEGRATION_STAGES
                                )
                            )
                        )
                    ),
                    None,
                )
                if candidate is None:
                    break
                pending.remove(candidate)
                stage = candidate
                self.launch(stage)
                if stage in self.results:
                    self.report(stage)
            self.poll_active()
            for stage in POST_UI_STAGES:
                if stage in self.results:
                    self.report(stage)
            if pending or any(stage in self.active for stage in POST_UI_STAGES):
                time.sleep(PROCESS_POLL_SECONDS)

    def inherited_timing_wall(self) -> int:
        """Return the wall time carried from a resumed run as telemetry."""
        if self.resume_dir is None:
            return 0
        raw = self.prior_manifest.get("timing_wall_seconds")
        if raw is None or not NONNEGATIVE_INTEGER.fullmatch(raw):
            raise GateError("resume timing wall duration is invalid")
        return int(raw)

    def report(self, stage: str) -> None:
        if stage in self.reported:
            return
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
        self.validate_hosted_reuse()
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
            parallel_swift_app = (
                "swift" in self.selected
                and "app" in self.selected
                and (os.cpu_count() or 0) >= 3
            )
            self.launch("swift")
            if parallel_swift_app:
                self.launch("app")
                self.wait_for(("swift", "app"))
            else:
                self.wait_for(("swift",))
                self.launch("app")
                self.wait_for(("app",))
            self.launch("ui-e2e")
            self.wait_for(("ui-e2e",))
            self.launch("quality-contracts")
            self.wait_for(("quality-contracts",))
            self.run_post_ui_stages()
            for stage in self.selected:
                self.wait_for((stage,))
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


RUNTIME_PRODUCT_ROOT = Path("app/.build/quality-runtime")


def provider_runtime_payload(root: Path) -> Path:
    """Return the directory that holds tmux and detach-state for provider suites.

    Hosted shards that bind exact products from the last green main use the
    published runtime products. Everything else uses the freshly verified app.
    """
    if exact_products_enabled():
        return root / RUNTIME_PRODUCT_ROOT
    return root / "app/build/Detach.app/Contents/Resources/DetachCLI"


def exact_products_enabled() -> bool:
    value = os.environ.get("DETACH_QUALITY_EXACT_PRODUCTS", "")
    if value not in ("", "1"):
        raise GateError("DETACH_QUALITY_EXACT_PRODUCTS must be 1")
    if value and (
        os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("DETACH_QUALITY_GATE_AUTHORITY")
        not in ("ci-shard", "ci-main")
    ):
        raise GateError("exact product reuse requires hosted CI authority")
    return value == "1"


def exact_swift_profile(run_dir: Path) -> Path:
    return run_dir / "exact-swift.profdata"


def run_exact_swift_stage(root: Path, run_dir: Path) -> int:
    bundle = root / QUALITY_TEST_BUNDLE
    binary = root / QUALITY_TEST_BINARY
    if (
        not bundle.is_dir()
        or bundle.is_symlink()
        or not binary.is_file()
        or binary.is_symlink()
        or not os.access(binary, os.X_OK)
    ):
        print("quality-gate: exact Swift test product is missing or unsafe", file=sys.stderr)
        return 2
    raw_root = run_dir / "exact-swift-profiles"
    if raw_root.exists():
        if not raw_root.is_dir() or raw_root.is_symlink():
            print("quality-gate: exact Swift profile root is unsafe", file=sys.stderr)
            return 2
        shutil.rmtree(raw_root)
    raw_root.mkdir(mode=0o700)
    environment = os.environ.copy()
    environment["LLVM_PROFILE_FILE"] = str(raw_root / "%p-%m.profraw")
    status = child_run(["xcrun", "xctest", str(bundle)], cwd=root, env=environment)
    if status:
        return status
    profiles = sorted(
        path for path in raw_root.glob("*.profraw")
        if path.is_file() and not path.is_symlink()
    )
    if not profiles:
        print("quality-gate: exact Swift tests emitted no coverage profile", file=sys.stderr)
        return 2
    profile = exact_swift_profile(run_dir)
    profile.unlink(missing_ok=True)
    return child_run(
        [
            "xcrun",
            "llvm-profdata",
            "merge",
            "-sparse",
            *[str(path) for path in profiles],
            "-o",
            str(profile),
        ],
        cwd=root,
    )


def run_provider_parts(
    root: Path,
    run_dir: Path,
    stage: str,
    environment: dict[str, str],
) -> int:
    parts = provider_test_parts(stage)
    if parts is None:
        print(f"quality-gate: no provider test partition for {stage}", file=sys.stderr)
        return 2
    part_root = run_dir / f"{stage}-parts"
    if part_root.exists():
        if not part_root.is_dir() or part_root.is_symlink():
            print("quality-gate: provider part evidence root is unsafe", file=sys.stderr)
            return 2
        shutil.rmtree(part_root)
    part_root.mkdir(mode=0o700)
    artifact_value = environment.get("DETACH_PROVIDER_TEST_ARTIFACT_DIR", "")
    artifact_root = Path(artifact_value) if artifact_value else None
    variable = f"DETACH_{stage.upper()}_TEST_PART"
    suite = root / ("tests/run.sh" if stage == "codex" else "tests/run-claude.sh")
    scenario_owners = PROVIDER_PART_SCENARIOS.get(stage, {})
    processes: list[
        tuple[str, Path, subprocess.Popen[bytes], TextIO, float]
    ] = []
    try:
        for part in parts:
            for scenario_id in scenario_owners.get(part, ()):
                record_scenario_event("begin", scenario_id)
        waiting = list(parts)
        part_limit = min(len(parts), 3 if stage == "codex" else len(parts))
        pending: set[int] = set()
        statuses: dict[int, int] = {}
        durations: dict[int, int] = {}
        while waiting or pending:
            while waiting and len(pending) < part_limit:
                part = waiting.pop(0)
                part_environment = environment.copy()
                part_environment[variable] = part
                part_environment["DETACH_QUALITY_PARTITIONED_PROVIDER"] = "1"
                if artifact_root is not None:
                    part_environment["DETACH_PROVIDER_TEST_ARTIFACT_DIR"] = str(
                        artifact_root / part
                    )
                log = part_root / f"{part}.log"
                output = log.open("w", encoding="utf-8")
                log.chmod(0o600)
                process = subprocess.Popen(
                    [str(suite)],
                    cwd=root,
                    env=part_environment,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                )
                processes.append((part, log, process, output, time.monotonic()))
                pending.add(len(processes) - 1)
            for index in list(pending):
                part, _, process, output, started = processes[index]
                status = process.poll()
                if status is None:
                    continue
                output.close()
                statuses[index] = status
                durations[index] = max(0, round(time.monotonic() - started))
                if status == 0:
                    for scenario_id in scenario_owners.get(part, ()):
                        record_scenario_event("pass", scenario_id)
                pending.remove(index)
            if pending:
                time.sleep(PROCESS_POLL_SECONDS)
        for index, (part, log, _, _, _) in enumerate(processes):
            status = statuses[index]
            sys.stdout.write(log.read_text(encoding="utf-8", errors="replace"))
            print(
                f"quality-gate: {stage} part {part} completed in {durations[index]}s "
                f"with exit {status}"
            )
        return next(
            (statuses[index] for index in range(len(processes)) if statuses[index]),
            0,
        )
    except OSError as error:
        print(f"quality-gate: cannot run {stage} test parts: {error}", file=sys.stderr)
        return 2
    finally:
        for _, _, process, output, _ in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not output.closed:
                output.close()


def run_distribution_parts(root: Path, run_dir: Path) -> int:
    part_root = run_dir / "distribution-parts"
    if part_root.exists():
        if not part_root.is_dir() or part_root.is_symlink():
            print(
                "quality-gate: distribution part evidence root is unsafe",
                file=sys.stderr,
            )
            return 2
        shutil.rmtree(part_root)
    part_root.mkdir(mode=0o700)
    suite = root / "tests/distribution.sh"
    processes: list[
        tuple[str, Path, subprocess.Popen[bytes], TextIO, float]
    ] = []
    try:
        for scenario_id in DISTRIBUTION_SCENARIOS:
            record_scenario_event("begin", scenario_id)
        statuses: dict[int, int] = {}
        durations: dict[int, int] = {}
        for part in DISTRIBUTION_TEST_PARTS:
            environment = os.environ.copy()
            environment["DETACH_DISTRIBUTION_TEST_PART"] = part
            environment["DETACH_QUALITY_PARTITIONED_DISTRIBUTION"] = "1"
            log = part_root / f"{part}.log"
            output = log.open("w", encoding="utf-8")
            log.chmod(0o600)
            process = subprocess.Popen(
                [str(suite)],
                cwd=root,
                env=environment,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            processes.append((part, log, process, output, time.monotonic()))
        pending = set(range(len(processes)))
        while pending:
            for index in list(pending):
                _, _, process, output, started = processes[index]
                part_status = process.poll()
                if part_status is None:
                    continue
                output.close()
                statuses[index] = part_status
                durations[index] = max(0, round(time.monotonic() - started))
                pending.remove(index)
            if pending:
                time.sleep(PROCESS_POLL_SECONDS)
        status = next(
            (statuses[index] for index in range(len(processes)) if statuses[index]),
            0,
        )
        if status == 0:
            for scenario_id in DISTRIBUTION_SCENARIOS:
                record_scenario_event("pass", scenario_id)
        for index, (part, log, _, _, _) in enumerate(processes):
            sys.stdout.write(log.read_text(encoding="utf-8", errors="replace"))
            print(
                f"quality-gate: distribution part {part} completed in "
                f"{durations[index]}s with exit {statuses[index]}"
            )
        return status
    except OSError as error:
        print(
            f"quality-gate: cannot run distribution test parts: {error}",
            file=sys.stderr,
        )
        return 2
    finally:
        for _, _, process, output, _ in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not output.closed:
                output.close()


def run_static_contracts(root: Path, run_dir: Path) -> int:
    contracts = (
        ("documentation", [str(root / "tests/docs-contract.sh")]),
        ("shell-safety", [str(root / "tests/shell-safety.sh")]),
        ("suite-inventory", [str(root / "tests/test-suite-contract.sh")]),
    )
    part_root = run_dir / "static-parts"
    part_root.mkdir(mode=0o700)
    processes: list[
        tuple[str, Path, subprocess.Popen[bytes], TextIO, float]
    ] = []
    try:
        for name, command in contracts:
            log = part_root / f"{name}.log"
            output = log.open("w", encoding="utf-8")
            log.chmod(0o600)
            process = subprocess.Popen(
                command,
                cwd=root,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            processes.append((name, log, process, output, time.monotonic()))
        statuses: dict[int, int] = {}
        durations: dict[int, int] = {}
        pending = set(range(len(processes)))
        while pending:
            for index in list(pending):
                _, _, process, output, started = processes[index]
                status = process.poll()
                if status is None:
                    continue
                output.close()
                statuses[index] = status
                durations[index] = max(0, round(time.monotonic() - started))
                pending.remove(index)
            if pending:
                time.sleep(PROCESS_POLL_SECONDS)
        for index, (name, log, _, _, _) in enumerate(processes):
            sys.stdout.write(log.read_text(encoding="utf-8", errors="replace"))
            print(
                f"quality-gate: static part {name} completed in "
                f"{durations[index]}s with exit {statuses[index]}"
            )
        return next(
            (statuses[index] for index in range(len(processes)) if statuses[index]),
            0,
        )
    except OSError as error:
        print(f"quality-gate: cannot run static contracts: {error}", file=sys.stderr)
        return 2
    finally:
        for _, _, process, output, _ in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not output.closed:
                output.close()


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
        "scripts/quality-shard",
        "scripts/quality-scenarios",
        "scripts/quality-policy",
        "scripts/quality-metrics",
        "scripts/quality-mutation",
        "scripts/quality-baseline",
        "scripts/quality-evidence",
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
    return run_static_contracts(root, run_dir)


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
            "orchestrator-distributed.log",
            [str(root / "tests/quality-gate.sh")],
            {"DETACH_QUALITY_GATE_CONTRACT_SHARD": "distributed"},
            "Quality gate distributed evidence tests passed",
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
            "quality-evidence.log",
            [str(root / "tests/quality-evidence.sh")],
            {},
            "Quality evidence contracts passed",
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
        (
            "quality-cache-warm.log",
            [sys.executable, str(root / "tests/quality_cache_warm_contract.py")],
            {},
            "Quality cache warm contracts passed",
        ),
        (
            "quality-products.log",
            [sys.executable, str(root / "tests/quality_products_contract.py")],
            {},
            "Quality executable product contracts passed",
        ),
        (
            "quality-shard.log",
            [sys.executable, str(root / "tests/quality_shard_contract.py")],
            {},
            "Quality shard contracts passed",
        ),
    ]
    if include_orchestrators:
        return contracts
    return [
        contract
        for contract in contracts
        if not contract[0].startswith("orchestrator-")
    ]


def gate_orchestrator_limit(logical_cpus: int | None = None) -> int:
    available = logical_cpus if logical_cpus is not None else os.cpu_count()
    return 4 if (available or 0) >= 8 else 2


def gate_contract_process_limit(logical_cpus: int | None = None) -> int:
    available = logical_cpus if logical_cpus is not None else os.cpu_count()
    return max(2, min(4, available or 2))


def include_gate_orchestrators(mode: str, diagnostic_stage: str) -> bool:
    return mode != "change" or bool(diagnostic_stage)


def run_gate_contract_stage(root: Path, *, include_orchestrators: bool) -> int:
    orchestrator_limit = gate_orchestrator_limit()
    process_limit = gate_contract_process_limit()
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
                if len(running) >= process_limit:
                    break
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
                time.sleep(PROCESS_POLL_SECONDS)
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


def ui_coverage_binary(root: Path, *, exact_products: bool = False) -> Path:
    if exact_products:
        return root / QUALITY_UI_BINARY
    return (
        root / "app/.build" / UI_COVERAGE_SCRATCH
        / "arm64-apple-macosx/release/DetachApp"
    )


def split_swift_build_jobs(logical_cpus: int | None = None) -> tuple[int, int]:
    available = logical_cpus if logical_cpus is not None else os.cpu_count()
    total = max(2, available or 2)
    normal = (total + 1) // 2
    return normal, total - normal


def split_quality_pipeline_jobs(
    logical_cpus: int | None = None,
) -> tuple[int, int, int]:
    available = logical_cpus if logical_cpus is not None else os.cpu_count()
    total = max(3, available or 3)
    swift = (total + 2) // 3
    remaining = total - swift
    normal = (remaining + 1) // 2
    return swift, normal, remaining - normal


def run_app_stage(root: Path) -> int:
    make_app = [str(root / "app/scripts/make-app.sh")]
    exact_app = os.environ.get("DETACH_QUALITY_EXACT_APP", "")
    if exact_app not in ("", "1"):
        print("quality-gate: DETACH_QUALITY_EXACT_APP must be 1", file=sys.stderr)
        return 2
    if exact_app and (
        os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("DETACH_QUALITY_GATE_AUTHORITY")
        not in ("ci-shard", "ci-main")
    ):
        print(
            "quality-gate: exact app reuse requires hosted CI authority",
            file=sys.stderr,
        )
        return 2
    normal_command = (
        [str(root / "app/scripts/verify-app.sh")] if exact_app else make_app
    )
    selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
    if "quality-contracts" not in selected:
        return child_run(normal_command)
    try:
        exact_products = exact_products_enabled()
    except GateError as error:
        print(f"quality-gate: {error}", file=sys.stderr)
        return 2
    if exact_products:
        return child_run(normal_command)

    parallel_swift = "swift" in selected and (os.cpu_count() or 0) >= 3
    if parallel_swift:
        _, normal_jobs, coverage_jobs = split_quality_pipeline_jobs()
    else:
        normal_jobs, coverage_jobs = split_swift_build_jobs()
    normal_environment = os.environ.copy()
    normal_environment["DETACH_SWIFT_BUILD_JOBS"] = str(normal_jobs)
    normal_environment["DETACH_QUALITY_APP_SCRATCH"] = "1"
    coverage_environment = os.environ.copy()
    coverage_environment.pop("DETACH_APP_BUILD_MARKER_FILE", None)
    coverage_module_cache = root / "app/.build/quality-ui-module-cache"
    coverage_environment.update(
        {
            "CLANG_MODULE_CACHE_PATH": str(coverage_module_cache),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(coverage_module_cache),
        }
    )
    coverage_command = [
        "swift",
        "build",
        "--enable-code-coverage",
        "--disable-sandbox",
        "--disable-automatic-resolution",
        "--cache-path",
        str(root / "app/.build"),
        "-c",
        "release",
        "--triple",
        "arm64-apple-macosx26.0",
        "--scratch-path",
        str(root / "app/.build" / UI_COVERAGE_SCRATCH),
        "--product",
        "DetachApp",
        "--jobs",
        str(coverage_jobs),
    ]
    coverage_process = subprocess.Popen(
        coverage_command,
        cwd=root / "app",
        env=coverage_environment,
    )
    normal_status = child_run(normal_command, env=normal_environment)
    coverage_status = coverage_process.wait()
    return normal_status or coverage_status


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
        if exact_products_enabled():
            return run_exact_swift_stage(root, run_dir)
        app = root / "app"
        scratch = app / ".build" / SWIFT_TEST_SCRATCH
        (app / ".build/quality-codecov").mkdir(parents=True, exist_ok=True)
        build_path_command = [
            "swift", "build", "--show-bin-path", "--disable-automatic-resolution",
            "--cache-path", str(app / ".build"),
            "--scratch-path", str(scratch)
        ]
        result = run(build_path_command, cwd=app, text=True, check=False)
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
        command = [
            "swift", "test", "--enable-code-coverage", "--disable-sandbox",
            "--disable-automatic-resolution",
            "--cache-path", str(app / ".build"), "--scratch-path", str(scratch),
        ]
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        if "app" in selected and (os.cpu_count() or 0) >= 3:
            swift_jobs, _, _ = split_quality_pipeline_jobs()
            command.extend(("--jobs", str(swift_jobs)))
        return child_run(
            command,
            cwd=app,
            env=environment,
        )
    if stage == "quality-contracts":
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        exact_products = exact_products_enabled()
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
        if exact_products:
            environment.update(
                {
                    "DETACH_SWIFT_TEST_BINARY": str(root / QUALITY_TEST_BINARY),
                    "DETACH_SWIFT_TEST_PROFILE": str(exact_swift_profile(run_dir)),
                }
            )
        elif "swift" in selected:
            environment["DETACH_SWIFT_TEST_SCRATCH"] = str(
                root / "app/.build" / SWIFT_TEST_SCRATCH
            )
        if "ui-e2e" in selected:
            profile_directory = (
                root / "app/build/quality-ui-coverage" / run_dir.name
            )
            environment.update(
                {
                    "DETACH_UI_COVERAGE_BINARY": str(
                        ui_coverage_binary(root, exact_products=exact_products)
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
        return run_app_stage(root)
    if stage == "ui-e2e":
        exact_products = exact_products_enabled()
        status = child_run([str(root / "tests/ui-e2e-contract.sh")])
        if status:
            return status
        environment = os.environ.copy()
        environment["DETACH_UI_E2E_ARTIFACT_DIR"] = str(run_dir / "ui-e2e-artifacts")
        selected = os.environ.get("DETACH_QUALITY_GATE_SELECTED_STAGES", "").split(",")
        coverage_dir = root / "app/build/quality-ui-coverage" / run_dir.name
        if "quality-contracts" in selected:
            coverage_binary = ui_coverage_binary(
                root, exact_products=exact_products
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
    payload = provider_runtime_payload(root)
    tmux = payload / "tmux"
    state = payload / "detach-state"
    if stage in ("codex", "claude"):
        print(f"quality-gate: {stage} runtime payload {payload}", file=sys.stderr)
        if not tmux.is_file() or tmux.is_symlink() or not os.access(tmux, os.X_OK):
            print(
                f"quality-gate: {stage} gate requires bundled tmux from the app stage "
                "or exact runtime products",
                file=sys.stderr,
            )
            return 2
        if not state.is_file() or state.is_symlink() or not os.access(state, os.X_OK):
            print(
                f"quality-gate: {stage} gate requires the bundled state helper from the "
                "app stage or exact runtime products",
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
        if stage in PROVIDER_TEST_PARTS:
            return run_provider_parts(root, run_dir, stage, environment)
        return child_run([str(root / "tests/run-claude.sh")], env=environment)
    if stage == "distribution":
        return run_distribution_parts(root, run_dir)
    commands = {
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
