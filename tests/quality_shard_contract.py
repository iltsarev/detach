#!/usr/bin/env python3
"""Focused contracts for distributed quality evidence."""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from quality_shard import (  # noqa: E402
    ShardError,
    plan_stages,
    safe_evidence_file,
    shard_for,
    shard_plan,
    unique_values,
    validate_inventory,
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class QualityShardContract(unittest.TestCase):
    def test_narrow_plan_has_only_level_zero(self) -> None:
        plan = {"stages": ["static"]}
        self.assertEqual(
            shard_plan(plan),
            [
                {
                    "id": "static",
                    "stages": "static",
                    "level": 0,
                    "needs_app": False,
                    "needs_cache": False,
                    "needs_runtime": False,
                    "needs_metrics": False,
                    "coverage_profile": "",
                }
            ],
        )

    def test_full_plan_is_an_exact_ordered_partition(self) -> None:
        stages = [
            "static",
            "gate-contract",
            "swift",
            "quality-contracts",
            "app",
            "ui-e2e",
            "codex",
            "claude",
            "distribution",
            "tmux-runtime",
            "release-preflight",
            "publish-preflight",
            "release-workflow",
        ]
        shards = shard_plan({"stages": stages})
        self.assertEqual(len(shards), 6)
        flattened = [
            stage
            for shard in shards
            for stage in str(shard["stages"]).split(",")
        ]
        self.assertEqual(set(flattened), set(stages))
        self.assertEqual(len(flattened), len(stages))
        build = shard_for({"stages": stages}, "build-and-coverage")
        self.assertEqual(build["stages"], "swift,quality-contracts,app,ui-e2e")
        self.assertTrue(build["needs_app"])
        self.assertTrue(build["needs_cache"])
        self.assertTrue(build["needs_metrics"])
        self.assertEqual(build["coverage_profile"], "combined")
        contracts = shard_for({"stages": stages}, "contracts-and-runtime")
        self.assertEqual(
            contracts["stages"], "gate-contract,tmux-runtime,release-preflight"
        )
        self.assertTrue(contracts["needs_app"])
        self.assertFalse(contracts["needs_cache"])
        self.assertFalse(contracts["needs_runtime"])
        codex = shard_for({"stages": stages}, "codex")
        self.assertFalse(codex["needs_app"])
        self.assertTrue(codex["needs_cache"])
        self.assertTrue(codex["needs_runtime"])
        self.assertFalse(build["needs_runtime"])

    def test_swift_only_metrics_shard_selects_swift_profile(self) -> None:
        build = shard_for(
            {"stages": ["static", "swift", "quality-contracts"]},
            "build-and-coverage",
        )
        self.assertTrue(build["needs_metrics"])
        self.assertEqual(build["coverage_profile"], "swift")

    def test_unowned_or_malformed_plan_fails_closed(self) -> None:
        with self.assertRaisesRegex(ShardError, "invalid stages"):
            plan_stages({"stages": ["static", "static"]})
        with self.assertRaisesRegex(ShardError, "absent"):
            shard_for({"stages": ["static"]}, "codex")

    def test_duplicate_binding_value_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "binding.tsv"
            path.write_text("schema\t1\nschema\t2\nshard\tstatic\n", encoding="utf-8")
            values = unique_values(path)
        self.assertIsNone(values["schema"])
        self.assertEqual(values["shard"], "static")

    def test_inventory_binds_every_listed_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = "schema\t1\n"
            summary = "header\n"
            artifact = "proof\n"
            artifacts = f"schema\t1\nfile\tproof.txt\t{digest(artifact)}\n"
            (root / "environment.tsv").write_text(environment, encoding="utf-8")
            (root / "summary.tsv").write_text(summary, encoding="utf-8")
            (root / "proof.txt").write_text(artifact, encoding="utf-8")
            (root / "artifacts.tsv").write_text(artifacts, encoding="utf-8")
            manifest = {
                "environment_sha256": digest(environment),
                "summary_sha256": digest(summary),
                "artifacts_sha256": digest(artifacts),
            }
            validate_inventory(root, manifest)
            (root / "proof.txt").write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(ShardError, "artifact digest"):
                validate_inventory(root, manifest)

    def test_symlinked_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("value", encoding="utf-8")
            (root / "link").symlink_to(target)
            with self.assertRaisesRegex(ShardError, "missing or unsafe"):
                safe_evidence_file(root, "link")


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QualityShardContract)
    result = unittest.TextTestRunner(verbosity=0).run(suite)
    if not result.wasSuccessful():
        return 1
    print("Quality shard contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
