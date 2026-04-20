#!/usr/bin/env bash
# Fires a macOS notification for a Falcode-tracked agent pane status change.
# Click focuses Ghostty and the target zellij pane.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: oc-notify.sh --agent <agent> --pane-name <name> --status <status> --session <name> --pane-id <id>
       oc-notify.sh --focus-now --session <name> --pane-id <id>

Notification flags (all required):
  --agent      Agent identifier (e.g. opencode | pi | claude).
  --pane-name  Raw zellij pane title; leading known agent prefixes are stripped for display.
  --status     Free-form status string (e.g. idle | permission | question).
               Validation is the caller's responsibility.
  --session    Zellij session name.
  --pane-id    Numeric zellij pane id to focus on click.

Focus flags:
  --focus-now  Internal mode used by notification clicks.
EOF
  exit 2
}

STATE_DIR="${FALCODE_STATE_DIR:-${HOME:-.}/.local/state/falcode-zellij}"
LOG_FILE="$STATE_DIR/notification-clicks.log"
NOTIFIER_LOG_FILE="$STATE_DIR/terminal-notifier.log"
ATTACHED_SESSION=""
ATTACHED_SESSION_SCAN=""

ensure_log_dir() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

append_log_field() {
  local key="$1"
  local value="$2"
  printf '%s<<__FALCODE_LOG__\n%s\n__FALCODE_LOG__\n' "$key" "$value"
}

log_event() {
  local event="$1"
  shift

  ensure_log_dir
  {
    printf -- '---\n'
    append_log_field "timestamp" "$(iso_timestamp)"
    append_log_field "event" "$event"
    append_log_field "pid" "$$"
    while [[ $# -ge 2 ]]; do
      append_log_field "$1" "$2"
      shift 2
    done
  } >>"$LOG_FILE" 2>/dev/null || true
}

run_capture() {
  local __var_name="$1"
  shift
  local output rc
  if output="$("$@" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf -v "$__var_name" '%s' "$output"
  return "$rc"
}

focus_already_satisfied() {
  local output="$1"
  grep -Fq "already focused" <<<"$output"
}

command_to_string() {
  printf '%q ' "$@"
}

output_mentions_target_pane() {
  local output="$1"
  local expected_pane_id="$2"
  grep -Eq "(^|[[:space:]])(${expected_pane_id}|terminal_${expected_pane_id})([[:space:]]|$)" <<<"$output"
}

activate_ghostty() {
  if [[ -x /usr/bin/osascript ]]; then
    /usr/bin/osascript -e 'tell application "Ghostty" to activate' >/dev/null 2>&1 && return 0
  fi
  [[ -x /usr/bin/open ]] && /usr/bin/open -a Ghostty >/dev/null 2>&1 || true
}

find_attached_session() {
  local sessions_output sessions_status session_name clients_output clients_status

  ATTACHED_SESSION=""
  ATTACHED_SESSION_SCAN=""

  if run_capture sessions_output "$ZELLIJ_BIN" list-sessions --short; then
    sessions_status=0
  else
    sessions_status=$?
  fi

  ATTACHED_SESSION_SCAN+="list_sessions_status=${sessions_status}"$'\n'
  ATTACHED_SESSION_SCAN+="list_sessions_output:"$'\n'"${sessions_output}"$'\n'

  if [[ $sessions_status -ne 0 ]]; then
    return 1
  fi

  while IFS= read -r session_name; do
    [[ -z $session_name ]] && continue

    if run_capture clients_output "$ZELLIJ_BIN" -s "$session_name" action list-clients; then
      clients_status=0
    else
      clients_status=$?
    fi

    ATTACHED_SESSION_SCAN+="session=${session_name}"$'\n'
    ATTACHED_SESSION_SCAN+="clients_status=${clients_status}"$'\n'
    ATTACHED_SESSION_SCAN+="clients_output:"$'\n'"${clients_output}"$'\n'

    [[ $clients_output == "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND" ]] && continue
    case "$clients_output" in
      "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND"$'\n'[0-9]*)
        ATTACHED_SESSION="$session_name"
        return 0
        ;;
    esac
  done <<<"$sessions_output"

  return 1
}

focus_now=0
agent="opencode"
pane_name=""; status=""; session=""; pane_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus-now) focus_now=1; shift;;
    --agent)     agent="${2-}";     shift 2;;
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

  target_pane="terminal_${pane_id}"
  attempts_log=""
  attempt_count=0
  attached_session=""
  attached_session_scan=""
  post_attached_session=""
  post_attached_session_scan=""
  target_clients_output=""
  target_clients_status=1
  focus_mode=""
  focus_cmd=()
  action_output=""
  action_status=1
  worked="unknown"
  what_happened="notification click did not produce a confirmed focus"

  for attempt in 1 2 3 4 5; do
    attempt_count=$attempt

    activate_ghostty
    sleep 0.2

    attached_session=""
    attached_session_scan=""
    if find_attached_session; then
      attached_session="$ATTACHED_SESSION"
    fi
    attached_session_scan="$ATTACHED_SESSION_SCAN"

    focus_mode="direct-focus"
    focus_cmd=("$ZELLIJ_BIN" -s "$session" action focus-pane-id "$target_pane")
    if [[ -n $attached_session && $attached_session != "$session" ]]; then
      focus_mode="switch-session"
      focus_cmd=("$ZELLIJ_BIN" -s "$attached_session" action switch-session "$session" --pane-id "$target_pane")
    fi

    if action_output="$("${focus_cmd[@]}" 2>&1)"; then
      action_status=0
    else
      action_status=$?
    fi

    sleep 0.25

    post_attached_session=""
    post_attached_session_scan=""
    if find_attached_session; then
      post_attached_session="$ATTACHED_SESSION"
    fi
    post_attached_session_scan="$ATTACHED_SESSION_SCAN"

    if run_capture target_clients_output "$ZELLIJ_BIN" -s "$session" action list-clients; then
      target_clients_status=0
    else
      target_clients_status=$?
    fi

    attempts_log+="attempt=${attempt}"$'\n'
    attempts_log+="attached_session_before=${attached_session}"$'\n'
    attempts_log+="focus_mode=${focus_mode}"$'\n'
    attempts_log+="focus_command=$(command_to_string "${focus_cmd[@]}")"$'\n'
    attempts_log+="focus_command_exit_status=${action_status}"$'\n'
    attempts_log+="focus_command_output:"$'\n'"${action_output}"$'\n'
    attempts_log+="attached_session_after=${post_attached_session}"$'\n'
    attempts_log+="target_session_list_clients_exit_status=${target_clients_status}"$'\n'
    attempts_log+="target_session_list_clients_output:"$'\n'"${target_clients_output}"$'\n'

    target_confirmed=0
    if [[ $target_clients_status -eq 0 ]] && output_mentions_target_pane "$target_clients_output" "$pane_id"; then
      target_confirmed=1
    fi

    if [[ $target_confirmed -eq 1 ]]; then
      worked="yes"
      if [[ $action_status -eq 0 ]]; then
        what_happened="target pane showed up in target session client list after click"
      elif focus_already_satisfied "$action_output"; then
        what_happened="target pane was already focused when the click handler ran"
      else
        what_happened="target pane was confirmed after click despite a non-zero focus command exit status"
      fi
      break
    fi

    if [[ $action_status -ne 0 ]]; then
      worked="no"
      what_happened="focus command failed with exit status ${action_status}"
    elif [[ -n $post_attached_session && $post_attached_session == "$session" ]]; then
      worked="maybe"
      what_happened="attached client moved to target session, but target pane could not be confirmed"
    elif [[ $target_clients_status -ne 0 ]]; then
      worked="unknown"
      what_happened="focus command exited 0, but target session list-clients failed with ${target_clients_status}"
    else
      worked="unknown"
      what_happened="focus command exited 0, but post-check did not confirm the target pane"
    fi
  done

  log_event "notification_click" \
    "script_path" "$0" \
    "zellij_bin" "$ZELLIJ_BIN" \
    "requested_session" "$session" \
    "requested_pane_id" "$pane_id" \
    "target_pane_arg" "$target_pane" \
    "attempt_count" "$attempt_count" \
    "attempts_log" "$attempts_log" \
    "attached_session_before" "$attached_session" \
    "attached_session_scan_before" "$attached_session_scan" \
    "focus_mode" "$focus_mode" \
    "focus_command" "$(command_to_string "${focus_cmd[@]}")" \
    "focus_command_exit_status" "$action_status" \
    "focus_command_output" "$action_output" \
    "attached_session_after" "$post_attached_session" \
    "attached_session_scan_after" "$post_attached_session_scan" \
    "target_session_list_clients_exit_status" "$target_clients_status" \
    "target_session_list_clients_output" "$target_clients_output" \
    "worked" "$worked" \
    "what_happened" "$what_happened"

  exit 0
fi

[[ -z $pane_name || -z $status || -z $session || -z $pane_id ]] && usage

# Mirror clean_pane_title() in src/main.rs — strip known agent prefixes + trim.
display_name="${pane_name#OC | }"
display_name="${display_name#PI | }"
display_name="${display_name#"${display_name%%[![:space:]]*}"}"
display_name="${display_name%"${display_name##*[![:space:]]}"}"
case "$agent" in
  pi) default_display_name="Pi" ;;
  claude) default_display_name="Claude" ;;
  *) default_display_name="OpenCode" ;;
esac
[[ -z $display_name ]] && display_name="$default_display_name"

# Resolve project root from this script's location so assets/ path is stable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON="$PROJECT_ROOT/assets/opencode-icon.icns"
[[ -f "$ICON" ]] || ICON=""

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
# The focus-now path activates Ghostty itself and retries the zellij action.
exec_cmd="${esc_script} --focus-now --session ${esc_session} --pane-id ${esc_pane_id}"

log_event "notification_created" \
  "script_path" "$0" \
  "agent" "$agent" \
  "pane_name" "$pane_name" \
  "display_name" "$display_name" \
  "status" "$status" \
  "session" "$session" \
  "pane_id" "$pane_id" \
  "title" "$title" \
  "message" "$message" \
  "exec_cmd" "$exec_cmd" \
  "terminal_notifier_bin" "$TN_BIN" \
  "terminal_notifier_log_file" "$NOTIFIER_LOG_FILE"

# Group notifications by session so new ones replace older ones for the
# same session instead of stacking up in Notification Center.
# Note: -sender would give us OpenCode's icon on the left, but it also
# redirects click handling to that app and breaks -execute. So we use
# -contentImage to at least show our icon on the right side of the body.
args=(
  -title "$title"
  -message "$message"
  -wait
  -execute "$exec_cmd"
)
[[ -n $ICON ]] && args+=( -contentImage "$ICON" )
[[ -n $sound ]] && args+=( -sound "$sound" )

ensure_log_dir
( "$TN_BIN" "${args[@]}" >>"$NOTIFIER_LOG_FILE" 2>&1 ) &
disown
