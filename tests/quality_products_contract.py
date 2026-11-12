#!/usr/bin/env python3
"""Focused contracts for exact executable quality products."""

from __future__ import annotations

import json
from contextlib import ExitStack
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

import quality_products  # noqa: E402


class QualityProductsContract(unittest.TestCase):
    def test_prepared_commit_cannot_label_a_dirty_checkout_as_the_tested_head(self):
        with patch("quality_products.command_text", side_effect=["b" * 40, "app/Resources/icon"]):
            with self.assertRaisesRegex(quality_products.ProductError, "tracked changes"):
                quality_products.source_commit(ROOT)

    def prepared_context(self):
        stack = ExitStack()
        stack.enter_context(patch("quality_products.source_commit", return_value="b" * 40))
        stack.enter_context(patch("quality_products.source_fingerprint", return_value="a" * 64))
        stack.enter_context(patch("quality_products.toolchain_document", return_value={"architecture": "arm64"}))
        stack.enter_context(patch("quality_products.command_text", return_value="arm64"))
        stack.enter_context(patch("quality_products.subprocess.run", return_value=SimpleNamespace(returncode=0)))
        return stack

    def prepared_fixture(self, root, parts=("swift", "app", "ui")):
        for part in parts:
            for name, relative in quality_products.PART_PATHS[part]:
                target = root / relative
                if name == "ui-app":
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("coverage app")
                else:
                    target.mkdir(parents=True, exist_ok=True)
                    (target / "data").write_text(name)
            for relative in quality_products.PART_EXECUTABLES[part]:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(relative.name)
                target.chmod(0o755)
        if "swift" in parts:
            bundle = root / quality_products.PRODUCT_PATHS[0][1]
            (bundle / "Empty").mkdir()
            (bundle / "Current").symlink_to("Contents/MacOS/DetachAppPackageTests")
            if hasattr(os, "lchmod"):
                os.lchmod(bundle / "Current", 0o755)
        if "app" in parts:
            for name in quality_products.RUNTIME_PRODUCTS:
                target = root / quality_products.RUNTIME_SOURCE / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(name)
                target.chmod(0o755)

    def rewrite_archive(self, path, transform):
        with tarfile.open(path, "r:gz") as archive:
            records = [(member, archive.extractfile(member).read() if member.isfile() else None)
                       for member in archive.getmembers()]
        records = transform(records)
        with tarfile.open(path, "w:gz") as archive:
            for member, data in records:
                if data is not None:
                    member.size = len(data)
                archive.addfile(member, io.BytesIO(data) if data is not None else None)

    def test_prepared_parts_restore_bytes_modes_links_and_verified_bindings(self):
        with tempfile.TemporaryDirectory() as temporary, self.prepared_context():
            work = Path(temporary)
            producer, consumer, archives = work / "producer", work / "consumer", work / "archives"
            self.prepared_fixture(producer)
            first = producer / quality_products.PRODUCT_PATHS[0][1] / "data"
            second = producer / quality_products.PRODUCT_PATHS[1][1] / "linked-data"
            os.link(first, second)
            for part in quality_products.PART_PATHS:
                quality_products.pack_part(producer, part, archives / f"{part}.tar.gz")
                with tarfile.open(archives / f"{part}.tar.gz", "r:gz") as archive:
                    for member in archive.getmembers():
                        self.assertEqual((member.uid, member.gid, member.uname, member.gname), (0, 0, "", ""))
            bindings = quality_products.restore_parts(consumer, archives, ("swift", "app", "ui"))
            self.assertEqual(bindings, {
                "DETACH_QUALITY_EXACT_APP": "1", "DETACH_QUALITY_EXACT_RUNTIME": "1",
                "DETACH_QUALITY_EXACT_SWIFT": "1", "DETACH_QUALITY_EXACT_PRODUCTS": "1",
            })
            for part in quality_products.PART_PATHS:
                quality_products.verify_part(consumer, part)
                self.assertEqual(quality_products.part_inventory(producer, part),
                                 quality_products.part_inventory(consumer, part))
            quality_products.verify(consumer)
            quality_products.verify(consumer, runtime_only=True)

    def test_swift_only_preparation_cannot_bind_an_app_or_full_products(self):
        with tempfile.TemporaryDirectory() as temporary, self.prepared_context():
            work = Path(temporary)
            self.prepared_fixture(work / "producer", ("swift",))
            quality_products.pack_part(work / "producer", "swift", work / "archives/swift.tar.gz")
            self.assertEqual(quality_products.restore_parts(work / "consumer", work / "archives", ("swift",)),
                             {"DETACH_QUALITY_EXACT_SWIFT": "1"})

    def test_failed_app_verification_cannot_publish_a_reuse_binding(self):
        with tempfile.TemporaryDirectory() as temporary, self.prepared_context():
            work = Path(temporary)
            self.prepared_fixture(work / "producer", ("app",))
            quality_products.pack_part(work / "producer", "app", work / "archives/app.tar.gz")
            with patch("quality_products.subprocess.run", return_value=SimpleNamespace(returncode=1)), patch(
                "quality_products.publish"
            ) as publish:
                with self.assertRaisesRegex(quality_products.ProductError, "app verification failed"):
                    quality_products.restore_parts(work / "consumer", work / "archives", ("app",))
                publish.assert_not_called()

    def test_native_verifier_output_cannot_enter_github_environment_bindings(self):
        with tempfile.TemporaryDirectory() as temporary, self.prepared_context():
            work = Path(temporary)
            self.prepared_fixture(work / "producer", ("app",))
            quality_products.pack_part(work / "producer", "app", work / "archives/app.tar.gz")
            with patch("quality_products.subprocess.run", return_value=SimpleNamespace(returncode=0)) as run:
                quality_products.restore_parts(work / "consumer", work / "archives", ("app",))
                self.assertIs(run.call_args.kwargs["stdout"], sys.stderr)

    def test_prepared_source_commit_content_and_toolchain_must_match(self):
        for field, wrong in [("source_commit", "c" * 40), ("source_fingerprint", "d" * 64),
                             ("toolchain", {"architecture": "x86_64"}), ("part", "ui")]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary, self.prepared_context():
                work = Path(temporary)
                self.prepared_fixture(work / "producer", ("swift",))
                archive = work / "archives/swift.tar.gz"
                quality_products.pack_part(work / "producer", "swift", archive)
                def change(records):
                    member, data = records[0]
                    document = json.loads(data)
                    document[field] = wrong
                    records[0] = member, json.dumps(document).encode()
                    return records
                self.rewrite_archive(archive, change)
                with self.assertRaisesRegex(quality_products.ProductError, "identity"):
                    quality_products.restore_parts(work / "consumer", archive.parent, ("swift",))

    def test_prepared_parts_reject_tampered_bytes_modes_and_extra_files(self):
        for change_kind in ("bytes", "mode", "directory-mode", "extra", "duplicate", "traversal", "hardlink", "symlink"):
            with self.subTest(change=change_kind), tempfile.TemporaryDirectory() as temporary, self.prepared_context():
                work = Path(temporary)
                self.prepared_fixture(work / "producer", ("swift",))
                archive = work / "archives/swift.tar.gz"
                quality_products.pack_part(work / "producer", "swift", archive)
                def change(records):
                    if change_kind in ("bytes", "mode", "directory-mode"):
                        member, data = next(record for record in records[1:] if (
                            record[0].isdir() if change_kind == "directory-mode" else record[0].isfile()))
                        if change_kind == "bytes":
                            for index, record in enumerate(records):
                                if record[0] is member:
                                    records[index] = member, data + b"changed"
                        else:
                            member.mode ^= 0o100
                    elif change_kind == "duplicate":
                        records.append(records[0])
                    elif change_kind == "symlink":
                        member, _ = next(record for record in records if record[0].issym())
                        member.linkname = "../../../../../../../../escape"
                    else:
                        name = ("../escape" if change_kind == "traversal" else
                                (quality_products.PRODUCT_PATHS[0][1] / "extra").as_posix())
                        member = tarfile.TarInfo(name)
                        if change_kind == "hardlink":
                            member.type = tarfile.LNKTYPE
                            member.linkname = records[1][0].name
                            records.append((member, None))
                        else:
                            records.append((member, b"unexpected"))
                    return records
                self.rewrite_archive(archive, change)
                with self.assertRaises(quality_products.ProductError):
                    quality_products.restore_parts(work / "consumer", archive.parent, ("swift",))
                self.assertFalse((work / "escape").exists())

    def test_prepared_parts_reject_missing_parts_and_destination_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary, self.prepared_context():
            work = Path(temporary)
            self.prepared_fixture(work / "producer", ("swift",))
            archives = work / "archives"
            quality_products.pack_part(work / "producer", "swift", archives / "swift.tar.gz")
            with self.assertRaisesRegex(quality_products.ProductError, "selected part set"):
                quality_products.restore_parts(work / "consumer", archives, ("swift", "ui"))
            outside = work / "outside"
            outside.mkdir()
            link = work / "consumer/app/.build/quality-swift-tests"
            link.parent.mkdir(parents=True)
            link.symlink_to(outside)
            with self.assertRaisesRegex(quality_products.ProductError, "symlink"):
                quality_products.restore_parts(work / "consumer", archives, ("swift",))
            self.assertEqual(list(outside.iterdir()), [])

    def test_preparation_builds_only_one_graph_with_the_worker_capacity(self):
        with patch.dict(os.environ, {"DETACH_CODESIGN_IDENTITY": "private-identity",
                                    "DETACH_CONFIRM_RELEASE": "1", "DETACH_RELEASE_BUILD": "1"}), patch(
            "quality_products.os.cpu_count", return_value=3
        ), patch(
            "quality_products.subprocess.run", return_value=SimpleNamespace(returncode=0)
        ) as run:
            for part in quality_products.PART_PATHS:
                self.assertEqual(quality_products.build_part(ROOT, part), 0)
            self.assertEqual(run.call_count, 3)
            swift, ui, app = run.call_args_list
            for call in (swift, ui):
                command = call.args[0]
                self.assertEqual(command[command.index("--jobs") + 1], "3")
                self.assertIn("--enable-code-coverage", command)
            self.assertIn("--build-tests", swift.args[0])
            self.assertIn("release", ui.args[0])
            self.assertEqual(app.args[0], [str(ROOT / "app/scripts/make-app.sh")])
            self.assertEqual(app.kwargs["env"]["DETACH_SWIFT_BUILD_JOBS"], "3")
            for call in run.call_args_list:
                for key in ("DETACH_CODESIGN_IDENTITY", "DETACH_CONFIRM_RELEASE", "DETACH_RELEASE_BUILD"):
                    self.assertNotIn(key, call.kwargs["env"])

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

    def test_runtime_manifest_requires_exact_source_toolchain_and_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / quality_products.RUNTIME_PRODUCT_ROOT
            runtime.mkdir(parents=True)
            for name in quality_products.RUNTIME_PRODUCTS:
                (runtime / name).write_text(name)
                (runtime / name).chmod(0o755)
            with patch("quality_products.command_text", return_value="arm64"), patch(
                "quality_products.source_fingerprint", return_value="a" * 64
            ), patch("quality_products.toolchain_document", return_value={"compiler": "A"}):
                quality_products.publish(root, runtime_only=True)
                quality_products.verify(root, runtime_only=True)
                self.assertFalse((root / quality_products.RUNTIME_SOURCE).exists())
                with patch("quality_products.source_fingerprint", return_value="b" * 64):
                    with self.assertRaisesRegex(quality_products.ProductError, "source content"):
                        quality_products.verify(root, runtime_only=True)
                with patch("quality_products.toolchain_document", return_value={"compiler": "B"}):
                    with self.assertRaisesRegex(quality_products.ProductError, "toolchain"):
                        quality_products.verify(root, runtime_only=True)
                (runtime / "detach-state").write_text("modified")
                with self.assertRaisesRegex(quality_products.ProductError, "inventory"):
                    quality_products.verify(root, runtime_only=True)

    def test_runtime_only_manifest_cannot_authorize_the_full_products(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / quality_products.RUNTIME_PRODUCT_ROOT
            runtime.mkdir(parents=True)
            for name in quality_products.RUNTIME_PRODUCTS:
                (runtime / name).write_text(name)
                (runtime / name).chmod(0o755)
            with patch("quality_products.command_text", return_value="arm64"), patch(
                "quality_products.source_fingerprint", return_value="a" * 64
            ), patch("quality_products.toolchain_document", return_value={}):
                quality_products.publish(root, runtime_only=True)
                with self.assertRaisesRegex(quality_products.ProductError, "manifest is missing"):
                    quality_products.verify(root)
                (runtime / "tmux").unlink()
                (runtime / "tmux").symlink_to("detach-state")
                with self.assertRaisesRegex(quality_products.ProductError, "unsafe"):
                    quality_products.publish(root, runtime_only=True)

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
