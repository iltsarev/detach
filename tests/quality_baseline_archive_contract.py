#!/usr/bin/env python3
"""Contracts for durable baseline bytes and their original hosted identity."""
from pathlib import Path
import hashlib
import json
import lzma
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tests"))
import quality_baseline_archive as archive
from quality_metrics import build_metrics, collect_coverage, load_baseline
from quality_metrics_contract import POLICY, BASE_COMMIT, coverage_document, test_lines, create_baseline, write_json


def rejects(operation, label):
    try:
        operation()
    except Exception:
        return
    raise AssertionError(f"archive accepted {label}")


def main():
    with tempfile.TemporaryDirectory(prefix="detach-baseline-archive-") as raw:
        root = Path(raw)
        metrics, _ = build_metrics(collect_coverage(coverage_document()), set(test_lines()),
                                   POLICY, BASE_COMMIT, "", None, "none",
                                   changed_override={}, allow_incomplete_sources=True)
        source = root / "metrics.json"
        write_json(source, metrics)
        source.write_bytes(source.read_bytes().replace(b"\n", b"\r\n"))
        prior = root / "prior"
        create_baseline(prior, source)
        payload = archive.pack(prior, "owner/repository", 123)
        metadata = {"head_branch": "main", "event": "push", "status": "completed",
                    "conclusion": "success", "path": ".github/workflows/quality-gates.yml",
                    "head_sha": BASE_COMMIT}
        with patch.object(archive, "gh", return_value=json.dumps(metadata)):
            restored = archive.unpack(payload, "owner/repository", root / "restored")
            assert (restored / "run/quality-metrics.json").read_bytes() == source.read_bytes()
            assert load_baseline(restored, "swift")[2] == BASE_COMMIT
            assert archive.unpack(payload, "owner/repository", root / "restored") == restored
            (root / "occupied/123").mkdir(parents=True)
            rejects(lambda: archive.unpack(payload, "owner/repository", root / "occupied"), "a different existing destination")
            rejects(lambda: archive.unpack(payload, "other/repository", root / "foreign"), "a foreign repository")
            rejects(lambda: archive.unpack(payload[:-2], "owner/repository", root / "truncated"), "a truncated archive")
            value = json.loads(lzma.decompress(payload))
            value["files"]["../outside"] = "bad"
            bad = lzma.compress(json.dumps(value).encode())
            rejects(lambda: archive.unpack(bad, "owner/repository", root / "traversal"), "path traversal")
            del value["files"]["../outside"]
            value["files"]["quality-metrics.json"] += " "
            bad = lzma.compress(json.dumps(value).encode())
            rejects(lambda: archive.unpack(bad, "owner/repository", root / "changed"), "changed metrics bytes")
            (root / "linked").symlink_to(root / "restored", target_is_directory=True)
            rejects(lambda: archive.unpack(payload, "owner/repository", root / "linked"), "a symlink output")
        for field, wrong in (("head_sha", "f" * 40), ("conclusion", "failure"),
                             ("head_branch", "topic"), ("event", "pull_request"),
                             ("path", ".github/workflows/other.yml")):
            with patch.object(archive, "gh", return_value=json.dumps({**metadata, field: wrong})):
                rejects(lambda: archive.unpack(payload, "owner/repository", root / field), field)
                assert not (root / field / "123").exists()
        def profile_root(name, commit, profile):
            path = root / (name + ".json")
            write_json(path, {**metrics, "source_commit": commit, "coverage_profile": profile})
            directory = root / name
            create_baseline(directory, path, source_commit=commit)
            return directory

        combined_root = profile_root("combined", BASE_COMMIT, "combined")
        newer_swift = profile_root("newer-swift", "c" * 40, "swift")
        current = profile_root("current", "b" * 40, "swift")
        saved = {
            "combined": archive.pack(combined_root, "owner/repository", 100),
            "swift": archive.pack(newer_swift, "owner/repository", 300),
        }
        identities = {100: BASE_COMMIT, 200: "b" * 40, 300: "c" * 40, 400: "b" * 40}
        def hosted_run(executable, arguments):
            identity = int(arguments[-1].rsplit("/", 1)[1])
            return json.dumps({**metadata, "head_sha": identities[identity]})
        with patch.object(archive, "gh", side_effect=hosted_run), \
             patch.object(archive, "public_payload", side_effect=lambda repository, profile: saved[profile]):
            output = root / "dashboard"
            output.mkdir()
            archive.dashboard_archives(output, current / "run", None, "owner/repository", 200)
            for profile, expected in (("combined", 100), ("swift", 300)):
                restored = archive.unpack((output / archive.public_name(profile)).read_bytes(),
                                          "owner/repository", root / ("first-" + profile))
                assert int(restored.name) == expected
                load_baseline(restored, profile)
            archive.dashboard_archives(output, current / "run", None, "owner/repository", 400)
            restored = archive.unpack((output / archive.public_name("swift")).read_bytes(),
                                      "owner/repository", root / "advanced")
            assert restored.name == "400"

        with patch.object(archive, "MAX_BYTES", 32):
            rejects(lambda: archive.unpack(payload, "owner/repository", root / "huge"), "an oversized archive")
    print("Durable quality baseline archive contracts passed")


if __name__ == "__main__":
    main()
