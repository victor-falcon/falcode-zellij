#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR=${FALCODE_STATE_DIR:-$SCRIPT_DIR}
SNAPSHOT_FILE=${FALCODE_SNAPSHOT_FILE:-$STATE_DIR/detect-active-opencode.snapshot.tsv}
CACHE_FILE=${FALCODE_CACHE_FILE:-$STATE_DIR/popup-cache.json}
CURRENT_SESSION=${FALCODE_CURRENT_SESSION:-}
NOW_MS=${FALCODE_NOW_MS:-$(python3 -c 'import time; print(int(time.time() * 1000))')}
MAX_AGE_MS=${FALCODE_MAX_PANE_STATE_AGE_MS:-180000}

if [ ! -f "$SNAPSHOT_FILE" ] && [ -f "$CACHE_FILE" ]; then
  if python3 - "$CACHE_FILE" "$NOW_MS" "$MAX_AGE_MS" <<'PY'
import json
import sys

cache_file = sys.argv[1]
now_ms = int(sys.argv[2])
max_age_ms = int(sys.argv[3])

try:
    with open(cache_file, encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    raise SystemExit(1)

entries = payload.get("entries")
generated_at_ms = int(payload.get("generated_at_ms") or 0)
if not isinstance(entries, list):
    raise SystemExit(1)
if generated_at_ms and now_ms - generated_at_ms > max_age_ms:
    raise SystemExit(1)

json.dump(entries, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
  then
    exit 0
  fi
fi

tmp_input=$(mktemp "${TMPDIR:-/tmp}/falcode-detect.XXXXXX")
cleanup() {
  rm -f "$tmp_input"
}
trap cleanup EXIT HUP INT TERM

has_snapshot=0
if [ -f "$SNAPSHOT_FILE" ]; then
  has_snapshot=1
  cp "$SNAPSHOT_FILE" "$tmp_input"
fi

python3 - "$STATE_DIR" "$tmp_input" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])

def clean(value):
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")

def append_tracked(pane):
    session_name = clean(pane.get("session_name"))
    pane_id = pane.get("pane_id")
    status = clean(pane.get("status"))
    agent = clean(pane.get("agent"))
    if not session_name or pane_id is None or not status or not agent:
        return None
    cwd = clean(pane.get("cwd"))
    updated_at_ms = pane.get("updated_at_ms", 0)
    return f"tracked\t{session_name}\t{pane_id}\t{status}\t{agent}\t{cwd}\t{updated_at_ms}\n"

records = []
seen_sessions = set()

panes_dir = state_dir / "panes"
if panes_dir.is_dir():
    for pane_file in sorted(panes_dir.glob("*.json")):
        try:
            pane = json.loads(pane_file.read_text(encoding="utf-8"))
        except Exception:
            continue
        record = append_tracked(pane)
        if record is None:
            continue
        session_name = clean(pane.get("session_name"))
        if session_name and session_name not in seen_sessions:
            records.append(f"session\t{session_name}\n")
            seen_sessions.add(session_name)
        records.append(record)

legacy_state = state_dir / "opencode-sessions.json"
if legacy_state.is_file() and not records:
    try:
        data = json.loads(legacy_state.read_text(encoding="utf-8"))
    except Exception:
        data = {}
    for pane in (data.get("panes") or {}).values():
        record = append_tracked(pane)
        if record is None:
            continue
        session_name = clean(pane.get("session_name"))
        if session_name and session_name not in seen_sessions:
            records.append(f"session\t{session_name}\n")
            seen_sessions.add(session_name)
        records.append(record)

if records:
    with output_path.open("a", encoding="utf-8") as fh:
        for record in records:
            fh.write(record)
PY

awk -F '\t' -v current_session="$CURRENT_SESSION" -v now_ms="$NOW_MS" -v max_age_ms="$MAX_AGE_MS" -v has_snapshot="$has_snapshot" '
  function decode_field(value) {
    gsub(/\r/, " ", value)
    gsub(/\n/, " ", value)
    return value
  }

  function json_escape(value) {
    gsub(/\\/, "\\\\", value)
    gsub(/"/, "\\\"", value)
    gsub(/\t/, " ", value)
    gsub(/\r/, " ", value)
    gsub(/\n/, " ", value)
    return value
  }

  function agent_name(agent) {
    return agent == "claude" ? "Claude" : "OpenCode"
  }

  function is_supported_agent(agent) {
    return agent == "opencode" || agent == "claude"
  }

  function is_agent_pane(title, command, lower_command) {
    lower_command = tolower(command)
    return index(lower_command, "opencode") || index(lower_command, "claude")
  }

  function print_entry(session_name, pane_id, pane_title, tab_position, tab_name, status, cwd, updated_at_ms, cwd_json) {
    if (!first_entry) {
      printf(",\n")
    }
    printf("  {\"session_name\":\"%s\",\"pane_id\":%d,\"pane_title\":\"%s\",\"tab_position\":%d,\"tab_name\":\"%s\",\"status\":\"%s\",\"cwd\":",
      json_escape(session_name), pane_id + 0, json_escape(pane_title), tab_position + 0, json_escape(tab_name), json_escape(status))
    if (cwd == "") {
      cwd_json = "null"
    } else {
      cwd_json = sprintf("\"%s\"", json_escape(cwd))
    }
    printf("%s,\"updated_at_ms\":%d}", cwd_json, updated_at_ms + 0)
    first_entry = 0
  }

  BEGIN {
    print "["
    first_entry = 1
  }

  {
    record_type = $1

    if (record_type == "session" && NF >= 2) {
      known_sessions[decode_field($2)] = 1
      next
    }

    if (record_type == "pane" && NF >= 7) {
      session_name = decode_field($2)
      pane_id = $3 + 0
      key = session_name SUBSEP pane_id
      session_has_panes[session_name] = 1
      pane_exists[key] = 1
      pane_order[++pane_count] = key
      pane_tab_position[key] = $4 + 0
      pane_tab_name[key] = decode_field($5)
      pane_title[key] = decode_field($6)
      pane_command[key] = decode_field($7)
      next
    }

    if (record_type == "tracked" && NF >= 7) {
      session_name = decode_field($2)
      pane_id = $3 + 0
      status = decode_field($4)
      agent = decode_field($5)
      cwd = decode_field($6)
      updated_at_ms = $7 + 0
      key = session_name SUBSEP pane_id

      if (!is_supported_agent(agent)) {
        next
      }

      if (!(key in tracked_updated_at_ms) || updated_at_ms > tracked_updated_at_ms[key]) {
        tracked_keys[key] = 1
        tracked_updated_at_ms[key] = updated_at_ms
        tracked_status[key] = status
        tracked_agent[key] = agent
        tracked_cwd[key] = cwd
      }
      next
    }
  }

  END {
    for (key in tracked_keys) {
      split(key, parts, SUBSEP)
      session_name = parts[1]
      pane_id = parts[2]

      if (!(session_name in known_sessions)) {
        continue
      }

      if (tracked_updated_at_ms[key] != 0 && (now_ms - tracked_updated_at_ms[key]) > max_age_ms) {
        continue
      }

      if (has_snapshot == 1 && (session_name in session_has_panes)) {
        if (!(key in pane_exists)) {
          continue
        }
      }

      seen_panes[key] = 1

      if (key in pane_exists) {
        print_entry(session_name, pane_id, pane_title[key], pane_tab_position[key], pane_tab_name[key], tracked_status[key], tracked_cwd[key], tracked_updated_at_ms[key])
      } else {
        print_entry(session_name, pane_id, agent_name(tracked_agent[key]), 0, "", tracked_status[key], tracked_cwd[key], tracked_updated_at_ms[key])
      }
    }

    for (i = 1; i <= pane_count; i++) {
      key = pane_order[i]
      if (seen_panes[key]) {
        continue
      }

      split(key, parts, SUBSEP)
      session_name = parts[1]
      pane_id = parts[2]

      if (session_name != current_session) {
        continue
      }
      if (!is_agent_pane(pane_title[key], pane_command[key])) {
        continue
      }

      print_entry(session_name, pane_id, pane_title[key], pane_tab_position[key], pane_tab_name[key], "waiting_user_input", "", 0)
    }

    if (!first_entry) {
      printf("\n")
    }
    print "]"
  }
' "$tmp_input"
