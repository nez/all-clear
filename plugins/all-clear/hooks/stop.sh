#!/usr/bin/env bash
# all-clear — play a sound only when the Claude Code session is fully idle.
#
# A Stop hook fires every time Claude returns control after a turn. Several
# kinds of work can leave a session "busy" past one of those Stops, and we
# suppress the sound while any is still active:
#
#   1. Debounce — never play twice within ALL_CLEAR_DEBOUNCE_SEC (default 8s).
#      Rapid bursts of Stops (e.g. several background completions arriving in
#      quick succession) collapse into a single sound.
#
#   2. Pending TaskCreate items — ~/.claude/tasks/<session_id>/<n>.json with
#      status "pending" or "in_progress".
#
#   3. Background Bash tasks (run_in_background:true) detected via /proc fd
#      links to the per-session tasks dir.
#
#   4. In-flight tool launches detected from the transcript by walking
#      tool_use records (authoritative — no substring false positives) and
#      pairing them with terminal <task-notification> blocks. Catches
#      Agent/Monitor/Bash launched in-process which leave no /proc fd.
#
#   5. Recent non-terminal <task-notification> blocks — Monitor watchers and
#      similar emit intermediate events; if one appears in the tail of the
#      transcript without a matching terminal, the watcher is still live.
#
# Configuration (env vars):
#   ALL_CLEAR_SOUND          Path to a sound file. Defaults to plugin's
#                            bundled sounds/default.mp3.
#   ALL_CLEAR_PLAYER         Command to play the sound file. Defaults: paplay
#                            (Linux), afplay (macOS), aplay (Linux fallback).
#   ALL_CLEAR_DEBOUNCE_SEC   Minimum seconds between sounds. Default 8.

set -u

input=$(cat)

extract_field() {
  printf '%s' "$input" | /usr/bin/tr -d '\n' \
    | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

session_id=$(extract_field session_id)
transcript_path=$(extract_field transcript_path)

debounce_sec=${ALL_CLEAR_DEBOUNCE_SEC:-8}
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/all-clear"
last_play_file="$state_dir/last-play"

play() {
  local sound=${ALL_CLEAR_SOUND:-}
  if [ -z "$sound" ]; then
    sound="${CLAUDE_PLUGIN_ROOT:-}/sounds/default.mp3"
  fi
  [ -f "$sound" ] || return 0

  local player=${ALL_CLEAR_PLAYER:-}
  if [ -z "$player" ]; then
    for candidate in paplay afplay aplay; do
      if command -v "$candidate" >/dev/null 2>&1; then
        player=$candidate
        break
      fi
    done
  fi
  [ -z "$player" ] && return 0

  /usr/bin/mkdir -p "$state_dir" 2>/dev/null || true
  /usr/bin/date +%s > "$last_play_file" 2>/dev/null || true

  $player "$sound" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# (1) Debounce — within $debounce_sec of the last play, stay silent.
if [ -f "$last_play_file" ]; then
  last=$(/usr/bin/cat "$last_play_file" 2>/dev/null)
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    now=$(/usr/bin/date +%s)
    if (( now - last < debounce_sec )); then
      exit 0
    fi
  fi
fi

if ! [[ "$session_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  play
  exit 0
fi

# (2) Any TaskCreate item still pending or in-progress?
tasks_dir="${HOME:-/}/.claude/tasks/${session_id}"
if [ -d "$tasks_dir" ]; then
  if /usr/bin/grep -lE \
       '"status"[[:space:]]*:[[:space:]]*"(pending|in_progress)"' \
       "$tasks_dir"/*.json >/dev/null 2>&1; then
    exit 0
  fi
fi

# (3) Any background Bash task still running (process holds fd open)?
marker="/${session_id}/tasks/"
if [ -d /proc ]; then
  for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    [ "$pid" = "$$" ] && continue
    for fd in "$proc/fd/1" "$proc/fd/2"; do
      link=$(/usr/bin/readlink "$fd" 2>/dev/null) || continue
      [ -z "$link" ] && continue
      [[ "$link" == *"$marker"* ]] || continue
      case "$link" in
        */tasks/hook_*) continue ;;
      esac
      exit 0
    done
  done
fi

# (4) Walk the transcript for in-flight tool launches and recent non-terminal
#     notifications. Authoritative source: tool_use records with
#     run_in_background:true, paired with terminal <task-notification>s.
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v python3 >/dev/null 2>&1; then
  if ! /usr/bin/python3 - "$transcript_path" <<'PYEOF'
import json, re, sys, os, time

try:
    path = sys.argv[1]
except IndexError:
    sys.exit(0)

# tool_use ids whose tool_result we still need to scan for a launch announcement
pending_results = {}     # tool_use_id -> tool_name
launched = set()         # bg task ids known to have started
terminated = set()       # bg task ids known to have finished
recent_nonterminal = []  # task ids of recent non-terminal notifications

# Recognised launch announcements — these appear in the *tool_result* text
# returned to the parent right after a background-capable tool fires.
LAUNCH_PATTERNS = [
    re.compile(r'agentId:\s*(a[a-z0-9]+)', re.IGNORECASE),
    re.compile(r'background with ID:\s*(b[a-z0-9]+)', re.IGNORECASE),
    re.compile(r'task[-_ ]id["\':\s]+([ab][a-z0-9]{6,})', re.IGNORECASE),
]
TERMINAL_STATUSES = {
    'completed', 'failed', 'cancelled', 'canceled',
    'timeout', 'killed', 'error', 'done', 'finished',
}
NOTIF_TID = re.compile(r'<task-id>\s*([ab][a-z0-9]+)\s*</task-id>')
NOTIF_ST = re.compile(r'<status>\s*([a-z_]+)\s*</status>')

def collect_launches(text):
    if not text:
        return
    for pat in LAUNCH_PATTERNS:
        for m in pat.finditer(text):
            launched.add(m.group(1))

def collect_notifs(text, recency_window):
    if not text or '<task-notification>' not in text:
        return
    for chunk in text.split('</task-notification>'):
        mid = NOTIF_TID.search(chunk)
        if not mid:
            continue
        tid = mid.group(1)
        mst = NOTIF_ST.search(chunk)
        if mst and mst.group(1).lower() in TERMINAL_STATUSES:
            terminated.add(tid)
        elif recency_window:
            # Non-terminal notification near the tail of the transcript:
            # strong signal that an emitting task (e.g. Monitor) is alive.
            recent_nonterminal.append(tid)

def text_of(content):
    """Yield text strings from a content field that may be str | list[block]."""
    if isinstance(content, str):
        yield content
    elif isinstance(content, list):
        for x in content:
            if not isinstance(x, dict):
                continue
            t = x.get('text')
            if isinstance(t, str):
                yield t

try:
    # First pass: read every line, identify tool_use blocks that ran in
    # background, then capture their corresponding tool_result text. We also
    # opportunistically scan tool_result text for launch markers so tools we
    # don't have a tool_use record for (e.g. Monitor launched in a sibling
    # session) still register.
    lines = []
    with open(path, 'r', errors='replace') as fh:
        for line in fh:
            lines.append(line)
    total = len(lines)
    # Tail window for "this monitor is still emitting events". Tight enough
    # that stale notifications from earlier in a long session don't suppress
    # the sound forever after the watcher has gone quiet.
    tail_start = max(0, total - 30)

    for idx, line in enumerate(lines):
        try:
            d = json.loads(line)
        except Exception:
            continue
        is_tail = idx >= tail_start
        msg = d.get('message')
        if isinstance(msg, dict):
            content = msg.get('content')
            if isinstance(content, list):
                for x in content:
                    if not isinstance(x, dict):
                        continue
                    t = x.get('type')
                    if t == 'tool_use':
                        inp = x.get('input') or {}
                        if isinstance(inp, dict) and inp.get('run_in_background'):
                            tuid = x.get('id')
                            if tuid:
                                pending_results[tuid] = x.get('name', '')
                        # Monitor tool always runs in background
                        if x.get('name') == 'Monitor':
                            tuid = x.get('id')
                            if tuid:
                                pending_results[tuid] = 'Monitor'
                    elif t == 'tool_result':
                        tuid = x.get('tool_use_id')
                        c = x.get('content', '')
                        for txt in text_of(c):
                            if tuid in pending_results:
                                collect_launches(txt)
                            collect_notifs(txt, recency_window=is_tail)
            elif isinstance(content, str):
                collect_notifs(content, recency_window=is_tail)
        att = d.get('attachment')
        if isinstance(att, dict):
            collect_notifs(att.get('prompt', ''), recency_window=is_tail)
        if d.get('type') == 'queue-operation':
            collect_notifs(d.get('content', ''), recency_window=is_tail)
except OSError:
    sys.exit(0)

# In-flight tasks: launched but no terminal notification yet.
in_flight = launched - terminated
# Recent non-terminal notifications whose task never terminated either.
live_emitters = {tid for tid in recent_nonterminal if tid not in terminated}

# Suppress if anything still in flight or actively emitting events.
sys.exit(1 if (in_flight or live_emitters) else 0)
PYEOF
  then
    exit 0
  fi
fi

play
exit 0
