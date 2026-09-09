#!/usr/bin/env python3
"""Record and assemble scenario-addressable quality evidence."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
from typing import Any, Iterable, NoReturn

from quality_policy import POLICY_FILE, Policy, PolicyError


ROOT = Path(__file__).resolve().parent.parent
EVENT_SCHEMA = 1
RESULT_SCHEMA = 1
EVENT_KINDS = {"begin", "pass"}
STAGE_FAILURES = {"failed", "environment-failed", "timeout", "interrupted"}
SCENARIO_FAILURES = STAGE_FAILURES | {"missing"}
SAFE_ID = re.compile(r"^SC-[A-Z0-9-]+$")
SAFE_STAGE = re.compile(r"^[a-z0-9-]+$")
SAFE_LOG = re.compile(r"^[a-z0-9-]+\.log$")
RESULT_STATUSES = {
    "passed",
    "failed",
    "environment-failed",
    "timeout",
    "interrupted",
    "blocked",
    "not-run",
    "missing",
    "planned",
    "manual-release",
}
LOG_TAIL_BYTES = 65_536
LOG_TAIL_LINES = 100
RERUN_FINALIZE_SECONDS = 30


class ScenarioError(Exception):
    """Malformed, incomplete, or unsafe scenario evidence."""


def fail(message: str) -> NoReturn:
    print(f"quality-scenarios: {message}", file=sys.stderr)
    raise SystemExit(2)


def canonical(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def safe_output(path: Path, label: str) -> None:
    if path.exists() and (not path.is_file() or path.is_symlink()):
        raise ScenarioError(f"{label} must be a regular non-symlink file")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise ScenarioError(f"{label} parent must be a non-symlink directory")


def write_private(path: Path, text: str) -> None:
    safe_output(path, "scenario output")
    path.write_text(text, encoding="utf-8")
    path.chmod(0o600)


def read_jsonl(path: Path, label: str) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    if not path.is_file() or path.is_symlink():
        raise ScenarioError(f"{label} is missing or unsafe")
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ScenarioError(f"cannot read {label}: {error}") from error
    for line_number, line in enumerate(lines, 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise ScenarioError(f"{label} line {line_number} is malformed: {error}") from error
        if not isinstance(value, dict):
            raise ScenarioError(f"{label} line {line_number} is not an object")
        records.append(value)
    return records


def append_event(path: Path, record: dict[str, Any]) -> None:
    safe_output(path, "scenario event file")
    flags = os.O_RDWR | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise ScenarioError(f"cannot open scenario event file: {error}") from error
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        prior = read_jsonl(path, "scenario events")
        scenario_id = record["id"]
        kind = record["kind"]
        kinds = [
            event.get("kind") for event in prior
            if event.get("id") == scenario_id
        ]
        if kind == "begin" and kinds:
            raise ScenarioError(f"scenario {scenario_id} began more than once")
        if kind == "pass" and kinds != ["begin"]:
            raise ScenarioError(
                f"scenario {scenario_id} passed without one begin event")
        record["time_ns"] = next_event_time_ns(prior)
        os.write(descriptor, (canonical(record) + "\n").encode("utf-8"))
        os.fchmod(descriptor, 0o600)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def next_event_time_ns(prior: list[dict[str, Any]]) -> int:
    """Return a cross-process timestamp that stays ordered in the event file."""
    now = time.time_ns()
    if not prior:
        return now
    previous = prior[-1].get("time_ns")
    if isinstance(previous, int) and previous > 0:
        return max(now, previous + 1)
    return now


def scenario_context(policy: Policy) -> dict[str, dict[str, list[str]]]:
    result: dict[str, dict[str, list[str]]] = {
        identifier: {"journeys": [], "requirements": []}
        for identifier in policy.scenarios
    }
    for journey_id, (_, requirements, scenarios, _) in policy.journeys.items():
        journey_requirements = [] if requirements == "-" else requirements.split(",")
        for scenario_id in scenarios.split(","):
            context = result[scenario_id]
            if journey_id not in context["journeys"]:
                context["journeys"].append(journey_id)
            for requirement in journey_requirements:
                if requirement not in context["requirements"]:
                    context["requirements"].append(requirement)
    return result


def record_event(kind: str, scenario_id: str) -> None:
    if kind not in EVENT_KINDS:
        raise ScenarioError(f"invalid event kind: {kind}")
    if not SAFE_ID.fullmatch(scenario_id):
        raise ScenarioError(f"invalid scenario id: {scenario_id}")
    raw_path = os.environ.get("DETACH_QUALITY_SCENARIO_EVENTS", "")
    if not raw_path:
        return
    stage = os.environ.get("DETACH_QUALITY_SCENARIO_STAGE", "")
    if not SAFE_STAGE.fullmatch(stage):
        raise ScenarioError("scenario stage is missing or invalid")
    policy = Policy(POLICY_FILE)
    scenario = policy.scenarios.get(scenario_id)
    if scenario is None:
        raise ScenarioError(f"unknown scenario: {scenario_id}")
    expected_stage, policy_status, _ = scenario
    if expected_stage != stage:
        raise ScenarioError(
            f"scenario {scenario_id} belongs to {expected_stage}, not {stage}"
        )
    if policy_status != "instrumented":
        raise ScenarioError(f"scenario {scenario_id} is not instrumented in policy")
    path = Path(raw_path)
    append_event(
        path,
        {
            "schema": EVENT_SCHEMA,
            "id": scenario_id,
            "stage": stage,
            "kind": kind,
        },
    )


def validate_events(
    events: Iterable[dict[str, Any]], stage: str, policy: Policy
) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    last_time = 0
    for event in events:
        if set(event) != {"schema", "id", "stage", "kind", "time_ns"}:
            raise ScenarioError("scenario event has unknown or missing fields")
        schema = event["schema"]
        scenario_id = event["id"]
        event_stage = event["stage"]
        kind = event["kind"]
        event_time = event["time_ns"]
        if schema != EVENT_SCHEMA:
            raise ScenarioError("scenario event schema is unsupported")
        if not isinstance(scenario_id, str) or not SAFE_ID.fullmatch(scenario_id):
            raise ScenarioError("scenario event id is invalid")
        if event_stage != stage:
            raise ScenarioError("scenario event stage does not match its file")
        scenario = policy.scenarios.get(scenario_id)
        if scenario is None or scenario[0] != stage or scenario[1] != "instrumented":
            raise ScenarioError(f"unexpected instrumented scenario event: {scenario_id}")
        if kind not in EVENT_KINDS:
            raise ScenarioError(f"scenario event kind is invalid: {scenario_id}")
        if not isinstance(event_time, int) or event_time <= 0 or event_time < last_time:
            raise ScenarioError("scenario event time is invalid or unordered")
        last_time = event_time
        grouped.setdefault(scenario_id, []).append(event)
    for scenario_id, records in grouped.items():
        kinds = [record["kind"] for record in records]
        if kinds not in (["begin"], ["begin", "pass"]):
            raise ScenarioError(f"scenario event order is invalid: {scenario_id}")
    return grouped


def stage_outcome(status: str) -> str:
    if status in ("passed", "reused"):
        return "passed"
    if status in STAGE_FAILURES:
        return status
    if status == "blocked":
        return "blocked"
    return "not-run"


def finalize_stage(
    *,
    policy: Policy,
    stage: str,
    stage_status: str,
    stage_duration_seconds: int,
    stage_log: str,
    event_path: Path,
    output_path: Path,
) -> list[str]:
    context = scenario_context(policy)
    events = validate_events(read_jsonl(event_path, "scenario events"), stage, policy)
    records: list[dict[str, Any]] = []
    errors: list[str] = []
    for scenario_id, (scenario_stage, policy_status, command) in policy.scenarios.items():
        if scenario_stage != stage:
            continue
        outcome = "not-run"
        duration_ms = 0
        granularity = "stage"
        message = ""
        scenario_events = events.get(scenario_id, [])
        if policy_status == "instrumented":
            granularity = "scenario"
            if len(scenario_events) == 2:
                outcome = "passed"
                duration_ms = max(
                    0, (scenario_events[1]["time_ns"] - scenario_events[0]["time_ns"]) // 1_000_000
                )
            elif len(scenario_events) == 1:
                outcome = stage_outcome(stage_status)
                if outcome == "passed":
                    outcome = "missing"
                    errors.append(f"{scenario_id} has no pass marker")
                message = "scenario began but did not emit a pass marker"
            else:
                outcome = "missing" if stage_status in ("passed", "reused") else stage_outcome(stage_status)
                message = "scenario emitted no markers"
                if outcome == "missing":
                    errors.append(f"{scenario_id} emitted no markers")
        elif policy_status in ("automated", "legacy-stage"):
            outcome = stage_outcome(stage_status)
            duration_ms = max(0, stage_duration_seconds * 1000)
            granularity = "command" if policy_status == "automated" else "legacy-stage"
        elif policy_status == "planned":
            outcome = "planned"
            granularity = "planned"
        elif policy_status == "manual-release":
            outcome = "manual-release"
            granularity = "manual-release"
        else:
            raise ScenarioError(f"unsupported scenario policy status: {policy_status}")
        records.append(
            {
                "schema": RESULT_SCHEMA,
                "id": scenario_id,
                "stage": stage,
                "policy_status": policy_status,
                "status": outcome,
                "granularity": granularity,
                "duration_ms": duration_ms,
                "requirements": context[scenario_id]["requirements"],
                "journeys": context[scenario_id]["journeys"],
                "rerun": f"scripts/quality-scenarios rerun {scenario_id}",
                "command": command,
                "log": stage_log,
                "message": message,
            }
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.parent.is_symlink():
        raise ScenarioError("stage scenario output directory is unsafe")
    write_private(output_path, "".join(canonical(record) + "\n" for record in records))
    return errors


def validate_result(
    record: dict[str, Any],
    policy: Policy,
    context: dict[str, dict[str, list[str]]],
) -> None:
    required = {
        "schema",
        "id",
        "stage",
        "policy_status",
        "status",
        "granularity",
        "duration_ms",
        "requirements",
        "journeys",
        "rerun",
        "command",
        "log",
        "message",
    }
    if set(record) != required or record.get("schema") != RESULT_SCHEMA:
        raise ScenarioError("scenario result schema is invalid")
    if not isinstance(record["id"], str) or not SAFE_ID.fullmatch(record["id"]):
        raise ScenarioError("scenario result id is invalid")
    if not isinstance(record["stage"], str) or not SAFE_STAGE.fullmatch(record["stage"]):
        raise ScenarioError("scenario result stage is invalid")
    if not isinstance(record["duration_ms"], int) or record["duration_ms"] < 0:
        raise ScenarioError("scenario result duration is invalid")
    for key in (
        "policy_status",
        "status",
        "granularity",
        "rerun",
        "command",
        "log",
        "message",
    ):
        if not isinstance(record[key], str):
            raise ScenarioError(f"scenario result {key} is invalid")
    scenario = policy.scenarios.get(record["id"])
    if scenario is None:
        raise ScenarioError(f"unknown scenario result: {record['id']}")
    expected_stage, expected_policy_status, expected_command = scenario
    if record["stage"] != expected_stage:
        raise ScenarioError(f"scenario result stage does not match policy: {record['id']}")
    if record["policy_status"] != expected_policy_status:
        raise ScenarioError(f"scenario result policy status does not match: {record['id']}")
    if record["command"] != expected_command:
        raise ScenarioError(f"scenario result command does not match policy: {record['id']}")
    if record["rerun"] != f"scripts/quality-scenarios rerun {record['id']}":
        raise ScenarioError(f"scenario result rerun is invalid: {record['id']}")
    if record["status"] not in RESULT_STATUSES:
        raise ScenarioError(f"scenario result status is invalid: {record['id']}")
    expected_granularity = {
        "instrumented": "scenario",
        "automated": "command",
        "legacy-stage": "legacy-stage",
        "planned": "planned",
        "manual-release": "manual-release",
    }[expected_policy_status]
    if record["granularity"] != expected_granularity:
        raise ScenarioError(f"scenario result granularity is invalid: {record['id']}")
    if expected_policy_status == "planned" and record["status"] != "planned":
        raise ScenarioError(f"planned scenario result has an invalid status: {record['id']}")
    if expected_policy_status == "manual-release" and record["status"] != "manual-release":
        raise ScenarioError(f"manual scenario result has an invalid status: {record['id']}")
    if expected_policy_status not in ("planned", "manual-release") and record["status"] in (
        "planned",
        "manual-release",
    ):
        raise ScenarioError(f"automated scenario result has an invalid status: {record['id']}")
    if record["log"] != "-" and not SAFE_LOG.fullmatch(record["log"]):
        raise ScenarioError(f"scenario result log is unsafe: {record['id']}")
    if len(record["message"]) > 4096:
        raise ScenarioError(f"scenario result message is too large: {record['id']}")
    for key in ("requirements", "journeys"):
        if not isinstance(record[key], list) or not all(
            isinstance(value, str) for value in record[key]
        ):
            raise ScenarioError(f"scenario result {key} is invalid")
        if record[key] != context[record["id"]][key]:
            raise ScenarioError(f"scenario result {key} does not match policy")


def xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def bounded_log_tail(path: Path) -> list[str]:
    try:
        with path.open("rb") as source:
            source.seek(0, os.SEEK_END)
            size = source.tell()
            start = max(0, size - LOG_TAIL_BYTES)
            source.seek(start)
            content = source.read(LOG_TAIL_BYTES)
    except OSError as error:
        raise ScenarioError(f"cannot read scenario failure log: {error}") from error
    if start and b"\n" in content:
        content = content.split(b"\n", 1)[1]
    return content.decode("utf-8", errors="replace").splitlines()[-LOG_TAIL_LINES:]


def assemble(
    *,
    stage_paths: Iterable[Path],
    output_jsonl: Path,
    output_junit: Path,
    repair_bundle: Path,
    run_dir: Path,
    expected_stages: Iterable[str],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    policy = Policy(POLICY_FILE)
    context = scenario_context(policy)
    for path in stage_paths:
        for record in read_jsonl(path, "stage scenario results"):
            validate_result(record, policy, context)
            if record["id"] in seen:
                raise ScenarioError(f"duplicate scenario result: {record['id']}")
            seen.add(record["id"])
            records.append(record)
    selected = set(expected_stages)
    expected = {
        scenario_id
        for scenario_id, (stage, _, _) in policy.scenarios.items()
        if stage in selected
    }
    if seen != expected:
        missing = ",".join(sorted(expected - seen)) or "-"
        unexpected = ",".join(sorted(seen - expected)) or "-"
        raise ScenarioError(
            f"scenario result coverage mismatch: missing={missing} unexpected={unexpected}"
        )
    write_private(output_jsonl, "".join(canonical(record) + "\n" for record in records))
    failures = [record for record in records if record["status"] in SCENARIO_FAILURES]
    skipped = [
        record
        for record in records
        if record["status"] in {"blocked", "not-run", "planned", "manual-release"}
    ]
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        (
            f'<testsuite name="detach-quality-scenarios" tests="{len(records)}" '
            f'failures="{len(failures)}" skipped="{len(skipped)}">'
        ),
    ]
    for record in records:
        body = ""
        if record in failures:
            body = (
                f'<failure message="{xml_escape(record["status"])}">'
                f'{xml_escape(record["rerun"])}</failure>'
            )
        elif record in skipped:
            body = f'<skipped message="{xml_escape(record["status"])}"/>'
        lines.append(
            f'  <testcase classname="quality-scenario.{xml_escape(record["stage"])}" '
            f'name="{xml_escape(record["id"])}" '
            f'time="{record["duration_ms"] / 1000:.3f}">{body}</testcase>'
        )
    lines.append("</testsuite>")
    write_private(output_junit, "\n".join(lines) + "\n")

    if failures:
        bundle_records = []
        for record in failures:
            log_tail: list[str] = []
            if record["log"] != "-":
                log_path = run_dir / record["log"]
                if log_path.is_file() and not log_path.is_symlink():
                    log_tail = bounded_log_tail(log_path)
            bundle_records.append(
                {
                    "id": record["id"],
                    "stage": record["stage"],
                    "status": record["status"],
                    "requirements": record["requirements"],
                    "journeys": record["journeys"],
                    "rerun": record["rerun"],
                    "log": record["log"],
                    "log_tail": log_tail,
                }
            )
        write_private(
            repair_bundle,
            json.dumps(
                {"schema": 1, "failures": bundle_records},
                ensure_ascii=False,
                sort_keys=True,
                indent=2,
            )
            + "\n",
        )
    elif repair_bundle.exists():
        repair_bundle.unlink()
    return records


def run_bounded(
    arguments: list[str], *, environment: dict[str, str], timeout: int
) -> int:
    process = subprocess.Popen(
        arguments,
        cwd=ROOT,
        env=environment,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise


def rerun(scenario_id: str) -> int:
    policy = Policy(POLICY_FILE)
    scenario = policy.scenarios.get(scenario_id)
    if scenario is None:
        raise ScenarioError(f"unknown scenario: {scenario_id}")
    stage, policy_status, command = scenario
    if policy_status not in ("instrumented", "automated", "legacy-stage"):
        raise ScenarioError(f"scenario is not automated: {scenario_id}")
    environment = os.environ.copy()
    timeout = policy.stages_by_name[stage].timeout
    if policy_status in ("instrumented", "legacy-stage"):
        arguments = [str(ROOT / "scripts/quality-gate"), "--stage", stage]
        environment.pop("DETACH_QUALITY_AUTHORITY", None)
        environment.pop("GITHUB_ACTIONS", None)
        timeout += RERUN_FINALIZE_SECONDS
    else:
        arguments = shlex.split(command)
        if not arguments or any(value in {"&&", "||", ";", "|"} for value in arguments):
            raise ScenarioError(f"scenario command is not directly executable: {scenario_id}")
    try:
        return run_bounded(
            arguments,
            environment=environment,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        print(f"quality-scenarios: {scenario_id} timed out after {timeout}s", file=sys.stderr)
        return 124
    except OSError as error:
        raise ScenarioError(f"cannot run scenario {scenario_id}: {error}") from error


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="scripts/quality-scenarios", description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    event = subparsers.add_parser("event")
    event.add_argument("kind", choices=sorted(EVENT_KINDS))
    event.add_argument("scenario_ids", nargs="+")
    rerun_parser = subparsers.add_parser("rerun")
    rerun_parser.add_argument("scenario_id")
    return result


def main(arguments: list[str]) -> int:
    options = parser().parse_args(arguments)
    if options.command == "event":
        for scenario_id in options.scenario_ids:
            record_event(options.kind, scenario_id)
        return 0
    if options.command == "rerun":
        return rerun(options.scenario_id)
    raise ScenarioError("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ScenarioError, PolicyError, OSError, UnicodeError, ValueError) as error:
        fail(str(error))
