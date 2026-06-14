#!/usr/bin/env bash
# Fires a macOS notification for a Falcode-tracked agent pane status change.
# Click focuses the terminal app and the target zellij pane.
# Set FALCODE_TERMINAL_APP to override the terminal (default: Ghostty).
# Example: export FALCODE_TERMINAL_APP="Alacritty"
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: oc-notify.sh --agent <agent> --pane-name <name> --status <status> --session <name> --pane-id <id>
       oc-notify.sh --focus-now --session <name> --pane-id <id>

Notification flags (all required):
  --agent      Agent identifier (e.g. opencode | pi | claude).
  --pane-name  Folder/agent label used as the heading fallback when the pane carries
               no conversation title; leading known agent prefixes are stripped.
  --pane-title Live conversation title the agent gave the pane (optional). When
               absent, falls back to the detection snapshot, then to --pane-name.
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
SNAPSHOT_FILE="${FALCODE_SNAPSHOT_FILE:-$STATE_DIR/detect-active-opencode.snapshot.tsv}"
ATTACHED_SESSION=""
ATTACHED_SESSION_SCAN=""
TERMINAL_ACTIVATION_METHOD=""
TERMINAL_ACTIVATION_STATUS=1
TERMINAL_ACTIVATION_OUTPUT=""

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

capture_session_clients() {
  local session_name="$1"
  local __output_var_name="$2"
  local __status_var_name="$3"
  local output rc

  if run_capture output "$ZELLIJ_BIN" -s "$session_name" action list-clients; then
    rc=0
  else
    rc=$?
  fi

  printf -v "$__output_var_name" '%s' "$output"
  printf -v "$__status_var_name" '%s' "$rc"
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

extract_session_clients_from_scan() {
  local session_scan="$1"
  local target_session="$2"
  local __output_var_name="$3"
  local __status_var_name="$4"
  local block output status found

  block="$(awk -v target="session=${target_session}" '
    $0 == target { in_block = 1; next }
    in_block && /^session=/ { exit }
    in_block { print }
  ' <<<"$session_scan")"

  output=""
  status="1"
  found=1

  if [[ -n $block ]]; then
    found=0
    status="$(sed -n 's/^clients_status=//p' <<<"$block" | head -n 1)"
    output="$(awk '
      /^clients_output:$/ { capture = 1; next }
      capture { print }
    ' <<<"$block")"
    [[ -z $status ]] && status="1"
  fi

  printf -v "$__output_var_name" '%s' "$output"
  printf -v "$__status_var_name" '%s' "$status"
  return "$found"
}

confirm_target_focus() {
  local session_scan="$1"
  local target_session="$2"
  local expected_pane_id="$3"
  local __scan_output_var_name="$4"
  local __scan_status_var_name="$5"
  local __confirmed_var_name="$6"
  local scan_output scan_status confirmed extracted_from_scan

  extracted_from_scan=1
  if extract_session_clients_from_scan "$session_scan" "$target_session" scan_output scan_status; then
    extracted_from_scan=0
  else
    capture_session_clients "$target_session" scan_output scan_status
  fi

  confirmed=0
  if [[ $scan_status -eq 0 ]] && output_mentions_target_pane "$scan_output" "$expected_pane_id"; then
    confirmed=1
  fi

  if [[ $confirmed -eq 0 && $extracted_from_scan -eq 0 && -z $scan_output ]]; then
    capture_session_clients "$target_session" scan_output scan_status
    if [[ $scan_status -eq 0 ]] && output_mentions_target_pane "$scan_output" "$expected_pane_id"; then
      confirmed=1
    fi
  fi

  printf -v "$__scan_output_var_name" '%s' "$scan_output"
  printf -v "$__scan_status_var_name" '%s' "$scan_status"
  printf -v "$__confirmed_var_name" '%s' "$confirmed"
}

activate_terminal() {
  local output=""
  local rc=1
  local notes=""
  local terminal_app="${FALCODE_TERMINAL_APP:-Ghostty}"

  TERMINAL_ACTIVATION_METHOD="none"
  TERMINAL_ACTIVATION_STATUS=1
  TERMINAL_ACTIVATION_OUTPUT=""

  if [[ -x /usr/bin/osascript ]]; then
    if run_capture output /usr/bin/osascript -e "tell application \"${terminal_app}\" to activate"; then
      TERMINAL_ACTIVATION_METHOD="osascript"
      TERMINAL_ACTIVATION_STATUS=0
      TERMINAL_ACTIVATION_OUTPUT="$output"
      return 0
    else
      rc=$?
      notes+="osascript_exit_status=${rc}"$'\n'
      notes+="osascript_output:"$'\n'"${output}"$'\n'
    fi
  else
    notes+="osascript_missing=1"$'\n'
  fi

  if [[ -x /usr/bin/open ]]; then
    if run_capture output /usr/bin/open -a "${terminal_app}"; then
      TERMINAL_ACTIVATION_METHOD="open"
      TERMINAL_ACTIVATION_STATUS=0
      TERMINAL_ACTIVATION_OUTPUT="${notes}open_output:"$'\n'"${output}"
      return 0
    else
      rc=$?
      notes+="open_exit_status=${rc}"$'\n'
      notes+="open_output:"$'\n'"${output}"$'\n'
    fi
  else
    notes+="open_missing=1"$'\n'
  fi

  TERMINAL_ACTIVATION_METHOD="failed"
  TERMINAL_ACTIVATION_STATUS="$rc"
  TERMINAL_ACTIVATION_OUTPUT="$notes"
  return 1
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
pane_name=""; status=""; session=""; pane_id=""; pane_title_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus-now)  focus_now=1; shift;;
    --agent)      agent="${2-}";          shift 2;;
    --pane-name)  pane_name="${2-}";      shift 2;;
    --pane-title) pane_title_arg="${2-}"; shift 2;;
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
  attached_session_clients_before_output=""
  attached_session_clients_before_status=1
  attached_session_clients_after_output=""
  attached_session_clients_after_status=1
  post_attached_session=""
  post_attached_session_scan=""
  target_clients_before_output=""
  target_clients_before_status=1
  target_clients_output=""
  target_clients_status=1
  target_confirmed=0
  focus_mode=""
  focus_command=""
  focus_command_output=""
  focus_command_exit_status=1
  fallback_mode=""
  fallback_command=""
  fallback_command_output=""
  fallback_command_exit_status=1
  fallback_followup_command=""
  fallback_followup_command_output=""
  fallback_followup_command_exit_status=1
  worked="unknown"
  what_happened="notification click did not produce a confirmed focus"
  terminal_activation_method=""
  terminal_activation_status=1
  terminal_activation_output=""

  for attempt in 1 2 3; do
    attempt_count=$attempt

    case "$attempt" in
      1) activation_settle_delay=0.08; post_action_delay=0.12 ;;
      2) activation_settle_delay=0.15; post_action_delay=0.18 ;;
      *) activation_settle_delay=0.25; post_action_delay=0.25 ;;
    esac

    activate_terminal || true
    terminal_activation_method="$TERMINAL_ACTIVATION_METHOD"
    terminal_activation_status="$TERMINAL_ACTIVATION_STATUS"
    terminal_activation_output="$TERMINAL_ACTIVATION_OUTPUT"
    sleep "$activation_settle_delay"

    attached_session=""
    attached_session_scan=""
    if find_attached_session; then
      attached_session="$ATTACHED_SESSION"
    fi
    attached_session_scan="$ATTACHED_SESSION_SCAN"

    attached_session_clients_before_output=""
    attached_session_clients_before_status=1
    if [[ -n $attached_session ]]; then
      capture_session_clients "$attached_session" attached_session_clients_before_output attached_session_clients_before_status
    fi

    capture_session_clients "$session" target_clients_before_output target_clients_before_status

    focus_mode="direct-focus"
    focus_command_output=""
    focus_command_exit_status=1
    if [[ -n $attached_session && $attached_session != "$session" ]]; then
      focus_mode="switch-session-with-pane"
      if run_capture focus_command_output "$ZELLIJ_BIN" -s "$attached_session" action switch-session "$session" --pane-id "$target_pane"; then
        focus_command_exit_status=0
      else
        focus_command_exit_status=$?
      fi
      focus_command="$(command_to_string "$ZELLIJ_BIN" -s "$attached_session" action switch-session "$session" --pane-id "$target_pane")"
    else
      if run_capture focus_command_output "$ZELLIJ_BIN" -s "$session" action focus-pane-id "$target_pane"; then
        focus_command_exit_status=0
      else
        focus_command_exit_status=$?
      fi
      focus_command="$(command_to_string "$ZELLIJ_BIN" -s "$session" action focus-pane-id "$target_pane")"
    fi

    sleep "$post_action_delay"

    post_attached_session=""
    post_attached_session_scan=""
    if find_attached_session; then
      post_attached_session="$ATTACHED_SESSION"
    fi
    post_attached_session_scan="$ATTACHED_SESSION_SCAN"

    attached_session_clients_after_output=""
    attached_session_clients_after_status=1
    if [[ -n $post_attached_session ]]; then
      capture_session_clients "$post_attached_session" attached_session_clients_after_output attached_session_clients_after_status
    fi

    confirm_target_focus "$post_attached_session_scan" "$session" "$pane_id" target_clients_output target_clients_status target_confirmed

    fallback_mode=""
    fallback_command=""
    fallback_command_output=""
    fallback_command_exit_status=1
    fallback_followup_command=""
    fallback_followup_command_output=""
    fallback_followup_command_exit_status=1

    if [[ $target_confirmed -ne 1 && -n $attached_session && $attached_session != "$session" ]]; then
      fallback_source_session="$post_attached_session"
      [[ -z $fallback_source_session ]] && fallback_source_session="$attached_session"

      if [[ -n $fallback_source_session && $fallback_source_session != "$session" ]]; then
        fallback_mode="switch-session-then-focus"

        if run_capture fallback_command_output "$ZELLIJ_BIN" -s "$fallback_source_session" action switch-session "$session"; then
          fallback_command_exit_status=0
        else
          fallback_command_exit_status=$?
        fi
        fallback_command="$(command_to_string "$ZELLIJ_BIN" -s "$fallback_source_session" action switch-session "$session")"

        sleep "$post_action_delay"

        post_attached_session=""
        post_attached_session_scan=""
        if find_attached_session; then
          post_attached_session="$ATTACHED_SESSION"
        fi
        post_attached_session_scan="$ATTACHED_SESSION_SCAN"

        attached_session_clients_after_output=""
        attached_session_clients_after_status=1
        if [[ -n $post_attached_session ]]; then
          capture_session_clients "$post_attached_session" attached_session_clients_after_output attached_session_clients_after_status
        fi

        confirm_target_focus "$post_attached_session_scan" "$session" "$pane_id" target_clients_output target_clients_status target_confirmed
      fi

      if [[ $target_confirmed -ne 1 ]]; then
        if run_capture fallback_followup_command_output "$ZELLIJ_BIN" -s "$session" action focus-pane-id "$target_pane"; then
          fallback_followup_command_exit_status=0
        else
          fallback_followup_command_exit_status=$?
        fi
        fallback_followup_command="$(command_to_string "$ZELLIJ_BIN" -s "$session" action focus-pane-id "$target_pane")"

        sleep "$post_action_delay"

        post_attached_session=""
        post_attached_session_scan=""
        if find_attached_session; then
          post_attached_session="$ATTACHED_SESSION"
        fi
        post_attached_session_scan="$ATTACHED_SESSION_SCAN"

        attached_session_clients_after_output=""
        attached_session_clients_after_status=1
        if [[ -n $post_attached_session ]]; then
          capture_session_clients "$post_attached_session" attached_session_clients_after_output attached_session_clients_after_status
        fi

        confirm_target_focus "$post_attached_session_scan" "$session" "$pane_id" target_clients_output target_clients_status target_confirmed

        if [[ $target_confirmed -eq 1 ]]; then
          focus_mode="switch-session-then-focus"
          focus_command="$fallback_followup_command"
          focus_command_output="$fallback_followup_command_output"
          focus_command_exit_status="$fallback_followup_command_exit_status"
        fi
      elif [[ $fallback_command_exit_status -eq 0 ]]; then
        focus_mode="switch-session-only"
        focus_command="$fallback_command"
        focus_command_output="$fallback_command_output"
        focus_command_exit_status="$fallback_command_exit_status"
      fi
    fi

    attempts_log+="attempt=${attempt}"$'\n'
    attempts_log+="activation_settle_delay=${activation_settle_delay}"$'\n'
    attempts_log+="post_action_delay=${post_action_delay}"$'\n'
    attempts_log+="terminal_activation_method=${terminal_activation_method}"$'\n'
    attempts_log+="terminal_activation_status=${terminal_activation_status}"$'\n'
    attempts_log+="terminal_activation_output:"$'\n'"${terminal_activation_output}"$'\n'
    attempts_log+="attached_session_before=${attached_session}"$'\n'
    attempts_log+="attached_session_clients_before_exit_status=${attached_session_clients_before_status}"$'\n'
    attempts_log+="attached_session_clients_before_output:"$'\n'"${attached_session_clients_before_output}"$'\n'
    attempts_log+="target_session_list_clients_before_exit_status=${target_clients_before_status}"$'\n'
    attempts_log+="target_session_list_clients_before_output:"$'\n'"${target_clients_before_output}"$'\n'
    attempts_log+="focus_mode=${focus_mode}"$'\n'
    attempts_log+="focus_command=${focus_command}"$'\n'
    attempts_log+="focus_command_exit_status=${focus_command_exit_status}"$'\n'
    attempts_log+="focus_command_output:"$'\n'"${focus_command_output}"$'\n'
    attempts_log+="fallback_mode=${fallback_mode}"$'\n'
    attempts_log+="fallback_command=${fallback_command}"$'\n'
    attempts_log+="fallback_command_exit_status=${fallback_command_exit_status}"$'\n'
    attempts_log+="fallback_command_output:"$'\n'"${fallback_command_output}"$'\n'
    attempts_log+="fallback_followup_command=${fallback_followup_command}"$'\n'
    attempts_log+="fallback_followup_command_exit_status=${fallback_followup_command_exit_status}"$'\n'
    attempts_log+="fallback_followup_command_output:"$'\n'"${fallback_followup_command_output}"$'\n'
    attempts_log+="attached_session_after=${post_attached_session}"$'\n'
    attempts_log+="attached_session_clients_after_exit_status=${attached_session_clients_after_status}"$'\n'
    attempts_log+="attached_session_clients_after_output:"$'\n'"${attached_session_clients_after_output}"$'\n'
    attempts_log+="target_session_list_clients_exit_status=${target_clients_status}"$'\n'
    attempts_log+="target_session_list_clients_output:"$'\n'"${target_clients_output}"$'\n'
    attempts_log+="target_confirmed=${target_confirmed}"$'\n'

    if [[ $target_confirmed -eq 1 ]]; then
      worked="yes"
      if [[ $focus_command_exit_status -eq 0 ]]; then
        case "$focus_mode" in
          direct-focus)
            what_happened="target pane was focused directly after click"
            ;;
          switch-session-with-pane)
            what_happened="target session switched and target pane showed up after click"
            ;;
          switch-session-only)
            what_happened="switch-session without --pane-id succeeded after the initial command stalled"
            ;;
          switch-session-then-focus)
            what_happened="fallback switch-session plus explicit focus-pane-id recovered the click"
            ;;
          *)
            what_happened="target pane showed up in target session client list after click"
            ;;
        esac
      elif focus_already_satisfied "$focus_command_output"; then
        what_happened="target pane was already focused when the click handler ran"
      else
        what_happened="target pane was confirmed after click despite a non-zero focus command exit status"
      fi
      break
    fi

    if [[ $focus_command_exit_status -ne 0 ]]; then
      worked="no"
      what_happened="primary focus command failed with exit status ${focus_command_exit_status}"
    elif [[ -n $fallback_command && $fallback_command_exit_status -ne 0 ]]; then
      worked="no"
      what_happened="fallback switch-session command failed with exit status ${fallback_command_exit_status}"
    elif [[ -n $post_attached_session && $post_attached_session == "$session" ]]; then
      worked="maybe"
      what_happened="attached client moved to target session, but target pane could not be confirmed"
    elif [[ $target_clients_status -ne 0 ]]; then
      worked="unknown"
      what_happened="focus command exited 0, but target session list-clients failed with ${target_clients_status}"
    else
      worked="unknown"
      what_happened="focus command sequence exited 0, but post-check did not confirm the target pane"
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
    "terminal_activation_method" "$terminal_activation_method" \
    "terminal_activation_status" "$terminal_activation_status" \
    "terminal_activation_output" "$terminal_activation_output" \
    "attached_session_before" "$attached_session" \
    "attached_session_scan_before" "$attached_session_scan" \
    "attached_session_clients_before_exit_status" "$attached_session_clients_before_status" \
    "attached_session_clients_before_output" "$attached_session_clients_before_output" \
    "target_session_list_clients_before_exit_status" "$target_clients_before_status" \
    "target_session_list_clients_before_output" "$target_clients_before_output" \
    "focus_mode" "$focus_mode" \
    "focus_command" "$focus_command" \
    "focus_command_exit_status" "$focus_command_exit_status" \
    "focus_command_output" "$focus_command_output" \
    "fallback_mode" "$fallback_mode" \
    "fallback_command" "$fallback_command" \
    "fallback_command_exit_status" "$fallback_command_exit_status" \
    "fallback_command_output" "$fallback_command_output" \
    "fallback_followup_command" "$fallback_followup_command" \
    "fallback_followup_command_exit_status" "$fallback_followup_command_exit_status" \
    "fallback_followup_command_output" "$fallback_followup_command_output" \
    "attached_session_after" "$post_attached_session" \
    "attached_session_scan_after" "$post_attached_session_scan" \
    "attached_session_clients_after_exit_status" "$attached_session_clients_after_status" \
    "attached_session_clients_after_output" "$attached_session_clients_after_output" \
    "target_session_list_clients_exit_status" "$target_clients_status" \
    "target_session_list_clients_output" "$target_clients_output" \
    "target_confirmed" "$target_confirmed" \
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

# Resolve the live pane title — what the agent renamed the pane to, reflecting
# the current conversation. Prefer the caller-supplied title (the Claude hook
# pulls it straight from the transcript, always fresh); otherwise fall back to
# the plugin's detection snapshot, which is only current while the popup is open.
# Snapshot line format:
#   pane<TAB>session<TAB>pane_id<TAB>tab_pos<TAB>tab_name<TAB>pane_title<TAB>cmd
pane_title="$pane_title_arg"
if [[ -z $pane_title && -f $SNAPSHOT_FILE ]]; then
  pane_title="$(awk -F '\t' -v s="$session" -v p="$pane_id" '
    $1 == "pane" && $2 == s && $3 == p { print $6; exit }
  ' "$SNAPSHOT_FILE" 2>/dev/null || true)"
fi
# Mirror clean_pane_title() in src/main.rs — strip known agent prefixes + trim.
pane_title="${pane_title#OC | }"
pane_title="${pane_title#PI | }"
pane_title="${pane_title#"${pane_title%%[![:space:]]*}"}"
pane_title="${pane_title%"${pane_title##*[![:space:]]}"}"

# A pane only counts as "renamed" when its title carries real context — not the
# bare agent name (clean_pane_title's fallback) and not just the folder we'd
# show anyway. Otherwise fall back to the folder-only heading.
folder="$display_name"
renamed=0
if [[ -n $pane_title ]]; then
  lc_title="$(printf '%s' "$pane_title" | tr '[:upper:]' '[:lower:]')"
  lc_folder="$(printf '%s' "$folder" | tr '[:upper:]' '[:lower:]')"
  case "$lc_title" in
    claude|pi|opencode|"$lc_folder") ;;
    *) renamed=1 ;;
  esac
fi

# Icon reflects what the pane needs from the user: approval, an answer, or
# nothing (it finished and is ready).
case "$status" in
  idle)       sound="Glass"; icon="✅";;
  permission) sound="Funk";  icon="🔐";;
  question)   sound="Ping";  icon="❓";;
  *)          sound="";      icon="🔔";;
esac

if [[ $renamed -eq 1 ]]; then
  title="${icon} ${pane_title}"
  message="${folder} / ${session}"
else
  title="${icon} ${folder}"
  message="${session}"
fi

SCRIPT_PATH="$SCRIPT_DIR/oc-notify.sh"
esc_script=$(printf %q "$SCRIPT_PATH")
esc_session=$(printf %q "$session")
esc_pane_id=$(printf %q "$pane_id")

# Decide same-session vs cross-session at click time, not notification time.
# The focus-now path activates the terminal app and retries the zellij action.
exec_cmd="${esc_script} --focus-now --session ${esc_session} --pane-id ${esc_pane_id}"

log_event "notification_created" \
  "script_path" "$0" \
  "agent" "$agent" \
  "pane_name" "$pane_name" \
  "display_name" "$display_name" \
  "folder" "$folder" \
  "pane_title" "$pane_title" \
  "renamed" "$renamed" \
  "icon" "$icon" \
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
