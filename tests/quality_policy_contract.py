#!/usr/bin/env python3
"""Deterministic contracts for specification traceability in the quality policy."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from quality_policy import Policy, PolicyError  # noqa: E402


POLICY = ROOT / "quality/policy.tsv"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expect_error(source: str, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="detach-quality-policy-contract.") as directory:
        candidate = Path(directory) / "policy.tsv"
        candidate.write_text(source, encoding="utf-8")
        try:
            Policy(candidate)
        except PolicyError as error:
            require(expected in str(error), f"unexpected policy error: {error}")
        else:
            raise AssertionError(f"policy accepted invalid input: {expected}")


def main() -> None:
    source = POLICY.read_text(encoding="utf-8")
    policy = Policy(POLICY)
    specs = policy.specification_document()

    require(len(specs) == 7, "expected seven current specifications")
    require(
        {spec["id"] for spec in specs}
        == {
            "documentation", "runtime", "state", "power", "app",
            "app-setup", "release",
        },
        "specification identities changed unexpectedly",
    )
    require(
        policy.limits["routed_spec_warning_bytes"] == 12_288
        and policy.limits["routed_spec_limit_bytes"] == 16_384,
        "routed specification size limits changed unexpectedly",
    )
    route_cases = (
        (
            "app/Sources/DetachKit/DetachStateCommand.swift",
            "state-source", "safe", "docs/specs/state.md",
            "app/Sources/DetachKit/DetachState*.swift",
            "session-state",
        ),
        (
            "app/Sources/DetachKit/Session.swift",
            "state-source", "safe", "docs/specs/state.md",
            "app/Sources/DetachKit/Session.swift",
            "session-state",
        ),
        (
            "app/Sources/DetachKit/SessionEvents.swift",
            "state-source", "safe", "docs/specs/state.md",
            "app/Sources/DetachKit/SessionEvents.swift",
            "session-state",
        ),
        (
            "app/Sources/DetachKit/SessionHealth.swift",
            "session-health-source", "safe", "docs/specs/app.md",
            "app/Sources/DetachKit/SessionHealth.swift",
            "session-lifecycle,session-state,app-experience",
        ),
        (
            "app/Sources/DetachKit/SessionMaintenance.swift",
            "state-source", "safe", "docs/specs/state.md",
            "app/Sources/DetachKit/SessionMaintenance.swift",
            "session-state",
        ),
        (
            "app/Sources/DetachKit/SessionStore.swift",
            "state-runtime", "safe", "docs/specs/runtime.md",
            "app/Sources/DetachKit/Session*.swift",
            "session-lifecycle,session-state",
        ),
        (
            "app/Sources/DetachKit/BoundedProcessRunner.swift",
            "bounded-process-source", "both", "docs/specs/runtime.md",
            "app/Sources/DetachKit/BoundedProcessRunner.swift",
            "session-lifecycle,session-state,power-protection",
        ),
        (
            "app/Sources/DetachApp/DetachApp.swift",
            "app-shell-source", "install", "docs/specs/app.md",
            "app/Sources/DetachApp/DetachApp.swift",
            "app-experience,onboarding,settings,update",
        ),
        (
            "app/Sources/DetachApp/InstallationStore.swift",
            "installation-store-source", "both", "docs/specs/power.md",
            "app/Sources/DetachApp/InstallationStore.swift",
            "power-protection,onboarding,settings,update,diagnostics,installation",
        ),
        (
            "app/Sources/DetachApp/PowerHelperService.swift",
            "power", "both", "docs/specs/power.md",
            "app/Sources/DetachApp/PowerHelper*.swift",
            "power-protection",
        ),
        (
            "app/Sources/DetachApp/OnboardingView.swift",
            "onboarding-source", "install", "docs/specs/app-setup.md",
            "app/Sources/DetachApp/Onboarding*.swift",
            "onboarding",
        ),
        (
            "app/Sources/DetachApp/RootView.swift",
            "root-view-source", "safe", "docs/specs/app.md",
            "app/Sources/DetachApp/RootView.swift",
            "app-experience,onboarding",
        ),
        (
            "app/Sources/DetachKit/DetachCLI.swift",
            "runtime-source", "safe", "docs/specs/runtime.md",
            "app/Sources/DetachKit/DetachCLI.swift",
            "session-lifecycle,session-state",
        ),
        (
            "app/Sources/DetachApp/UIE2ETestDriver.swift",
            "ui-e2e-source", "safe", "docs/specs/app.md",
            "app/Sources/DetachApp/UIE2E*.swift",
            "app-experience,onboarding,settings",
        ),
    )
    for path, test_domain, release_domain, spec, pattern, capabilities in route_cases:
        classification = policy.classify(path)
        require(
            (
                classification.test_domain,
                classification.release_domain,
                classification.spec,
                classification.pattern,
                classification.capabilities,
            ) == (test_domain, release_domain, spec, pattern, capabilities),
            f"source route changed unexpectedly: {path}",
        )
    health_impact = policy.impact(["app/Sources/DetachKit/SessionHealth.swift"])
    require(
        {"swift", "app", "codex", "claude", "distribution", "tmux-runtime"}
        <= set(health_impact.stages),
        "session health changes omit runtime ownership evidence",
    )
    require(
        all("status" not in spec for spec in specs),
        "the runtime policy contains specification history state",
    )
    require(
        policy.render_spec_traceability() == policy.render_spec_traceability(),
        "the specification view is not deterministic",
    )

    requirements = {
        requirement["id"]: requirement
        for spec in specs
        for requirement in spec["requirements"]
    }
    require(
        set(requirements) == set(policy.requirements),
        "the specification view omits a requirement",
    )
    require(
        requirements["QC-RUNTIME-STATE"]["journeys"]
        == ["J-SESSION-PERSIST", "J-STATE-CLEANUP"],
        "typed state evidence does not cover persistence and safe cleanup",
    )
    require(
        requirements["QC-RUNTIME-STORAGE"]["journeys"]
        == ["J-STATE-RECOVER"],
        "validated restore evidence is not owned by the state recovery journey",
    )
    for identifier, requirement in requirements.items():
        require(requirement["journeys"], f"{identifier} has no user journey")
        automated = [
            scenario
            for scenario in requirement["scenarios"]
            if scenario["status"] not in {"planned", "manual-release"}
        ]
        require(automated, f"{identifier} has no automated scenario")

    expect_error(
        source.replace(
            "limit\trouted_spec_warning_bytes\t12288",
            "limit\trouted_spec_warning_bytes\t16384",
            1,
        ),
        "routed spec warning must be below the hard limit",
    )
    expect_error(
        source.replace(
            "spec\tdocumentation\tdocs/specs/documentation.md\t",
            "spec\tdocumentation\tdocs/specs/documentation.md\thistorical\t",
            1,
        ),
        "spec requires 3 values",
    )
    expect_error(
        "\n".join(
            line
            for line in source.splitlines()
            if not line.startswith("spec\tdocumentation\t")
        )
        + "\n",
        "route references unknown spec: docs/specs/documentation.md",
    )
    expect_error(
        source.replace(
            "journey\tJ-POWER-ENABLE\tpower-protection\t"
            "QC-POWER-ASSERTION,QC-POWER-LEASE,QC-POWER-CLI,QC-POWER-PLATFORM\t",
            "journey\tJ-POWER-ENABLE\tpower-protection\t"
            "QC-POWER-ASSERTION,QC-POWER-LEASE,QC-POWER-PLATFORM\t",
            1,
        ),
        "capability requirement has no journey: power-protection#QC-POWER-CLI",
    )
    expect_error(
        source.replace(
            "requirement\tQC-APP-SETTINGS\tdocs/specs/app-setup.md\t",
            "requirement\tQC-APP-SETTINGS\tdocs/specs/runtime.md\t",
            1,
        ),
        "capability settings references requirement from another spec: QC-APP-SETTINGS",
    )
    expect_error(
        source.replace(
            "scenario\tSC-APP-SETTINGS-UNIT\tswift\tlegacy-stage\t",
            "scenario\tSC-APP-SETTINGS-UNIT\tswift\tplanned\t",
            1,
        ).replace(
            "scenario\tSC-UI-SETTINGS\tui-e2e\tinstrumented\t",
            "scenario\tSC-UI-SETTINGS\tui-e2e\tplanned\t",
            1,
        ).replace(
            ",SC-UI-SETTINGS\tThe packaged real-control journeys own this test harness.",
            "\tThe packaged real-control journeys own this test harness.",
            1,
        ).replace(
            "\tSC-UI-SETTINGS\tThe packaged Settings journey covers its semantic control.",
            "\tSC-UI-DASHBOARD\tThe packaged Settings journey covers its semantic control.",
            1,
        ).replace(
            "\tSC-UI-SETTINGS\tXCTest cannot map SwiftUI task modifiers. Unit tests cover the extracted System heartbeat loop.",
            "\tSC-UI-DASHBOARD\tXCTest cannot map SwiftUI task modifiers. Unit tests cover the extracted System heartbeat loop.",
            1,
        ),
        "requirement has no automated verification scenario: QC-APP-SETTINGS",
    )

    print("Quality policy Python contracts passed")


if __name__ == "__main__":
    main()
