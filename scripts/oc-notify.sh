#!/usr/bin/env bash
# Fires a macOS notification for an OpenCode pane status change.
# Click focuses Ghostty and the target zellij pane.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: oc-notify.sh --pane-name <name> --status <status> --session <name> --pane-id <id>
       oc-notify.sh --focus-now --session <name> --pane-id <id>

Notification flags (all required):
  --pane-name  Raw zellij pane title; leading "OC | " is stripped for display.
  --status     Free-form status string (e.g. idle | permission | question).
               Validation is the caller's responsibility.
  --session    Zellij session name.
  --pane-id    Numeric zellij pane id to focus on click.

Focus flags:
  --focus-now  Internal mode used by notification clicks.
EOF
  exit 2
}

attached_session_name() {
  local session_name clients_output

  while IFS= read -r session_name; do
    [[ -z $session_name ]] && continue
    clients_output="$("$ZELLIJ_BIN" -s "$session_name" action list-clients 2>/dev/null || true)"
    [[ $clients_output == "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND" ]] && continue
    case "$clients_output" in
      "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND"$'\n'[0-9]*)
        printf '%s\n' "$session_name"
        return 0
        ;;
    esac
  done < <("$ZELLIJ_BIN" list-sessions --short 2>/dev/null || true)

  return 1
}

focus_now=0
pane_name=""; status=""; session=""; pane_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus-now) focus_now=1; shift;;
    --pane-name) pane_name="${2-}"; shift 2;;
    --status)    status="${2-}";    shift 2;;
    --session)   session="${2-}";   shift 2;;
    --pane-id)   pane_id="${2-}";   shift 2;;
    -h|--help)   usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

ZELLIJ_BIN="$(command -v zellij || echo /opt/homebrew/bin/zellij)"

if [[ $focus_now -eq 1 ]]; then
  [[ -z $session || -z $pane_id ]] && usage
  attached_session="$(attached_session_name || true)"
  target_pane="terminal_${pane_id}"
  if [[ -n $attached_session ]]; then
    "$ZELLIJ_BIN" -s "$attached_session" action switch-session "$session" --pane-id "$target_pane"
  else
    "$ZELLIJ_BIN" -s "$session" action focus-pane-id "$pane_id"
  fi
  exit 0
fi

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

TN_BIN="$(command -v terminal-notifier || echo /opt/homebrew/bin/terminal-notifier)"

case "$status" in
  idle)       sound="Glass"; phrase="is ready";;
  permission) sound="Funk";  phrase="is asking for permission";;
  question)   sound="Ping";  phrase="has a question";;
  *)          sound="";      phrase="is ${status}";;
esac

title="${display_name} ${phrase}"
message="on session ${session}"

SCRIPT_PATH="$SCRIPT_DIR/oc-notify.sh"
esc_script=$(printf %q "$SCRIPT_PATH")
esc_session=$(printf %q "$session")
esc_pane_id=$(printf %q "$pane_id")

# Decide same-session vs cross-session at click time, not notification time.
exec_cmd="open -a Ghostty && ${esc_script} --focus-now --session ${esc_session} --pane-id ${esc_pane_id}"

# Group notifications by session so new ones replace older ones for the
# same session instead of stacking up in Notification Center.
# Note: -sender would give us OpenCode's icon on the left, but it also
# redirects click handling to that app and breaks -execute. So we use
# -contentImage to at least show our icon on the right side of the body.
args=(
  -title "$title"
  -message "$message"
  -contentImage "$ICON"
  -wait
  -execute "$exec_cmd"
)
[[ -n $sound ]] && args+=( -sound "$sound" )

( "$TN_BIN" "${args[@]}" >/tmp/oc-notify.log 2>&1 ) &
disown
