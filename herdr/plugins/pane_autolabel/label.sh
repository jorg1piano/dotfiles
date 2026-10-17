#!/bin/sh
set -u

herdr="${HERDR_BIN_PATH:-herdr}"
jq=$(command -v jq || echo /usr/bin/jq)

pane=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')
[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || exit 0

info=$("$herdr" pane get "$pane") || exit 0
tab=$(printf '%s' "$info" | "$jq" -r '.result.pane.tab_id')
workspace=$(printf '%s' "$info" | "$jq" -r '.result.pane.workspace_id')

tab_label=$("$herdr" tab get "$tab" | "$jq" -r '.result.tab.label // empty')
[ -n "$tab_label" ] || exit 0

next=$("$herdr" pane list --workspace "$workspace" | "$jq" -r \
  --arg tab "$tab" --arg prefix "$tab_label:" '
  [ .result.panes[]
    | select(.tab_id == $tab)
    | .label // ""
    | select(startswith($prefix))
    | ltrimstr($prefix)
    | tonumber? ] | max // 0 | . + 1')

"$herdr" pane rename "$pane" "$tab_label:$next" >/dev/null
