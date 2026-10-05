#!/usr/bin/env python3
"""Require reviewed contract deltas and executed evidence for changed requirements."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
from typing import Any

from quality_policy import POLICY_FILE, ROOT, Policy


class ContractError(Exception):
    """A contract change lacks a valid review or acceptance evidence."""


def git(root: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], check=True,
                            capture_output=True, text=True)
    return result.stdout


def snapshot(text: str) -> dict[str, dict[str, Any]]:
    """Read current-schema requirement records for a Git comparison, not execution."""
    rows = [line.split("\t") for line in text.splitlines()]
    if ["schema", "1"] not in rows:
        raise ContractError("unsupported base policy schema")
    requirements = {row[1]: {"spec": row[2], "summary": row[3], "verification": []}
                    for row in rows if row[0] == "requirement" and len(row) == 4}
    for row in rows:
        if row[0] == "verification" and len(row) == 3 and row[1] in requirements:
            requirements[row[1]]["verification"] = row[2].split(",")
    for requirement in requirements.values():
        selected = set(requirement["verification"])
        requirement["checks"] = [row for row in rows
                                 if row[0] in {"scenario", "scenario-test"} and row[1] in selected]
    return requirements


def changed_requirements(root: Path, base: str, policy: Policy) -> dict[str, str]:
    before = snapshot(git(root, "show", f"{base}:quality/policy.tsv"))
    after = snapshot(policy.path.read_text(encoding="utf-8"))
    paths = set(git(root, "diff", "--name-only", base, "HEAD").splitlines())
    changes = {}
    for identity in sorted(before.keys() | after.keys()):
        old, new = before.get(identity), after.get(identity)
        if old is None:
            changes[identity] = "ADDED"
        elif new is None:
            changes[identity] = "REMOVED"
        elif old != new or old["spec"] in paths or new["spec"] in paths:
            changes[identity] = "MODIFIED"
    # A change to a directly mapped test must receive the same contract review.
    for identity, scenarios in policy.verifications.items():
        for scenario in scenarios:
            command = policy.scenarios[scenario][2]
            test_sources = {policy.test_sources[test] for test in policy.scenario_tests.get(scenario, [])}
            if set(shlex.split(command)) & paths or test_sources & paths:
                changes.setdefault(identity, "MODIFIED")
    return changes


def declaration(body: str, required: dict[str, str], policy: Policy) -> list[dict[str, Any]]:
    blocks = re.findall(r"(?m)^```detach-contract\s*\n(.*?)^```\s*$", body, re.S)
    if not blocks and not required:
        return []
    if len(blocks) != 1:
        raise ContractError("PR needs one detach-contract JSON block; use --draft --base BASE")
    try:
        value = json.loads(blocks[0])
    except json.JSONDecodeError as error:
        raise ContractError(f"invalid contract JSON: {error}") from error
    if not isinstance(value, dict) or set(value) != {"schema", "changes"} or value["schema"] != 1 or not isinstance(value["changes"], list):
        raise ContractError("contract declaration schema is invalid")
    seen = set()
    for row in value["changes"]:
        if not isinstance(row, dict) or set(row) != {"requirement", "change", "reason", "scenarios"}:
            raise ContractError("contract change fields are invalid")
        identity = row["requirement"]
        if not isinstance(identity, str) or identity in seen or identity not in required.keys() | policy.requirements.keys():
            raise ContractError("contract change requirement is unknown or duplicate")
        seen.add(identity)
        if row["change"] not in {"ADDED", "MODIFIED", "REMOVED", "UNCHANGED"}:
            raise ContractError(f"invalid change kind: {identity}")
        expected = required.get(identity)
        if expected in {"ADDED", "REMOVED"} and row["change"] != expected:
            raise ContractError(f"{identity} must be declared {expected}")
        if expected != "REMOVED" and row["change"] == "REMOVED":
            raise ContractError(f"{identity} still exists")
        reason = row["reason"]
        if not isinstance(reason, str) or len(reason.strip()) < 20 or len(reason) > 2000 or "TODO" in reason:
            raise ContractError(f"{identity} needs a specific reviewed reason")
        scenarios = row["scenarios"]
        if not isinstance(scenarios, list) or not scenarios or any(not isinstance(item, str) for item in scenarios) or len(set(scenarios)) != len(scenarios):
            raise ContractError(f"{identity} needs exact acceptance scenarios")
        allowed = set(policy.verifications.get(identity, ()))
        if expected == "REMOVED":
            # Removal needs an explicit current replacement proof. The reason
            # explains the replacement; its semantic validity remains review work.
            allowed = set(policy.scenarios)
        if not set(scenarios) <= allowed or any(policy.scenarios[item][1] not in {"instrumented", "test-cases"} for item in scenarios):
            raise ContractError(f"{identity} needs direct mapped automated evidence")
    missing = required.keys() - seen
    if missing:
        raise ContractError("missing contract deltas: " + ", ".join(sorted(missing)))
    return value["changes"]


def review(root: Path, base: str, policy: Policy, body: str,
           evidence: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    required = changed_requirements(root, base, policy)
    rows = declaration(body, required, policy)
    if evidence is not None:
        by_id = {record["id"]: record for record in evidence}
        if len(by_id) != len(evidence):
            raise ContractError("duplicate scenario evidence")
        for row in rows:
            for scenario in row["scenarios"]:
                record = by_id.get(scenario)
                if not record or record["status"] != "passed" or record["granularity"] not in {"scenario", "test-cases"}:
                    raise ContractError(f"{row['requirement']} has no passed direct evidence: {scenario}")
    return {"schema": 1, "source_commit": git(root, "rev-parse", "HEAD").strip(),
            "base_commit": git(root, "rev-parse", base).strip(), "policy": policy.version,
            "body_sha256": hashlib.sha256(body.encode()).hexdigest(),
            "status": "passed" if evidence is not None else "reviewed",
            "changes": rows}


def event_body(path: Path, root: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ContractError("PR event is missing or unsafe")
    event = json.loads(path.read_text(encoding="utf-8"))
    pr = event.get("pull_request", {})
    if pr.get("head", {}).get("sha") != git(root, "rev-parse", "HEAD^2").strip():
        raise ContractError("contract review does not name the tested PR head")
    body = pr.get("body") or ""
    if not isinstance(body, str):
        raise ContractError("PR body is not text")
    return body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--draft", action="store_true")
    parser.add_argument("--event-json", type=Path)
    parser.add_argument("--body-file", type=Path)
    args = parser.parse_args()
    policy = Policy(POLICY_FILE)
    if args.draft:
        changes = []
        for identity, kind in changed_requirements(ROOT, args.base, policy).items():
            candidates = policy.verifications.get(identity, tuple(policy.scenarios))
            automated = [item for item in candidates if policy.scenarios[item][1] in {"instrumented", "test-cases"}]
            changes.append({"requirement": identity, "change": kind,
                            "reason": "TODO: explain the reviewed before/after contract or why it is unchanged.",
                            "scenarios": automated[:1]})
        print("```detach-contract\n" + json.dumps({"schema": 1, "changes": changes}, indent=2) + "\n```")
    else:
        body = event_body(args.event_json, ROOT) if args.event_json else args.body_file.read_text(encoding="utf-8") if args.body_file else ""
        result = review(ROOT, args.base, policy, body)
        print(f"Contract review validated: {len(result['changes'])} requirements; execution evidence remains required")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"quality-contract-change: {error}", file=sys.stderr)
        raise SystemExit(2)
