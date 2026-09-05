#!/usr/bin/env python3
"""Show j1pstack proof status for a Herdr pane.

Two surfaces:
- `$proof` pane metadata for the agents sidebar.
- an overlay plugin pane with OSC-8 clickable card rows. Clicking a card emits a
  `nudge-proof://...` URL, which the link handler routes back here to `open(1)`
  or `xdg-open` the proof file/folder.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, unquote, urlparse

SOURCE_ID = "jorgen.proofcontext"
PLUGIN_ID = "jorgen.proofcontext"
TOKEN = "proof"
TTL_MS = int(os.environ.get("PROOFCONTEXT_TTL_MS", "3600000"))
HERDR = os.environ.get("HERDR_BIN_PATH", "herdr")
REFRESH_SECONDS = int(os.environ.get("PROOFCONTEXT_REFRESH_SECONDS", "3"))

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[38;5;114m"
YELLOW = "\033[38;5;221m"
RED = "\033[38;5;203m"
BLUE = "\033[38;5;110m"
BG = "\033[48;5;236m"


def log(message: str) -> None:
    state = Path(os.environ.get("HERDR_PLUGIN_STATE_DIR", os.environ.get("TMPDIR", "/tmp")))
    try:
        state.mkdir(parents=True, exist_ok=True)
        with (state / "proofcontext.log").open("a", encoding="utf-8") as f:
            print(f"{time.strftime('%H:%M:%S')} {message}", file=f)
    except OSError:
        pass


def load_env_json(name: str) -> dict[str, Any]:
    raw = os.environ.get(name, "")
    if not raw:
        return {}
    try:
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else {}
    except json.JSONDecodeError:
        return {}


def herdr_json(*args: str) -> dict[str, Any]:
    p = subprocess.run([HERDR, *args], text=True, capture_output=True, timeout=5)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "herdr failed").strip())
    return json.loads(p.stdout)


def pane_id_for(mode: str) -> str:
    if mode == "hook":
        ev = load_env_json("HERDR_PLUGIN_EVENT_JSON")
        return ev.get("pane_id") or os.environ.get("HERDR_PANE_ID", "")
    ctx = load_env_json("HERDR_PLUGIN_CONTEXT_JSON")
    return os.environ.get("HERDR_PANE_ID") or ctx.get("focused_pane_id", "")


def cwd_for_current_context() -> str:
    ctx = load_env_json("HERDR_PLUGIN_CONTEXT_JSON")
    return ctx.get("focused_pane_cwd") or ctx.get("workspace_cwd") or os.getcwd()


def pane_info(pane_id: str) -> dict[str, Any]:
    data = herdr_json("pane", "list")
    for pane in data.get("result", {}).get("panes", []):
        if pane.get("pane_id") == pane_id:
            return pane
    return {}


def find_root(cwd: str) -> Path | None:
    if not cwd:
        return None
    p = Path(cwd).resolve()
    for cur in [p, *p.parents]:
        if (cur / ".nudge" / "contract.jsonl").exists():
            return cur
        if (cur / ".git").exists() and (cur / ".nudge").exists():
            return cur
    return None


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as f:
            for line in f:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    rows.append(obj)
    except FileNotFoundError:
        pass
    return rows


def tag_string(tag: dict[str, Any]) -> str:
    area = tag.get("area") or ""
    ns = tag.get("namespace") or ""
    val = tag.get("value") or ""
    return f"{area + ':' if area else ''}{ns}:{val}"


def short_tag(tag: str) -> str:
    parts = tag.split(":")
    if len(parts) >= 3 and parts[-2] == "proof":
        return f"{parts[0]}:{parts[-1]}"
    if len(parts) >= 2 and parts[-2] == "proof":
        return parts[-1]
    return tag


def latest_contract(root: Path) -> dict[str, Any] | None:
    rows = read_jsonl(root / ".nudge" / "contract.jsonl")
    return rows[-1] if rows else None


def latest_records(root: Path, session: str, turn: int) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    for row in read_jsonl(root / ".nudge" / "proofs.jsonl"):
        if row.get("session") == session and row.get("turn") == turn and row.get("tag"):
            records[str(row["tag"])] = row
    return records


def current(root: Path) -> tuple[dict[str, Any] | None, list[str], dict[str, dict[str, Any]]]:
    contract = latest_contract(root)
    if not contract:
        return None, [], {}
    proof_tags = [tag_string(t) for t in contract.get("tags", []) if t.get("namespace") == "proof"]
    try:
        turn = int(contract.get("turn") or 0)
    except (TypeError, ValueError):
        turn = 0
    return contract, proof_tags, latest_records(root, str(contract.get("session") or ""), turn)


def record_for(records: dict[str, dict[str, Any]], tag: str) -> dict[str, Any]:
    if tag in records:
        return records[tag]
    # Prompts often carry bare proof:screenshot, while the gate records the
    # resolved definition as repo:proof:screenshot / mobile:proof:screenshot.
    if tag.startswith("proof:"):
        suffix = ":" + tag
        matches = [r for t, r in records.items() if t.endswith(suffix)]
        if matches:
            return matches[-1]
    return {}


def render_metadata(root: Path) -> str:
    _, proof_tags, records = current(root)
    if not proof_tags:
        return ""
    bits: list[str] = []
    for tag in proof_tags:
        record = record_for(records, tag)
        status = record.get("status")
        if status == "present":
            bits.append(short_tag(tag) + " ✓")
        elif status:
            bits.append(short_tag(tag) + " " + str(status))
        else:
            bits.append(short_tag(tag) + " …")
    return "proof " + ", ".join(bits)


def report(pane: str, text: str) -> None:
    args = ["pane", "report-metadata", pane, "--source", SOURCE_ID]
    if text:
        args += ["--token", f"{TOKEN}={text}", "--seq", str(int(time.time())), "--ttl-ms", str(TTL_MS)]
    else:
        args += ["--clear-token", TOKEN]
    subprocess.run([HERDR, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def proof_target(root: Path, tag: str, record: dict[str, Any]) -> Path:
    path = record.get("path")
    if path:
        p = Path(str(path))
        if p.is_absolute():
            return p
        candidate = root / p
        if candidate.exists():
            return candidate
        # Agents sometimes record paths from a subdirectory (`../.nudge/...`).
        # If the artifact basename exists in the repo's canonical .nudge tree,
        # prefer that real file/folder over a non-existent parent-relative path.
        parts = p.parts
        if ".nudge" in parts:
            i = parts.index(".nudge")
            canonical = root.joinpath(*parts[i:])
            if canonical.exists():
                return canonical
        if "screenshots" in parts:
            canonical = root / ".nudge" / "artifacts" / "screenshots" / p.name
            if canonical.exists():
                return canonical
        return candidate
    kind = tag.split(":")[-1]
    if kind == "screenshot":
        return root / ".nudge" / "artifacts" / "screenshots"
    if kind in {"video", "videos"}:
        return root / ".nudge" / "artifacts" / "videos"
    return root / ".nudge"


def link_for(path: Path, label: str) -> str:
    return f"nudge-proof://open?path={quote(str(path))}&label={quote(label)}"


def osc8(url: str, text: str) -> str:
    return f"\033]8;;{url}\033\\{text}\033]8;;\033\\"


def right(text: str, width: int) -> str:
    # Good enough for these ASCII cards; ANSI length is ignored intentionally so
    # the visible text stays near the right even with colour/link escapes.
    plain = text
    for code in [RESET, DIM, BOLD, GREEN, YELLOW, RED, BLUE, BG]:
        plain = plain.replace(code, "")
    return " " * max(0, width - len(plain) - 2) + text


def card_items(root: Path) -> list[tuple[Path, str]]:
    contract, proof_tags, records = current(root)
    if not contract or not proof_tags:
        return []
    items: list[tuple[Path, str]] = []
    for tag in proof_tags:
        record = record_for(records, tag)
        status = str(record.get("status") or "missing")
        colour = GREEN if status == "present" else RED if status in {"missing", "failed", "stale"} else YELLOW
        mark = "✓" if status == "present" else "!" if status in {"failed", "stale"} else "…"
        target = proof_target(root, tag, record)
        label = f"{BG}{colour} {mark} {short_tag(tag)} {RESET} {DIM}{target.name or target}{RESET}"
        items.append((target, label))

    shots = root / ".nudge" / "artifacts" / "screenshots"
    if shots.exists():
        items.append((shots, f"{BG}{BLUE} screenshots folder {RESET}"))
    return items


def cards(root: Path) -> list[str]:
    contract, _, _ = current(root)
    rows = [f"{BOLD}proof cards{RESET}" + (f" {DIM}turn {contract.get('turn', '?')}{RESET}" if contract else "")]
    rows.extend(label for _, label in card_items(root))
    return rows


def run_cards() -> int:
    root = find_root(cwd_for_current_context())
    if not root:
        print("\033[2J\033[H(no .nudge contract)", flush=True)
        time.sleep(2)
        return 0

    items = card_items(root)
    if not items:
        print("\033[2J\033[H(no active proof tags)", flush=True)
        time.sleep(2)
        return 0

    fzf = shutil.which("fzf", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", ""))
    if fzf:
        data = "".join(f"{path}\t{label}\n" for path, label in items)
        proc = subprocess.run(
            [
                fzf,
                "--ansi",
                "--no-sort",
                "--delimiter=\t",
                "--with-nth=2..",
                "--prompt=proof > ",
                "--header=enter/click opens the selected proof artifact",
                "--bind=left-click:accept,double-click:accept",
            ],
            input=data,
            text=True,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return open_path(Path(proc.stdout.split("\t", 1)[0]))
        return 0

    # Fallback for a machine without fzf: show OSC-8 links. Depending on Herdr
    # mouse capture and the host terminal, these may require Cmd-click.
    try:
        cols = shutil.get_terminal_size((80, 10)).columns
        print("\033[2J\033[H", end="")
        linked = [f"{BOLD}proof cards{RESET}"]
        for path, label in items:
            linked.append(osc8(link_for(path, path.name), label))
        print("\n".join(right(row, cols) for row in linked), flush=True)
        time.sleep(30)
    except KeyboardInterrupt:
        pass
    return 0


def open_cards() -> int:
    ctx = load_env_json("HERDR_PLUGIN_CONTEXT_JSON")
    cwd = ctx.get("focused_pane_cwd") or ctx.get("workspace_cwd") or os.getcwd()
    args = [HERDR, "plugin", "pane", "open", "--plugin", os.environ.get("HERDR_PLUGIN_ID", PLUGIN_ID), "--entrypoint", "cards", "--placement", "overlay", "--cwd", cwd, "--focus"]
    p = subprocess.run(args, text=True, capture_output=True)
    if p.returncode != 0 and "already" not in (p.stderr + p.stdout).lower():
        sys.stderr.write(p.stderr or p.stdout)
        return p.returncode
    return 0


def open_path(path: Path) -> int:
    if platform.system() == "Darwin":
        cmd = ["open", str(path)] if path.is_dir() else ["open", "-R", str(path)]
    else:
        cmd = ["xdg-open", str(path if path.is_dir() else path.parent)]
    return subprocess.run(cmd).returncode


def open_link() -> int:
    ctx = load_env_json("HERDR_PLUGIN_CONTEXT_JSON")
    url = ctx.get("clicked_url") or ""
    if not url:
        return 0
    parsed = urlparse(url)
    if parsed.scheme != "nudge-proof":
        return 0
    path = parse_qs(parsed.query).get("path", [""])[0]
    if not path:
        return 0
    return open_path(Path(unquote(path)))


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "hook"
    if mode == "cards":
        return run_cards()
    if mode == "open-cards":
        return open_cards()
    if mode == "open-link":
        return open_link()

    if mode == "hook":
        ev = load_env_json("HERDR_PLUGIN_EVENT_JSON")
        if os.environ.get("HERDR_PLUGIN_EVENT") != "pane.agent_status_changed":
            return 0
        if not ev.get("agent") or ev.get("agent_status") not in {"working", "idle", "done"}:
            return 0

    pane = pane_id_for(mode)
    if not pane:
        return 0
    if mode == "clear":
        report(pane, "")
        return 0

    try:
        info = pane_info(pane)
        cwd = info.get("foreground_cwd") or info.get("cwd") or cwd_for_current_context()
        root = find_root(cwd)
        report(pane, render_metadata(root) if root else "")
    except Exception as exc:
        log(f"{pane}: {exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
