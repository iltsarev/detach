#!/usr/bin/env python3
"""Interleave public commands around actual tmux, metadata, and kernel PIDs.

Called by run.sh with its stopped checkpoint and private runtime installation.
Barriers delay observations; they never synthesize a health result.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

cli, identity, name, metadata, state, temporary = sys.argv[1:]
name = "detach-codex-state-consistency"
metadata = str(Path(metadata).parent.parent / name / "meta.json")
root = Path(temporary) / "state-consistency"
root.mkdir()
environment = dict(os.environ, FAKE_CODEX_SLEEP="120", FAKE_CODEX_INIT_DELAY="0")


def run(arguments, *, env=None, success=True):
    result = subprocess.run(arguments, env=env or environment, capture_output=True,
                            text=True, timeout=60)
    if success:
        assert result.returncode == 0, (arguments[:4], result.stderr)
    return result


def patch(*arguments):
    run([state, "meta", "patch", metadata, *arguments])


def snapshot(*, env=None):
    result = run([cli, "codex", "list", "--json"], env=env)
    return next(row for row in map(json.loads, result.stdout.splitlines())
                if row["session_name"] == name)


def resume(*, env=None):
    return run([cli, "codex", "resume", "--name", name, "--detach", identity], env=env)


def stop():
    run([cli, "codex", "stop", name])


# A real owned process created after readiness is a reused PID. A process
# without that exclusion evidence must still block every replacement attempt.
# Use a separate managed history so these resumes cannot replace the caller's
# saved provider options or checkpoint generation.
resume()
stop()
unrelated = subprocess.Popen(["/bin/sleep", "120"])
try:
    patch("--integer", "worker_pid", str(unrelated.pid),
          "--string", "runtime_ready_at", "2000-01-01T00:00:00Z")
    assert snapshot()["effective_status"] == "stopped"
    text_row = next(line for line in run([cli, "codex", "list"]).stdout.splitlines()
                    if name in line.split())
    assert text_row.split()[3] == "stopped", text_row
    resume()
    assert unrelated.poll() is None
    stop()
    stopped = json.loads(Path(metadata).read_text())
    for readiness in [("--null", "runtime_ready_at"),
                      ("--string", "runtime_ready_at", "2099-01-01T00:00:00Z")]:
        patch("--integer", "worker_pid", str(unrelated.pid), *readiness)
        before = Path(metadata).read_bytes()
        assert snapshot()["health_reason"] == "runtime_process_without_tmux"
        refused = run([cli, "codex", "resume", "--name", name, "--detach", identity],
                      success=False)
        assert refused.returncode != 0
        assert "still alive without managed tmux" in refused.stderr
        assert unrelated.poll() is None
        assert Path(metadata).read_bytes() == before
    patch("--integer", "worker_pid", str(stopped["worker_pid"]),
          "--string", "runtime_ready_at", stopped["runtime_ready_at"])
finally:
    unrelated.terminate()
    unrelated.wait(timeout=5)

wrapper = root / "barrier"
wrapper.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
args = sys.argv[1:]
base = pathlib.Path(os.environ["STATE_TEST_BARRIER"])
mode = os.environ["STATE_TEST_MODE"]
real = os.environ["STATE_TEST_REAL"]
match = ((mode == "tmux" and "list-panes" in args)
         or (mode == "placeholder" and "new-session" in args)
         or (mode in ("process", "checkpoint") and args[:2] == ["health", "sessions"]))
if not match or base.with_suffix(".captured").exists():
    os.execv(real, [real] + args)
if mode in ("process", "checkpoint"):
    data = sys.stdin.buffer.read()
else:
    result = subprocess.run([real] + args, capture_output=True)
base.with_suffix(".captured").touch()
deadline = time.monotonic() + 45
while not base.with_suffix(".release").exists():
    if time.monotonic() > deadline:
        sys.exit(88)
    time.sleep(.02)
if mode in ("process", "checkpoint"):
    result = subprocess.run([real] + args, input=data, capture_output=True)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
''')
wrapper.chmod(0o755)


def barrier(mode, arguments):
    base = root / mode
    binary = state if mode in ("process", "checkpoint") else os.environ["DETACH_TMUX_BIN"]
    override = "DETACH_STATE_BIN" if mode in ("process", "checkpoint") else "DETACH_TMUX_BIN"
    env = dict(environment, STATE_TEST_BARRIER=str(base), STATE_TEST_MODE=mode,
               STATE_TEST_REAL=binary, **{override: str(wrapper)})
    process = subprocess.Popen(arguments, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 15
    while not base.with_suffix(".captured").exists():
        assert process.poll() is None, process.communicate()
        assert time.monotonic() < deadline, "barrier was not reached"
        time.sleep(.02)
    return base, process


def release(base, process):
    base.with_suffix(".release").touch()
    output, error = process.communicate(timeout=45)
    assert process.returncode == 0, error
    return output


# List has read genuine old tmux output. Complete Resume before allowing it to
# read metadata. The buffered mixed generation must be discarded and retried.
base, process = barrier("tmux", [cli, "codex", "list", "--json"])
try:
    resume()
finally:
    output = release(base, process)
row = next(row for row in map(json.loads, output.splitlines()) if row["session_name"] == name)
assert row["effective_status"] == "running", row
assert row["ownership_proven"] is True

# List has read running metadata. Complete Stop before kernel PID inspection.
base, process = barrier("process", [cli, "codex", "list", "--json"])
try:
    stop()
finally:
    output = release(base, process)
row = next(row for row in map(json.loads, output.splitlines()) if row["session_name"] == name)
assert row["effective_status"] == "stopped", row
assert row["health_actions"] == ["resume", "delete"]

# A checkpoint publication can change recovery eligibility without a change
# to primary metadata. Reject the observation taken before that publication.
checkpoint = Path(metadata).parent / "checkpoint"
preserved = Path(metadata).parent / "checkpoint-held-by-test"
live = Path(json.loads(Path(metadata).read_text())["transcript_path"])
assert live.is_relative_to(Path(os.environ["CODEX_HOME"]))
held_live = root / "live-rollout"
live.rename(held_live)
checkpoint.rename(preserved)
patch("--string", "status", "running")
try:
    assert snapshot()["effective_status"] == "orphaned"
    base, process = barrier("checkpoint", [cli, "codex", "list", "--json"])
    try:
        preserved.rename(checkpoint)
    finally:
        output = release(base, process)
    row = next(row for row in map(json.loads, output.splitlines()) if row["session_name"] == name)
    assert row["effective_status"] == "recoverable", row
finally:
    if preserved.exists():
        preserved.rename(checkpoint)
    held_live.rename(live)
    patch("--string", "status", "stopped")

# Pause the actual launcher with its operation lock held after placeholder
# creation, before metadata and tmux markers. This is a transaction, not a
# foreign-session fault. Releasing the lock restores normal health rules.
base, process = barrier("placeholder", [cli, "codex", "resume", "--name", name,
                                       "--detach", identity])
try:
    row = snapshot()
    assert row["effective_status"] == "starting", row
    assert row["health_reason"] == "operation_in_progress", row
    assert row["health_actions"] == [] and not row["ownership_proven"]
    assert not row["cleanup_eligible"] and row["reconcile_action"] == "none"
finally:
    release(base, process)
assert snapshot()["effective_status"] == "running"
stop()

# The same unmarked pane outside a transaction is a genuine persistent fault.
tmux = [os.environ["DETACH_TMUX_BIN"], "-S", os.environ["DETACH_TMUX_SOCKET_PATH"]]
run(tmux + ["new-session", "-d", "-s", name, "/bin/sleep", "30"])
try:
    row = snapshot()
    assert row["effective_status"] == "collision" and row["health_actions"] == [], row
finally:
    run(tmux + ["kill-session", "-t", "=" + name])
# Repeated real metadata changes exhaust the bounded retry without leaking a
# partial snapshot. Each helper invocation changes the opaque lifecycle ID.
churn = root / "churn-state"
churn.write_text('''#!/usr/bin/env python3
import os, subprocess, sys, uuid
args = sys.argv[1:]
real = os.environ["STATE_TEST_REAL"]
if args[:2] == ["health", "sessions"]:
    data = sys.stdin.buffer.read()
    subprocess.run([real, "meta", "patch", os.environ["STATE_TEST_METADATA"],
                    "--string", "lifecycle_id", str(uuid.uuid4())], check=True)
    result = subprocess.run([real] + args, input=data, capture_output=True)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
os.execv(real, [real] + args)
''')
churn.chmod(0o755)
result = run([cli, "codex", "list", "--json"], success=False,
             env=dict(environment, DETACH_STATE_BIN=str(churn),
                      STATE_TEST_REAL=state, STATE_TEST_METADATA=metadata))
assert result.returncode != 0 and result.stdout == "", result
assert "all three list attempts" in result.stderr, result.stderr
assert snapshot()["effective_status"] == "stopped"
run([cli, "codex", "delete", "--force", name])

print("runtime state consistency: actual PID reuse, tmux/metadata interleavings, and operation locks PASS")
