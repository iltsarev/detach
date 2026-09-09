#!/usr/bin/env python3
"""Static fail-closed contracts for repository security automation."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/security.yml"
DEPENDABOT = ROOT / ".github/dependabot.yml"
PACKAGE = ROOT / "app/Package.swift"
PAGES_WORKFLOWS = (
    ROOT / ".github/workflows/quality-gates.yml",
    ROOT / ".github/workflows/quality-care.yml",
    ROOT / ".github/workflows/quality-mutations.yml",
)
PINNED_ACTION = re.compile(
    r"(?:-\s+)?uses:\s+[^\s@]+@[0-9a-f]{40}"
    r"(?:\s+#\s+v[0-9]+(?:\.[0-9]+){0,2})?$"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    dependabot = DEPENDABOT.read_text(encoding="utf-8")
    package = PACKAGE.read_text(encoding="utf-8")
    uses = [line.strip() for line in workflow.splitlines() if "uses:" in line]
    require(uses and all(PINNED_ACTION.fullmatch(line) for line in uses),
            "every security Action must use an immutable commit")
    require("languages: actions" in workflow, "workflow analysis is missing")
    require("languages: swift" in workflow, "Swift analysis is missing")
    require("build-mode: manual" in workflow, "Swift must use an explicit build")
    cache = workflow.index("Restore the Swift dependency graph")
    resolve = workflow.index("Resolve the locked Swift dependencies")
    clean = workflow.index("Remove cached products before tracing")
    swift_init = workflow.index("Initialize Swift analysis")
    build = workflow.index("Build all Swift products for analysis")
    swift_analyze = workflow.index("Analyze Swift source")
    require(cache < resolve < clean < swift_init < build < swift_analyze,
            "Swift dependency preparation, supported build, and analysis are out of order")
    require("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9" in workflow,
            "Swift analysis must restore the immutable quality-gate cache")
    require("swift package --package-path app --force-resolved-versions resolve" in workflow,
            "Swift analysis must resolve the tracked lock before tracing")
    require("swift package --package-path app clean" in workflow,
            "Swift analysis must rebuild repository sources after cache restore")
    repository_modules = {
        path.name
        for path in (ROOT / "app/Sources").iterdir()
        if path.is_dir() and list(path.rglob("*.swift"))
    }
    declared_modules = set(re.findall(
        r"\.(?:target|executableTarget)\(\s*name:\s*\"([A-Za-z0-9_]+)\"",
        package,
    ))
    require(repository_modules,
            "Swift analysis has no production source modules")
    require(repository_modules <= declared_modules,
            "Package.swift does not declare every production source module")
    traced_zone = workflow[swift_init:swift_analyze]
    require(traced_zone.count("swift build") == 1,
            "Swift analysis must use one supported SwiftPM build")
    require("--target" not in traced_zone and "--product" not in traced_zone,
            "Swift analysis must build the complete package graph")
    require(not re.search(r"(?m)^\s+swiftc(?:\s|$)", traced_zone)
            and "swift_codeql_build.py" not in workflow,
            "Swift analysis must not bypass SwiftPM with direct compiler commands")
    require("matrix:" not in workflow,
            "Swift analysis must not repeat package preparation in a matrix")
    require("category: /language:swift" in workflow,
            "Swift analysis must publish one stable category")
    require("--arch arm64" in traced_zone,
            "Swift analysis must build only arm64")
    require("--jobs 3" in traced_zone,
            "Swift analysis must bound compiler workers")
    for option in ("--disable-index-store", "--disable-sandbox",
                   "--force-resolved-versions", "-whole-module-optimization",
                   "-num-threads", "-gnone"):
        require(option in traced_zone, f"Swift build is missing {option}")
    require("timeout-minutes: 5" in workflow, "workflow analysis deadline is missing")
    require("timeout-minutes: 30" in workflow, "Swift analysis deadline is missing")
    require("security-events: write" in workflow, "CodeQL cannot publish results")
    require("pull_request:" not in workflow, "security care must not extend PR feedback")
    require("\n  push:" not in workflow,
            "25-minute security care must not run after every merge")
    require("workflow_dispatch:" in workflow and "schedule:" in workflow,
            "security care must support weekly and explicit runs")
    evidence = workflow.index("  security-evidence:")
    dashboard = workflow.index("  quality-dashboard:")
    require(swift_analyze < evidence < dashboard,
            "security evidence and dashboard jobs are out of order")
    evidence_zone = workflow[evidence:dashboard]
    require("if: always()" in evidence_zone
            and "- actions" in evidence_zone and "- swift" in evidence_zone,
            "security evidence must record both completed analysis jobs")
    require("scripts/quality-security create" in evidence_zone,
            "security evidence must use the typed Python boundary")
    require("${{ needs.actions.result }}" in evidence_zone
            and "${{ needs.swift.result }}" in evidence_zone,
            "security evidence does not bind exact job results")
    require("quality-security-${{ github.run_id }}-${{ github.run_attempt }}" in evidence_zone,
            "security evidence artifact identity is not exact")
    upload = evidence_zone.index("Upload security result")
    enforce = evidence_zone.index("Enforce successful analysis")
    require(upload < enforce and "--require-pass" in evidence_zone[enforce:],
            "failed security results must upload before enforcement")
    dashboard_zone = workflow[dashboard:]
    require("github.ref == 'refs/heads/main'" in dashboard_zone,
            "security evidence from a topic branch can replace the main dashboard")
    require("--security-summary app/build/quality-security/summary.json" in dashboard_zone,
            "the security dashboard does not consume the exact current artifact")
    require("timeout-minutes: 3" in dashboard_zone,
            "security dashboard deadline is missing")
    dashboard_workflows = (WORKFLOW, *PAGES_WORKFLOWS)
    for path in dashboard_workflows:
        pages_workflow = path.read_text(encoding="utf-8")
        if path in PAGES_WORKFLOWS:
            require("scripts/quality-security latest --optional" in pages_workflow,
                    f"{path.name} does not preserve the latest security result")
        require("--security-summary" in pages_workflow,
                f"{path.name} does not pass security evidence to the dashboard")
        require('delimiter="detach-$(uuidgen)"' in pages_workflow
                and "printf 'summary<<%s\\n'" in pages_workflow,
                f"{path.name} writes summary outputs without a safe delimiter")
        require("<<EOF" not in pages_workflow,
                f"{path.name} uses a predictable output delimiter")
        require('if [ -n "${{' not in pages_workflow
                and "printf 'summary=%s\\n'" not in pages_workflow,
                f"{path.name} interpolates downloaded paths into the shell")
    require("release-version" not in workflow and "notary" not in workflow,
            "security care can enter a release path")
    require("version: 2" in dependabot, "Dependabot schema is missing")
    require("package-ecosystem: github-actions" in dependabot,
            "GitHub Actions updates are missing")
    require("package-ecosystem: swift" in dependabot,
            "Swift updates are missing")
    require("directory: /app" in dependabot, "Swift package directory is wrong")
    require(dependabot.count("interval: weekly") == 2,
            "dependency updates must use one bounded weekly cadence")
    require(dependabot.count("open-pull-requests-limit: 1") == 2,
            "each dependency ecosystem must allow only one open update pull request")
    require("actions:" in dependabot and "swift-packages:" in dependabot,
            "dependency updates must be grouped by ecosystem")
    require(dependabot.count('          - "*"') == 2,
            "each dependency group must cover its complete ecosystem")
    print("Security automation contracts passed")


if __name__ == "__main__":
    main()
