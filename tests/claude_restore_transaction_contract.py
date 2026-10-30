#!/usr/bin/env python3
"""Exercise rollback error propagation in the actual Claude restore functions."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
NAMES = (
    "claude_restore_path_is_reachable", "discard_claude_restore_tmp",
    "claude_restore_txn_path", "claude_restore_sync", "claude_restore_txn_line_is_safe",
    "write_claude_restore_txn", "read_claude_restore_txn", "remove_claude_restore_txn",
    "discard_claude_restore_member_old", "rollback_claude_restore_txn_member",
    "heal_claude_restore_txn",
)


def probe(core: Path) -> None:
    source = core.read_text()
    functions = []
    for name in NAMES:
        match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)
        if not match:
            raise AssertionError(f"missing production function: {name}")
        functions.append(match[0])
    # Ownership and file-shape admission are covered by provider integration.
    # These private plain fixtures isolate the real transaction and failing mv.
    script = "\n".join(functions) + r'''
set -u
set -o pipefail
SYNC_ENABLED=0
session_dir() { printf '%s/session\n' "$PROBE_ROOT"; }
safe_owned_plain_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
session_file_is_safe_or_absent() { [ ! -e "$1" ] || safe_owned_plain_file "$1"; }
safe_claude_restore_destination() { [ -d "$1" ] && [ ! -L "$1" ]; }
mv() {
  [ "${FAIL_MOVE_PATH:-}" != "$1" ] || return 1
  /bin/mv "$@"
}
mkdir -p "$PROBE_ROOT/session" "$PROBE_ROOT/home/tasks"
transcript="$PROBE_ROOT/home/transcript.jsonl"
companion="$PROBE_ROOT/home/tasks"
printf 'old transcript\n' >"$transcript"
printf 'old companion\n' >"$companion/data"
write_claude_restore_txn session publishing session-id "$transcript" "$PROBE_ROOT/home" "$companion" || exit 10
/bin/mv "$transcript" "$transcript.detach.old"
/bin/mv "$companion" "$companion.detach.old"
printf 'new transcript\n' >"$transcript"
mkdir "$companion"
printf 'new companion\n' >"$companion/data"
FAIL_MOVE_PATH="$companion.detach.old"
if heal_claude_restore_txn session "$PROBE_ROOT/home" session-id; then
  printf 'failed rollback was accepted\n' >&2
  exit 11
fi
[ -f "$PROBE_ROOT/session/claude-restore.txn" ] || exit 12
[ "$(cat "$transcript")" = 'old transcript' ] || exit 13
[ "$(cat "$companion.detach.old/data")" = 'old companion' ] || exit 14
if heal_claude_restore_txn session "$PROBE_ROOT/home" session-id; then exit 15; fi
[ -f "$PROBE_ROOT/session/claude-restore.txn" ] || exit 16
unset FAIL_MOVE_PATH
heal_claude_restore_txn session "$PROBE_ROOT/home" session-id || exit 17
[ ! -e "$PROBE_ROOT/session/claude-restore.txn" ] || exit 18
[ "$(cat "$transcript")" = 'old transcript' ] || exit 19
[ "$(cat "$companion/data")" = 'old companion' ] || exit 20
[ "$CLAUDE_RESTORE_TXN_REPUBLISH" = 1 ] || exit 21
'''
    with tempfile.TemporaryDirectory(prefix="detach-claude-rollback-") as raw:
        import os
        result = subprocess.run(["/bin/bash", "-c", script], env={**os.environ, "PROBE_ROOT": raw},
                                capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise AssertionError(f"rollback contract failed ({result.returncode}): {result.stderr}")


if __name__ == "__main__":
    probe(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "bin/detach-core")
    print("Claude restore transaction contracts passed")
