#!/usr/bin/env python3
"""Deterministic contracts for release SPDX generation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
COMMIT = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
    stdout=subprocess.PIPE, check=True,
).stdout.strip()


def invoke(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ROOT / "scripts/release-sbom"), *arguments],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=30,
    )


def main() -> None:
    identity = [
        "--version", "9.8.7", "--tag", "v9.8.7",
        "--commit", COMMIT, "--repository", "owner/repository",
    ]
    with tempfile.TemporaryDirectory(prefix="detach-release-sbom.") as directory:
        first = Path(directory) / "first.json"
        second = Path(directory) / "second.json"
        assert invoke(["generate", *identity, "--output", str(first)]).returncode == 0
        assert invoke(["generate", *identity, "--output", str(second)]).returncode == 0
        assert first.read_bytes() == second.read_bytes()
        value = json.loads(first.read_text(encoding="utf-8"))
        assert value["spdxVersion"] == "SPDX-2.3"
        assert value["documentDescribes"] == ["SPDXRef-Package-Detach"]
        names = {package["name"] for package in value["packages"]}
        assert names == {
            "Detach",
            "sparkle",
            "swift-argument-parser",
            "swiftterm",
            "tmux",
            "libevent",
            "utf8proc",
        }
        assert invoke(["validate", *identity, "--input", str(first)]).returncode == 0

        value["packages"][0]["externalRefs"][0]["referenceLocator"] = "git+wrong"
        first.write_text(json.dumps(value) + "\n", encoding="utf-8")
        invalid = invoke(["validate", *identity, "--input", str(first)])
        assert invalid.returncode == 2
        assert "root package provenance is invalid" in invalid.stdout

        value = json.loads(second.read_text(encoding="utf-8"))
        next(package for package in value["packages"] if package["name"] == "tmux")[
            "versionInfo"
        ] = "unexpected"
        second.write_text(json.dumps(value) + "\n", encoding="utf-8")
        changed_input = invoke(["validate", *identity, "--input", str(second)])
        assert changed_input.returncode == 2
        assert "does not match pinned release inputs" in changed_input.stdout

        wrong_tag = invoke([
            "generate", "--version", "9.8.7", "--tag", "v9.8.8",
            "--commit", COMMIT, "--repository", "owner/repository",
            "--output", str(first),
        ])
        assert wrong_tag.returncode == 2
        assert "tag must equal" in wrong_tag.stdout

    print("Release SBOM contracts passed")


if __name__ == "__main__":
    main()
