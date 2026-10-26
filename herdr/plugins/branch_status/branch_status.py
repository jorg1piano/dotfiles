#!/usr/bin/env python3
"""Show each worktree space's PR and CI state next to its sidebar dot.

  branch_status.py hook      from workspace.focused / worktree.* events
  branch_status.py refresh   from the "refresh now" action, skips the throttle
  branch_status.py clear     from the "clear" action
  branch_status.py run       internal: the detached worker

Each state is its own workspace metadata token, so the sidebar row in
config.toml can give each one its own colour (a token's style is fixed in the
config, not in the value). The worker sets the one that applies and clears the
rest:

  $merged   PR merged
  $closed   PR closed without merging
  $failed   PR open, a check failed
  $running  PR open, checks still running
  $passed   PR open, all checks green
  $draft    draft PR with no failing or running checks

A branch with no PR, the repo's default branch, a repo not hosted on GitHub,
and a space that is not a git worktree get no icon.
"""

import fcntl
import json
import os
import shutil
import subprocess
import sys
import time

SOURCE_ID = "jorgen.branchstatus"
HERDR = os.environ.get("HERDR_BIN_PATH") or shutil.which("herdr") or "herdr"
STATE_DIR = os.environ.get("HERDR_PLUGIN_STATE_DIR") or os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "branchstatus"
)
LOG = os.path.join(STATE_DIR, "branchstatus.log")
STAMP = os.path.join(STATE_DIR, "last-run")
LOCK = os.path.join(STATE_DIR, "lock")

MIN_INTERVAL = 60  # seconds between passes started by focus events
POLL_EVERY = 45  # seconds between passes while some checks are still running
POLL_FOR = 45 * 60  # stop polling running checks after this long
TTL_MS = 2 * 60 * 60 * 1000  # an icon nobody refreshes expires after two hours
GH_TIMEOUT = 20

TOKENS = {
    "merged": "✔",
    "closed": "✕",
    "failed": "✗",
    "running": "⟳",
    "passed": "✓",
    "draft": "◌",
}

FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
PENDING = {"PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"}


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        if os.path.getsize(LOG) > 131072:
            with open(LOG) as f:
                tail = f.readlines()[-200:]
            with open(LOG, "w") as f:
                f.writelines(tail)
    except OSError:
        pass


def find_bin(name, *extra):
    # The server's PATH is whatever launched Herdr, so Homebrew may be missing.
    found = shutil.which(name)
    if found:
        return found
    for c in extra:
        if os.access(c, os.X_OK):
            return c
    return None


GH = find_bin("gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh")
GIT = find_bin("git", "/opt/homebrew/bin/git", "/usr/bin/git") or "git"


def herdr(*args):
    return subprocess.run([HERDR, *args], capture_output=True, text=True, timeout=10)


def workspaces():
    out = herdr("workspace", "list")
    if out.returncode != 0:
        log(f"workspace list failed: {out.stderr.strip()}")
        return []
    return json.loads(out.stdout)["result"]["workspaces"]


def report(ws_id, state):
    args = ["workspace", "report-metadata", ws_id, "--source", SOURCE_ID]
    for name in TOKENS:
        if name == state:
            args += ["--token", f"{name}={TOKENS[name]}"]
        else:
            args += ["--clear-token", name]
    args += ["--seq", str(time.time_ns() // 1_000_000)]
    if state:
        args += ["--ttl-ms", str(TTL_MS)]
    out = herdr(*args)
    if out.returncode != 0:
        log(f"{ws_id}: report failed: {out.stderr.strip()}")


def git(cwd, *args):
    out = subprocess.run([GIT, "-C", cwd, *args], capture_output=True, text=True, timeout=10)
    return out.stdout.strip() if out.returncode == 0 else ""


def default_branch(cwd):
    ref = git(cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    return ref.split("/", 1)[1] if "/" in ref else "main"


def check_state(rollup):
    """Collapse a statusCheckRollup into failed / running / passed / None."""
    if not rollup:
        return None
    failed = running = False
    for c in rollup:
        if c.get("__typename") == "StatusContext":
            s = (c.get("state") or "").upper()
            failed |= s in FAILED
            running |= s in PENDING
        else:
            if (c.get("status") or "").upper() != "COMPLETED":
                running = True
            elif (c.get("conclusion") or "").upper() in FAILED:
                failed = True
    # A failure is final even while other checks keep running.
    return "failed" if failed else "running" if running else "passed"


def branch_state(cwd):
    branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
    if not branch or branch == "HEAD" or branch == default_branch(cwd):
        return None
    if "github.com" not in git(cwd, "remote", "get-url", "origin"):
        return None  # Azure DevOps and friends: gh has nothing to say
    out = subprocess.run(
        [GH, "pr", "list", "--head", branch, "--state", "all", "--limit", "1",
         "--json", "state,isDraft,statusCheckRollup"],
        cwd=cwd, capture_output=True, text=True, timeout=GH_TIMEOUT,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"gh exited {out.returncode}")
    prs = json.loads(out.stdout or "[]")
    if not prs:
        return None
    pr = prs[0]
    if pr["state"] == "MERGED":
        return "merged"
    if pr["state"] == "CLOSED":
        return "closed"
    checks = check_state(pr.get("statusCheckRollup"))
    if pr.get("isDraft") and checks != "failed" and checks != "running":
        return "draft"
    return checks or "passed"


def one_pass():
    """Refresh every worktree space. Returns True if any checks are still running."""
    any_running = False
    for ws in workspaces():
        wt = ws.get("worktree")
        if not wt:
            continue
        cwd = wt["checkout_path"]
        try:
            state = branch_state(cwd)
        except Exception as e:  # a gh hiccup keeps the last icon rather than clearing it
            log(f"{ws['workspace_id']} {ws['label']}: {e}")
            continue
        report(ws["workspace_id"], state)
        any_running |= state == "running"
    return any_running


def run():
    os.makedirs(STATE_DIR, exist_ok=True)
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # a worker is already going and will cover this
    if not GH:
        log("gh not found; nothing to do")
        return
    started = time.time()
    while True:
        with open(STAMP, "w") as f:
            f.write(str(time.time()))
        if not one_pass() or time.time() - started > POLL_FOR:
            break
        time.sleep(POLL_EVERY)


def spawn():
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "run"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def hook():
    try:
        last = float(open(STAMP).read())
    except (OSError, ValueError):
        last = 0
    if time.time() - last >= MIN_INTERVAL:
        spawn()


def clear():
    for ws in workspaces():
        report(ws["workspace_id"], None)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "hook"
    if cmd == "hook":
        hook()
    elif cmd == "refresh":
        spawn()
    elif cmd == "run":
        run()
    elif cmd == "clear":
        clear()
    else:
        sys.exit(f"usage: {sys.argv[0]} hook|refresh|clear|run")


if __name__ == "__main__":
    main()
