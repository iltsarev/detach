#!/usr/bin/env python3
"""Focused contracts for exact executable quality products."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

import quality_products  # noqa: E402


class QualityProductsContract(unittest.TestCase):
    def fixture(self, root: Path) -> None:
        first = root / "products/tests"
        second = root / "products/ui"
        first.mkdir(parents=True)
        second.mkdir(parents=True)
        (first / "binary").write_text("tests\n", encoding="utf-8")
        (first / "binary").chmod(0o755)
        (first / "Current").symlink_to("binary")
        (second / "binary").write_text("ui\n", encoding="utf-8")
        (second / "binary").chmod(0o755)

    def context(self):
        return (
            patch.object(
                quality_products,
                "PRODUCT_PATHS",
                (("tests", Path("products/tests")), ("ui", Path("products/ui"))),
            ),
            patch.object(quality_products, "EXECUTABLE_PATHS", ()),
            patch("quality_products.stage_runtime_products", return_value=None),
            patch("quality_products.source_fingerprint", return_value="a" * 64),
            patch(
                "quality_products.toolchain_document",
                return_value={"architecture": "arm64", "swift": "test", "xcode": "test"},
            ),
            patch.object(
                quality_products,
                "MANIFEST_RELATIVE",
                Path("products/manifest.json"),
            ),
        )

    def test_publish_verify_and_tamper_detection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            patches = self.context()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
                self.assertEqual(quality_products.publish(root), 0)
                self.assertEqual(quality_products.verify(root), 0)
                manifest = json.loads(
                    (root / "products/manifest.json").read_text(encoding="utf-8")
                )
                self.assertEqual(manifest["schema"], 1)
                self.assertEqual(set(manifest["products"]), {"tests", "ui"})
                (root / "products/tests/binary").write_text("changed\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    quality_products.ProductError, "inventory does not match"
                ):
                    quality_products.verify(root)

    def test_escaping_symlink_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            outside = root / "outside"
            outside.write_text("outside\n", encoding="utf-8")
            (root / "products/tests/escape").symlink_to("../../outside")
            patches = self.context()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
                with self.assertRaisesRegex(
                    quality_products.ProductError, "symlink escapes"
                ):
                    quality_products.publish(root)

    def test_manifest_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            (root / "products/manifest-target").write_text("{}\n", encoding="utf-8")
            (root / "products/manifest.json").symlink_to("manifest-target")
            patches = self.context()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
                with self.assertRaisesRegex(quality_products.ProductError, "symlink"):
                    quality_products.publish(root)

    def test_runtime_products_are_staged_from_the_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / quality_products.RUNTIME_SOURCE
            source.mkdir(parents=True)
            for name in quality_products.RUNTIME_PRODUCTS:
                (source / name).write_text(f"{name}\n", encoding="utf-8")
                (source / name).chmod(0o755)
            quality_products.stage_runtime_products(root)
            for name in quality_products.RUNTIME_PRODUCTS:
                staged = root / quality_products.RUNTIME_PRODUCT_ROOT / name
                self.assertEqual(staged.read_text(encoding="utf-8"), f"{name}\n")
                self.assertTrue(os.access(staged, os.X_OK))
            (source / "tmux").unlink()
            with self.assertRaisesRegex(
                quality_products.ProductError, "missing or unsafe: tmux"
            ):
                quality_products.stage_runtime_products(root)

    def test_exact_coverage_inputs_fail_closed(self) -> None:
        environment = os.environ.copy()
        environment.pop("DETACH_SWIFT_TEST_BINARY", None)
        environment.pop("DETACH_SWIFT_TEST_PROFILE", None)
        environment["DETACH_SWIFT_TEST_BINARY"] = "/tmp/not-a-quality-product"
        missing_pair = subprocess.run(
            [str(ROOT / "tests/quality-contracts.sh")],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(missing_pair.returncode, 2)
        self.assertIn("must occur together", missing_pair.stderr)

        environment["DETACH_SWIFT_TEST_PROFILE"] = "/tmp/not-quality-evidence"
        unsafe_profile = subprocess.run(
            [str(ROOT / "tests/quality-contracts.sh")],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(unsafe_profile.returncode, 2)
        self.assertIn("not a quality evidence path", unsafe_profile.stderr)


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QualityProductsContract)
    result = unittest.TextTestRunner(verbosity=0).run(suite)
    if not result.wasSuccessful():
        return 1
    print("Quality executable product contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
