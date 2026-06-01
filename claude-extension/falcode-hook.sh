#!/usr/bin/env bash
# Claude Code hook for Falcode-Zellij session status reporting.
#
# Invoked by ~/.claude/settings.json hooks. Reads the event JSON from stdin
# and writes a pane state file under $FALCODE_STATE_DIR/panes/, matching
# the format used by opencode-plugin/falcode.js and pi-extension/falcode.ts.
#
# Usage: falcode-hook.sh <EventName>
#   EventName ∈ {SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
#                Notification, Stop, SessionEnd}
#
# SubagentStop is intentionally NOT handled — it fires when a Task-tool
# subagent finishes while the parent session is still working, which would
# produce a spurious "idle" notification before the parent's real Stop.
#
# Always exits 0 so a misbehaving hook never blocks Claude Code.

set -uo pipefail

EVENT="${1:-}"
[[ -z $EVENT ]] && exit 0

PANE_ID="${ZELLIJ_PANE_ID:-}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-}"
# Outside zellij: nothing to track.
[[ -z $PANE_ID || -z $SESSION_NAME ]] && exit 0

STATE_ROOT="${FALCODE_STATE_DIR:-${HOME:-.}/.local/state/falcode-zellij}"
PANES_DIR="$STATE_ROOT/panes"
mkdir -p "$PANES_DIR" 2>/dev/null || exit 0

SAFE_SESSION="${SESSION_NAME//[^a-zA-Z0-9_-]/_}"
STATE_FILE="$PANES_DIR/${SAFE_SESSION}_${PANE_ID}.json"
NOTIFY_SCRIPT="${FALCODE_NOTIFY_SCRIPT:-$STATE_ROOT/oc-notify.sh}"

# Drain stdin JSON if present so Claude Code doesn't see a broken pipe.
STDIN_JSON=""
if [[ ! -t 0 ]]; then
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

# Opt-in debug log of raw hook payloads (set FALCODE_CLAUDE_HOOK_DEBUG=1).
# Off by default; capped at ~256 KiB to avoid runaway growth.
if [[ ${FALCODE_CLAUDE_HOOK_DEBUG:-0} == "1" ]]; then
  DEBUG_LOG="$STATE_ROOT/claude-hook.log"
  if [[ -f $DEBUG_LOG ]] && [[ $(wc -c <"$DEBUG_LOG" 2>/dev/null || echo 0) -gt 262144 ]]; then
    rm -f "$DEBUG_LOG"
  fi
  {
    printf -- '--- %s event=%s session=%s pane=%s\n' \
      "$(date -u +%FT%TZ)" "$EVENT" "$SESSION_NAME" "$PANE_ID"
    printf '%s\n' "$STDIN_JSON"
  } >>"$DEBUG_LOG" 2>/dev/null || true
fi

# Extract a top-level string field from the JSON payload (Notification only).
hook_field() {
  python3 -c '
import json, sys
key = sys.argv[1]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
val = data.get(key)
if isinstance(val, str):
    print(val)
' "$1" 2>/dev/null
}

# SessionEnd: drop the state file so the popup stops listing this pane.
if [[ $EVENT == "SessionEnd" ]]; then
  rm -f "$STATE_FILE"
  exit 0
fi

case "$EVENT" in
  SessionStart)
    STATUS="waiting_user_input"
    ;;
  UserPromptSubmit|PreToolUse|PostToolUse)
    STATUS="working"
    ;;
  Notification)
    # Claude fires Notification for several distinct flavors, disambiguated by
    # the top-level `notification_type` field (NOT the free-form `message`,
    # whose wording is undocumented and varies — e.g. permission prompts read
    # "Tool requires permission to execute", which matched no message regex and
    # used to fall through to a bogus "question" notification).
    #
    # Only two flavors mean "the user must act":
    #   permission_prompt  -> a tool needs approval        (asking_permissions)
    #   elicitation_dialog -> an MCP server wants input    (waiting_user_answers)
    # The rest are informational and must NOT raise attention:
    #   idle_prompt          -> 60s "waiting for you" nag; duplicates the Stop
    #                           event's idle notification.
    #   auth_success         -> login succeeded.
    #   elicitation_complete -> user already answered the elicitation.
    #   elicitation_response -> response forwarded to the MCP server.
    ntype=""
    notification_message=""
    if [[ -n $STDIN_JSON ]]; then
      ntype="$(hook_field notification_type <<<"$STDIN_JSON")"
      notification_message="$(hook_field message <<<"$STDIN_JSON")"
    fi
    case "$ntype" in
      permission_prompt)
        STATUS="asking_permissions"
        ;;
      elicitation_dialog)
        STATUS="waiting_user_answers"
        ;;
      idle_prompt|auth_success|elicitation_complete|elicitation_response)
        exit 0
        ;;
      "")
        # Pre-notification_type Claude Code: fall back to message text, but only
        # ever escalate to a permission prompt — never fabricate a question.
        if grep -qiE 'permission' <<<"$notification_message"; then
          STATUS="asking_permissions"
        else
          exit 0
        fi
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  Stop)
    STATUS="waiting_user_input"
    ;;
  *)
    exit 0
    ;;
esac

# Read prev status from existing state file (only if it belongs to claude;
# a stale file from another agent must not trigger a fake transition).
PREV_STATUS="waiting_user_input"
HAD_PREV=0
if [[ -f $STATE_FILE ]]; then
  prev_agent="$(sed -n 's/.*"agent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1)"
  if [[ $prev_agent == "claude" ]]; then
    HAD_PREV=1
    prev_status_value="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1)"
    [[ -n $prev_status_value ]] && PREV_STATUS="$prev_status_value"
  fi
fi

NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo "$(($(date +%s) * 1000))")"
CWD="${PWD:-}"
STABLE_ID="${SESSION_NAME}:${PANE_ID}"

python3 - "$STATE_FILE" "$STABLE_ID" "$PANE_ID" "$SESSION_NAME" "$STATUS" "$CWD" "$NOW_MS" <<'PY' 2>/dev/null || true
import json
import sys

state_file, stable_id, pane_id, session_name, status, cwd, updated_at_ms = sys.argv[1:8]
payload = {
    "agent": "claude",
    "cwd": cwd,
    "stable_id": stable_id,
    "pane_id": int(pane_id),
    "session_name": session_name,
    "status": status,
    "updated_at_ms": int(updated_at_ms),
}
with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY

# First write (no prior claude state) and no-op transitions are silent.
if [[ $HAD_PREV -eq 0 || $STATUS == "$PREV_STATUS" ]]; then
  exit 0
fi

# zellij-attention pipe: same contract as opencode-plugin/pi-extension.
if [[ ${FALCODE_DISABLE_ATTENTION:-} != "1" ]]; then
  was_active=0
  is_active=0
  case "$PREV_STATUS" in working|asking_permissions|waiting_user_answers) was_active=1;; esac
  case "$STATUS"      in working|asking_permissions|waiting_user_answers) is_active=1;;  esac
  attention_event=""
  if [[ $was_active -eq 0 && $is_active -eq 1 ]]; then
    attention_event="${FALCODE_ATTENTION_ENTER_EVENT:-waiting}"
  elif [[ $was_active -eq 1 && $is_active -eq 0 ]]; then
    attention_event="${FALCODE_ATTENTION_EXIT_EVENT:-completed}"
  fi
  if [[ -n $attention_event ]]; then
    ( zellij pipe --name "zellij-attention::${attention_event}::${PANE_ID}" >/dev/null 2>&1 & )
  fi
fi

# Notification via oc-notify.sh.
notify_status=""
case "$STATUS" in
  asking_permissions)
    notify_status="permission"
    ;;
  waiting_user_answers)
    notify_status="question"
    ;;
  waiting_user_input)
    case "$PREV_STATUS" in working|asking_permissions|waiting_user_answers) notify_status="idle";; esac
    ;;
esac

if [[ -n $notify_status && -x $NOTIFY_SCRIPT ]]; then
  display_name="Claude"
  [[ -n $CWD ]] && display_name="$(basename "$CWD")"

  # The pane title Claude shows is its generated conversation title, stored as
  # the latest `ai-title` entry in the transcript. Read it straight from there
  # so the notification matches the pane even when the popup (and its snapshot)
  # is closed.
  pane_title=""
  transcript_path=""
  [[ -n $STDIN_JSON ]] && transcript_path="$(hook_field transcript_path <<<"$STDIN_JSON")"
  if [[ -n $transcript_path && -f $transcript_path ]]; then
    pane_title="$(python3 - "$transcript_path" <<'PY' 2>/dev/null || true
import json, sys
title = ""
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") == "ai-title" and isinstance(obj.get("aiTitle"), str):
                title = obj["aiTitle"]
except Exception:
    pass
print(title)
PY
)"
  fi

  ( "$NOTIFY_SCRIPT" \
      --agent claude \
      --pane-name "$display_name" \
      --pane-title "$pane_title" \
      --status "$notify_status" \
      --session "$SESSION_NAME" \
      --pane-id "$PANE_ID" >/dev/null 2>&1 & )
fi

exit 0
