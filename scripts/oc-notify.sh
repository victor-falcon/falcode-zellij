#!/usr/bin/env bash
# Fires a macOS notification for an OpenCode pane status change.
# Click focuses Ghostty and the target zellij pane.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: oc-notify.sh --pane-name <name> --status <status> --session <name> --pane-id <id>

Flags (all required):
  --pane-name  Raw zellij pane title; leading "OC | " is stripped for display.
  --status     Free-form status string (e.g. idle | permission | question).
               Validation is the caller's responsibility.
  --session    Zellij session name.
  --pane-id    Numeric zellij pane id to focus on click.
EOF
  exit 2
}

pane_name=""; status=""; session=""; pane_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pane-name) pane_name="${2-}"; shift 2;;
    --status)    status="${2-}";    shift 2;;
    --session)   session="${2-}";   shift 2;;
    --pane-id)   pane_id="${2-}";   shift 2;;
    -h|--help)   usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[[ -z $pane_name || -z $status || -z $session || -z $pane_id ]] && usage

# Mirror clean_pane_title() in src/main.rs:1105 — strip "OC | " + trim.
display_name="${pane_name#OC | }"
display_name="${display_name#"${display_name%%[![:space:]]*}"}"
display_name="${display_name%"${display_name##*[![:space:]]}"}"
[[ -z $display_name ]] && display_name="OpenCode"

# Resolve project root from this script's location so assets/ path is stable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON="$PROJECT_ROOT/assets/opencode-icon.icns"

ZELLIJ_BIN="$(command -v zellij || echo /opt/homebrew/bin/zellij)"
TN_BIN="$(command -v terminal-notifier || echo /opt/homebrew/bin/terminal-notifier)"

case "$status" in
  idle)       sound="Glass"; phrase="is ready";;
  permission) sound="Funk";  phrase="is asking for permission";;
  question)   sound="Ping";  phrase="has a question";;
  *)          sound="";      phrase="is ${status}";;
esac

title="${display_name} ${phrase}"
message="on session ${session}"

esc_zellij=$(printf %q "$ZELLIJ_BIN")
esc_session=$(printf %q "$session")
esc_pane=$(printf %q "$pane_id")
exec_cmd="open -a Ghostty && ${esc_zellij} -s ${esc_session} action focus-pane-id ${esc_pane}"

# Group notifications by session so new ones replace older ones for the
# same session instead of stacking up in Notification Center.
# Note: -sender would give us OpenCode's icon on the left, but it also
# redirects click handling to that app and breaks -execute. So we use
# -contentImage to at least show our icon on the right side of the body.
args=(
  -title "$title"
  -message "$message"
  -contentImage "$ICON"
  -group "oc-notify:${session}"
  -wait
  -execute "$exec_cmd"
)
[[ -n $sound ]] && args+=( -sound "$sound" )

( "$TN_BIN" "${args[@]}" >/tmp/oc-notify.log 2>&1 ) &
disown
