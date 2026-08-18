#!/usr/bin/env bash
# Focus the topmost space in the sidebar list (bound to prefix+h).
# `herdr workspace list` returns spaces in sidebar order, so the first entry is
# the target; Herdr has no built-in "focus first workspace" key action.
set -euo pipefail

first=$(herdr workspace list |
  python3 -c 'import json,sys; ws=json.load(sys.stdin)["result"]["workspaces"]; print(ws[0]["workspace_id"] if ws else "")')

[ -n "$first" ] && herdr workspace focus "$first" >/dev/null
