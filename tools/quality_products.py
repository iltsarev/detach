#!/usr/bin/env python3
"""Publish and verify the minimal exact executable quality products."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from typing import NoReturn

from quality_cache_warm import product_fingerprint, product_inputs


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_RELATIVE = Path("app/.build/quality-products-v1.json")
# The provider integrations need only the bundled tmux and detach-state. A
# green main publishes both as exact runtime products so a pull request that
# changes only the shell CLI does not rebuild the whole app in every shard.
RUNTIME_PRODUCT_ROOT = Path("app/.build/quality-runtime")
RUNTIME_SOURCE = Path("app/build/Detach.app/Contents/Resources/DetachCLI")
RUNTIME_PRODUCTS = ("tmux", "detach-state")
PRODUCT_PATHS = (
    (
        "swift-tests",
        Path(
            "app/.build/quality-swift-tests/arm64-apple-macosx/debug/"
            "DetachAppPackageTests.xctest"
        ),
    ),
    (
        "swift-sparkle",
        Path(
            "app/.build/quality-swift-tests/arm64-apple-macosx/debug/"
            "Sparkle.framework"
        ),
    ),
    (
        "ui-app",
        Path(
            "app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp"
        ),
    ),
    (
        "ui-sparkle",
        Path(
            "app/.build/quality-ui-release/arm64-apple-macosx/release/"
            "Sparkle.framework"
        ),
    ),
    ("runtime-tmux", RUNTIME_PRODUCT_ROOT / "tmux"),
    ("runtime-state", RUNTIME_PRODUCT_ROOT / "detach-state"),
)
EXECUTABLE_PATHS = (
    Path(
        "app/.build/quality-swift-tests/arm64-apple-macosx/debug/"
        "DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests"
    ),
    Path("app/.build/quality-ui-release/arm64-apple-macosx/release/DetachApp"),
    RUNTIME_PRODUCT_ROOT / "tmux",
    RUNTIME_PRODUCT_ROOT / "detach-state",
)


class ProductError(Exception):
    """Exact executable products are missing, stale, or unsafe."""


def fail(message: str) -> NoReturn:
    print(f"quality-products: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_text(arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            arguments,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError as error:
        raise ProductError(f"cannot start {arguments[0]}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ProductError(f"command failed ({arguments[0]}): {detail}")
    return result.stdout.strip()


def toolchain_document() -> dict[str, str]:
    return {
        "architecture": command_text(["uname", "-m"]),
        "swift": command_text(["swift", "--version"]).splitlines()[0],
        "xcode": " ".join(command_text(["xcodebuild", "-version"]).splitlines()),
    }


def source_fingerprint(root: Path) -> str:
    return product_fingerprint(product_inputs(root))


def contained_symlink(path: Path, product_root: Path) -> str:
    target = os.readlink(path)
    if os.path.isabs(target):
        raise ProductError(f"product has an absolute symlink: {path}")
    try:
        path.resolve(strict=True).relative_to(product_root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise ProductError(f"product symlink escapes its root: {path}") from error
    return target


def inventory(root: Path, relative: Path) -> list[dict[str, object]]:
    root = root.resolve()
    product = root / relative
    if product.is_symlink() or not product.exists():
        raise ProductError(f"missing or unsafe product: {relative.as_posix()}")
    try:
        product.resolve(strict=True).relative_to(root)
    except (OSError, ValueError) as error:
        raise ProductError(f"product escapes repository: {relative.as_posix()}") from error
    candidates = [product]
    if product.is_dir():
        candidates.extend(sorted(product.rglob("*"), key=lambda path: path.as_posix()))
    records: list[dict[str, object]] = []
    for path in candidates:
        details = path.lstat()
        path_relative = path.relative_to(root).as_posix()
        mode = stat.S_IMODE(details.st_mode)
        if stat.S_ISLNK(details.st_mode):
            records.append(
                {
                    "path": path_relative,
                    "type": "symlink",
                    "mode": mode,
                    "target": contained_symlink(path, product),
                }
            )
        elif stat.S_ISREG(details.st_mode):
            records.append(
                {
                    "path": path_relative,
                    "type": "file",
                    "mode": mode,
                    "sha256": sha256_file(path),
                    "size": details.st_size,
                }
            )
        elif not stat.S_ISDIR(details.st_mode):
            raise ProductError(f"product has an unsupported entry: {path_relative}")
    if not records:
        raise ProductError(f"product has no files: {relative.as_posix()}")
    return records


def product_document(root: Path) -> dict[str, list[dict[str, object]]]:
    return {
        identifier: inventory(root, relative)
        for identifier, relative in PRODUCT_PATHS
    }


def validate_executables(root: Path) -> None:
    for relative in EXECUTABLE_PATHS:
        binary = root / relative
        if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
            raise ProductError(f"missing or unsafe executable product: {relative.as_posix()}")
        if command_text(["lipo", "-archs", str(binary)]) != "arm64":
            raise ProductError(f"executable product is not arm64-only: {relative.as_posix()}")


def manifest_path(root: Path) -> Path:
    return root / MANIFEST_RELATIVE


def stage_runtime_products(root: Path) -> None:
    """Copy the verified bundle's tmux and detach-state into the product root."""
    source_root = root / RUNTIME_SOURCE
    destination_root = root / RUNTIME_PRODUCT_ROOT
    if destination_root.is_symlink():
        raise ProductError("runtime product root is a symlink")
    destination_root.mkdir(parents=True, exist_ok=True)
    for name in RUNTIME_PRODUCTS:
        source = source_root / name
        if not source.is_file() or source.is_symlink() or not os.access(source, os.X_OK):
            raise ProductError(f"bundled runtime product is missing or unsafe: {name}")
        destination = destination_root / name
        if destination.is_symlink():
            raise ProductError(f"runtime product is a symlink: {name}")
        temporary = destination_root / f".{name}.{os.getpid()}"
        temporary.write_bytes(source.read_bytes())
        temporary.chmod(0o755)
        os.replace(temporary, destination)


def publish(root: Path) -> int:
    root = root.resolve()
    stage_runtime_products(root)
    validate_executables(root)
    document = {
        "schema": 1,
        "source_fingerprint": source_fingerprint(root),
        "toolchain": toolchain_document(),
        "products": product_document(root),
    }
    manifest = manifest_path(root)
    if manifest.is_symlink():
        raise ProductError("product manifest is a symlink")
    manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary = manifest.with_name(f".{manifest.name}.{os.getpid()}")
    temporary.write_text(
        json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    os.replace(temporary, manifest)
    print("quality-products: exact executable products published")
    return 0


def verify(root: Path) -> int:
    root = root.resolve()
    manifest = manifest_path(root)
    if not manifest.is_file() or manifest.is_symlink():
        raise ProductError("product manifest is missing or unsafe")
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProductError("product manifest is invalid") from error
    if not isinstance(document, dict) or set(document) != {
        "schema",
        "source_fingerprint",
        "toolchain",
        "products",
    }:
        raise ProductError("product manifest has unknown or missing fields")
    if document["schema"] != 1:
        raise ProductError("product manifest schema is unsupported")
    if document["source_fingerprint"] != source_fingerprint(root):
        raise ProductError("product manifest does not match source content")
    if document["toolchain"] != toolchain_document():
        raise ProductError("product manifest does not match the toolchain")
    if document["products"] != product_document(root):
        raise ProductError("executable product inventory does not match its manifest")
    validate_executables(root)
    print("quality-products: exact executable products verified")
    return 0


def main(arguments: list[str]) -> int:
    if arguments == ["publish"]:
        return publish(ROOT)
    if arguments == ["verify"]:
        return verify(ROOT)
    raise ProductError("usage: quality_products.py publish|verify")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ProductError as error:
        fail(str(error))
