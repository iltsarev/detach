#!/usr/bin/env python3
"""Publish and verify the minimal exact executable quality products."""

from __future__ import annotations

from contextlib import redirect_stdout
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import NoReturn

from quality_cache_warm import module_environment, product_fingerprint, product_inputs


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_RELATIVE = Path("app/.build/quality-products-v1.json")
RUNTIME_MANIFEST_RELATIVE = Path("app/.build/quality-runtime-v1.json")
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
PART_PATHS = {
    "swift": PRODUCT_PATHS[:2],
    "ui": PRODUCT_PATHS[2:4],
    "app": (
        ("app-bundle", Path("app/build/Detach.app")),
        ("tmux-cache", Path("app/.build/tmux-runtime/arm64/product")),
    ),
}
PART_EXECUTABLES = {
    "swift": EXECUTABLE_PATHS[:1],
    "ui": EXECUTABLE_PATHS[1:2],
    "app": (
        Path("app/build/Detach.app/Contents/MacOS/Detach"),
        Path("app/.build/tmux-runtime/arm64/product/tmux"),
    ),
}


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


def product_document(root: Path, runtime_only: bool = False) -> dict[str, list[dict[str, object]]]:
    return {
        identifier: inventory(root, relative)
        for identifier, relative in (
            (("runtime-tmux", RUNTIME_PRODUCT_ROOT / "tmux"),
             ("runtime-state", RUNTIME_PRODUCT_ROOT / "detach-state"))
            if runtime_only else PRODUCT_PATHS
        )
    }


def validate_executables(root: Path, runtime_only: bool = False) -> None:
    paths = tuple(RUNTIME_PRODUCT_ROOT / name for name in RUNTIME_PRODUCTS) if runtime_only else EXECUTABLE_PATHS
    validate_executable_paths(root, paths)


def validate_executable_paths(root: Path, paths: tuple[Path, ...]) -> None:
    for relative in paths:
        binary = root / relative
        if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
            raise ProductError(f"missing or unsafe executable product: {relative.as_posix()}")
        if command_text(["lipo", "-archs", str(binary)]) != "arm64":
            raise ProductError(f"executable product is not arm64-only: {relative.as_posix()}")


def part_manifest(part: str) -> Path:
    if part not in PART_PATHS:
        raise ProductError("unknown prepared product part")
    return Path("app/.build/quality-prepared-parts") / f"{part}.json"


def source_commit(root: Path) -> str:
    commit = command_text(["git", "-C", str(root), "rev-parse", "HEAD"])
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ProductError("prepared product source commit is invalid")
    if command_text(["git", "-C", str(root), "diff", "--name-only", "HEAD"]):
        raise ProductError("prepared product source checkout has tracked changes")
    return commit


def part_identity(root: Path, part: str) -> dict[str, object]:
    part_manifest(part)
    return {
        "schema": 1, "part": part, "source_commit": source_commit(root),
        "source_fingerprint": source_fingerprint(root),
        "toolchain": toolchain_document(),
    }


def preparation_environment(root: Path, name: str) -> dict[str, str]:
    environment = module_environment(root, name)
    for key in (
        "DETACH_CONFIRM_RELEASE", "DETACH_VERSION", "DETACH_BUILD_VERSION",
        "DETACH_BUILD_ARCHS", "DETACH_CODESIGN_IDENTITY", "DETACH_RELEASE_BUILD",
        "DETACH_APP_BUILD_MARKER_FILE", "DETACH_SPARKLE_VERSION",
        "DETACH_SPARKLE_FEED_URL", "DETACH_SPARKLE_PUBLIC_ED_KEY", "DETACH_DOWNLOAD_URL",
    ):
        environment.pop(key, None)
    return environment


def part_inventory(root: Path, part: str) -> dict[str, list[dict[str, object]]]:
    result = {}
    for name, relative in PART_PATHS[part]:
        records = inventory(root, relative)
        product = root / relative
        if product.is_dir():
            directories = [product, *(path for path in product.rglob("*")
                                      if path.is_dir() and not path.is_symlink())]
            records.extend({"path": path.relative_to(root).as_posix(), "type": "directory",
                            "mode": stat.S_IMODE(path.lstat().st_mode)} for path in directories)
        result[name] = sorted(records, key=lambda record: record["path"])
    return result


def verify_part(root: Path, part: str) -> dict[str, object]:
    path = root / part_manifest(part)
    if not path.is_file() or path.is_symlink():
        raise ProductError("prepared product manifest is missing or unsafe")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise ProductError("prepared product manifest is invalid") from error
    identity = part_identity(root, part)
    if (not isinstance(document, dict) or set(document) != {*identity, "products"}
            or any(document.get(key) != value for key, value in identity.items())):
        raise ProductError("prepared product identity does not match this checkout")
    if document["products"] != part_inventory(root, part):
        raise ProductError("prepared product inventory does not match its manifest")
    validate_executable_paths(root, PART_EXECUTABLES[part])
    return document


def safe_destination(root: Path, relative: Path) -> Path:
    current = root.resolve()
    for component in relative.parts:
        if component in ("", ".", "..") or Path(component).is_absolute():
            raise ProductError("prepared product destination is invalid")
        current = current / component
        if current.is_symlink():
            raise ProductError("prepared product destination contains a symlink")
    return current


def pack_part(root: Path, part: str, output: Path) -> int:
    root = root.resolve()
    identity = part_identity(root, part)
    validate_executable_paths(root, PART_EXECUTABLES[part])
    document = {**identity, "products": part_inventory(root, part)}
    manifest = safe_destination(root, part_manifest(part))
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(document, sort_keys=True) + "\n", encoding="utf-8")
    manifest.chmod(0o600)
    if output.is_symlink():
        raise ProductError("prepared product archive is a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}")
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            metadata = archive.gettarinfo(manifest, arcname=part_manifest(part).as_posix())
            metadata.uid = metadata.gid = 0
            metadata.uname = metadata.gname = ""
            with manifest.open("rb") as stream:
                archive.addfile(metadata, stream)
            for records in document["products"].values():
                for record in records:
                    source = root / record["path"]
                    member = archive.gettarinfo(source, arcname=record["path"])
                    member.uid = member.gid = 0
                    member.uname = member.gname = ""
                    if record["type"] == "file":
                        # Store each file's bytes even when the build tree uses
                        # hard links. Incoming archives never need hard links.
                        member.type = tarfile.REGTYPE
                        member.linkname = ""
                        member.size = record["size"]
                        with source.open("rb") as stream:
                            archive.addfile(member, stream)
                    else:
                        archive.addfile(member)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"quality-products: prepared {part} archive published")
    return 0


def unpack_part(root: Path, staging: Path, path: Path, part: str) -> None:
    manifest_name = part_manifest(part).as_posix()
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or manifest_name not in names:
            raise ProductError("prepared product archive has duplicate or missing members")
        if len(members) > 10000 or sum(member.size for member in members) > 512 * 1024 * 1024:
            raise ProductError("prepared product archive exceeds its size limit")
        metadata = archive.getmember(manifest_name)
        if not metadata.isfile() or metadata.size > 2 * 1024 * 1024:
            raise ProductError("prepared product manifest is not a bounded regular file")
        try:
            stream = archive.extractfile(metadata)
            assert stream is not None
            document = json.loads(stream.read())
        except (ValueError, UnicodeError) as error:
            raise ProductError("prepared product manifest is invalid") from error
        identity = part_identity(root, part)
        if (not isinstance(document, dict) or set(document) != {*identity, "products"}
                or any(document.get(key) != value for key, value in identity.items())):
            raise ProductError("prepared product identity does not match this checkout")
        products = document["products"]
        if (not isinstance(products, dict) or set(products) != {name for name, _ in PART_PATHS[part]}
                or any(not isinstance(records, list) for records in products.values())):
            raise ProductError("prepared product inventory is invalid")
        records = [record for values in products.values() for record in values]
        if any(not isinstance(record, dict) or not isinstance(record.get("path"), str) for record in records):
            raise ProductError("prepared product inventory entry is invalid")
        by_name = {record["path"]: record for record in records}
        if len(by_name) != len(records) or set(names) != {*by_name, manifest_name}:
            raise ProductError("prepared product archive does not match its inventory")
        roots = [relative.as_posix() for _, relative in PART_PATHS[part]]
        for member in members:
            name = Path(member.name)
            if (name.is_absolute() or ".." in name.parts
                    or member.name != name.as_posix()
                    or not (member.name == manifest_name or any(
                        member.name == prefix or member.name.startswith(prefix + "/") for prefix in roots))
                    or not (member.isfile() or member.issym() or member.isdir())
                    or (member.issym() and member.name in roots)
                    or member.mode & ~0o777):
                raise ProductError("prepared product archive has an unsafe member")
            if member.name != manifest_name and member.mode != by_name[member.name].get("mode"):
                raise ProductError("prepared product member mode does not match its inventory")
        # The data filter constrains links and strips ownership. Apply only
        # the already-matched permission bits afterward; macOS symlink modes
        # otherwise inherit the consumer's umask.
        modes = {member.name: member.mode for member in members}
        try:
            archive.extractall(staging, filter="data")
        except (tarfile.TarError, OSError) as error:
            raise ProductError("prepared product archive cannot be safely extracted") from error
        for member in sorted(members, key=lambda item: len(Path(item.name).parts), reverse=True):
            if member.issym():
                parent = safe_destination(staging, Path(member.name).parent)
                destination = parent / Path(member.name).name
                prefix = next(prefix for prefix in roots if member.name.startswith(prefix + "/"))
                contained_symlink(destination, staging / prefix)
                if hasattr(os, "lchmod"):
                    os.lchmod(destination, modes[member.name])
                elif stat.S_IMODE(destination.lstat().st_mode) != modes[member.name]:
                    raise ProductError("prepared product symlink mode cannot be restored")
            else:
                safe_destination(staging, Path(member.name)).chmod(modes[member.name])
    if products != part_inventory(staging, part):
        raise ProductError("prepared product inventory does not match its manifest")
    validate_executable_paths(staging, PART_EXECUTABLES[part])


def restore_parts(root: Path, directory: Path, parts: tuple[str, ...]) -> dict[str, str]:
    root = root.resolve()
    if not parts or len(set(parts)) != len(parts) or not set(parts) <= PART_PATHS.keys():
        raise ProductError("prepared product part set is invalid")
    if directory.is_symlink() or not directory.is_dir():
        raise ProductError("prepared product archive directory is unsafe")
    archives = list(directory.rglob("*.tar.gz"))
    if (len(archives) != len(parts)
            or {path.name for path in archives} != {f"{part}.tar.gz" for part in parts}):
        raise ProductError("prepared product archives do not match the selected part set")
    for path in archives:
        if not path.is_file() or path.is_symlink():
            raise ProductError("prepared product archive is missing or unsafe")
        try:
            path.resolve().relative_to(directory.resolve())
        except ValueError as error:
            raise ProductError("prepared product archive escapes its directory") from error
    scratch = safe_destination(root, Path("app/.build"))
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="prepared-products-", dir=scratch) as raw:
        staging = Path(raw)
        for path in archives:
            part = path.name.removesuffix(".tar.gz")
            unpack_part(root, staging, path, part)
        for part in parts:
            for _, relative in PART_PATHS[part]:
                destination = safe_destination(root, relative)
                if destination.exists():
                    raise ProductError("prepared product destination already exists")
            safe_destination(root, part_manifest(part))
        for part in parts:
            for _, relative in PART_PATHS[part]:
                destination = safe_destination(root, relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                os.replace(staging / relative, destination)
            manifest = safe_destination(root, part_manifest(part))
            manifest.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staging / part_manifest(part), manifest)
            verify_part(root, part)
    bindings = {}
    if "app" in parts:
        status = subprocess.run(
            [str(root / "app/scripts/verify-app.sh")], cwd=root, stdout=sys.stderr,
            env=preparation_environment(root, "app"), check=False
        ).returncode
        if status:
            raise ProductError("prepared app verification failed")
        stage_runtime_products(root)
        publish(root, runtime_only=True)
        bindings.update(DETACH_QUALITY_EXACT_APP="1", DETACH_QUALITY_EXACT_RUNTIME="1")
    if "swift" in parts:
        bindings["DETACH_QUALITY_EXACT_SWIFT"] = "1"
    if set(parts) == set(PART_PATHS):
        publish(root)
        bindings["DETACH_QUALITY_EXACT_PRODUCTS"] = "1"
    return bindings


def build_part(root: Path, part: str) -> int:
    part_manifest(part)
    jobs = str(max(1, os.cpu_count() or 1))
    environment = preparation_environment(root, "app" if part == "app" else part)
    if part == "app":
        environment.update(DETACH_SWIFT_BUILD_JOBS=jobs, DETACH_QUALITY_APP_SCRATCH="1")
        command = [str(root / "app/scripts/make-app.sh")]
    else:
        scratch = "quality-swift-tests" if part == "swift" else "quality-ui-release"
        command = [
            "swift", "build", "--package-path", str(root / "app"),
            "--disable-sandbox", "--disable-automatic-resolution",
            "--cache-path", str(root / "app/.build"),
            "--scratch-path", str(root / "app/.build" / scratch),
            "--enable-code-coverage", "--jobs", jobs,
        ]
        if part == "swift":
            command.append("--build-tests")
        else:
            command.extend(("-c", "release", "--triple", "arm64-apple-macosx26.0", "--product", "DetachApp"))
    return subprocess.run(command, cwd=root, env=environment, check=False).returncode


def manifest_path(root: Path, runtime_only: bool = False) -> Path:
    return root / (RUNTIME_MANIFEST_RELATIVE if runtime_only else MANIFEST_RELATIVE)


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


def publish(root: Path, runtime_only: bool = False) -> int:
    root = root.resolve()
    if not runtime_only:
        stage_runtime_products(root)
    validate_executables(root, runtime_only)
    document = {
        "schema": 1,
        "source_fingerprint": source_fingerprint(root),
        "toolchain": toolchain_document(),
        "products": product_document(root, runtime_only),
    }
    manifest = manifest_path(root, runtime_only)
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


def verify(root: Path, runtime_only: bool = False) -> int:
    root = root.resolve()
    manifest = manifest_path(root, runtime_only)
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
    if document["products"] != product_document(root, runtime_only):
        raise ProductError("executable product inventory does not match its manifest")
    validate_executables(root, runtime_only)
    print("quality-products: exact executable products verified")
    return 0


def build_runtime(root: Path) -> int:
    """Build only the two exact executables used by provider integrations."""
    root = root.resolve()
    destination = root / RUNTIME_PRODUCT_ROOT
    if destination.is_symlink():
        raise ProductError("runtime product root is a symlink")
    try:
        destination.resolve().relative_to(root)
    except ValueError as error:
        raise ProductError("runtime product root escapes repository") from error
    destination.mkdir(parents=True, exist_ok=True)
    build = [
        "swift", "build", "--package-path", str(root / "app"),
        "--scratch-path", str(root / "app/.build/quality-runtime-build"),
        "--cache-path", str(root / "app/.build"), "--disable-sandbox",
        "--disable-automatic-resolution", "-c", "release",
        "--triple", "arm64-apple-macosx26.0", "--jobs", "3",
        "--product", "detach-state",
    ]
    environment = module_environment(root, "runtime")
    result = subprocess.run(build, cwd=root, env=environment, check=False)
    if result.returncode:
        raise ProductError("state runtime build failed")
    binaries = Path(command_text([*build, "--show-bin-path"]))
    try:
        binaries.resolve().relative_to(root)
    except ValueError as error:
        raise ProductError("state runtime build escaped repository") from error
    with tempfile.TemporaryDirectory(prefix="detach-quality-runtime.", dir="/private/tmp") as raw:
        tmux = Path(raw) / "tmux"
        command_text([str(root / "scripts/build-tmux.sh"), "build", "--arch", "arm64", "--output", str(tmux)])
        for name, source in (("tmux", tmux), ("detach-state", binaries / "detach-state")):
            target = destination / name
            if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK) or target.is_symlink():
                raise ProductError(f"runtime product is missing or unsafe: {name}")
            temporary = destination / f".{name}.{os.getpid()}"
            temporary.write_bytes(source.read_bytes())
            temporary.chmod(0o755)
            os.replace(temporary, target)
    return publish(root, runtime_only=True)


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "build-part":
        return build_part(ROOT, arguments[1])
    if len(arguments) == 3 and arguments[0] == "pack-part":
        return pack_part(ROOT, arguments[1], Path(arguments[2]))
    if len(arguments) == 3 and arguments[0] == "restore-parts":
        with redirect_stdout(sys.stderr):
            bindings = restore_parts(ROOT, Path(arguments[1]), tuple(arguments[2].split(",")))
        for key, value in bindings.items():
            print(f"{key}={value}")
        return 0
    if arguments == ["publish"]:
        return publish(ROOT)
    if arguments == ["verify"]:
        return verify(ROOT)
    if arguments == ["build-runtime"]:
        return build_runtime(ROOT)
    if arguments == ["verify-runtime"]:
        return verify(ROOT, runtime_only=True)
    raise ProductError("usage: quality_products.py publish|verify|build-runtime|verify-runtime|build-part PART|pack-part PART ARCHIVE|restore-parts DIRECTORY PARTS")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ProductError as error:
        fail(str(error))
