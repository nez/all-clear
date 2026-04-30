#!/usr/bin/env bash
# all-clear — play a sound only when the Claude Code session is fully idle.
#
# A Stop hook fires every time Claude returns control after a turn. Three kinds
# of work can leave a session "busy" past one of those Stops, and we suppress
# the sound while any is still active:
#
#   1. Pending TaskCreate items — ~/.claude/tasks/<session_id>/<n>.json with
#      status "pending" or "in_progress". Set when the parent explicitly
#      tracks work as tasks.
#
#   2. Background Bash tasks (run_in_background:true) — regular .output files
#      under /tmp/claude-<uid>/<cwd>/<session_id>/tasks/ with the spawned
#      shell's fd 1 or 2 still pointing at them. Hook stdout captures live in
#      the same dir as hook_<pid>.output, which we ignore.
#
#   3. In-flight background tasks (Agent and Bash run_in_background:true)
#      detected from the parent transcript: every launch emits an
#      "agentId: a<id>" or "Command running in background with ID: b<id>"
#      tool_result, and every terminal exit emits a <task-notification> with
#      <status>completed|failed|cancelled|timeout</status>. If launched IDs
#      lack a terminal notification, the task is still in flight. This
#      catches background Agents, which run in-process and have no /proc fd.
#
# Configuration (env vars):
#   ALL_CLEAR_SOUND   Path to a sound file. Defaults to plugin's bundled
#                     sounds/default.mp3.
#   ALL_CLEAR_PLAYER  Command to play the sound file. Defaults: paplay
#                     (Linux), afplay (macOS), aplay (Linux fallback).

set -u

input=$(cat)

extract_field() {
  printf '%s' "$input" | /usr/bin/tr -d '\n' \
    | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

session_id=$(extract_field session_id)
transcript_path=$(extract_field transcript_path)

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

  $player "$sound" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

if ! [[ "$session_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  play
  exit 0
fi

# (1) Any TaskCreate item still pending or in-progress?
tasks_dir="${HOME:-/}/.claude/tasks/${session_id}"
if [ -d "$tasks_dir" ]; then
  if /usr/bin/grep -lE \
       '"status"[[:space:]]*:[[:space:]]*"(pending|in_progress)"' \
       "$tasks_dir"/*.json >/dev/null 2>&1; then
    exit 0
  fi
fi

# (2) Any background Bash task still running (process holds fd open)?
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

# (3) Any background task launched but not yet terminated (per transcript)?
# Background Agents run in-process and produce no /proc fd, so this is the
# only signal that catches them. Also covers Bash run_in_background tasks
# whose process exited but whose terminal notification is the trigger for
# this very Stop — in which case launches and notifications match and we
# fall through.
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v python3 >/dev/null 2>&1; then
  if ! /usr/bin/python3 - "$transcript_path" <<'PYEOF'
import json, re, sys

try:
    path = sys.argv[1]
except IndexError:
    sys.exit(0)

LAUNCH_RE = re.compile(
    r'(?:agentId:\s*(a[a-f0-9]+)'
    r'|Command running in background with ID:\s*(b[a-z0-9]+))'
)
TERMINAL_STATUSES = {'completed', 'failed', 'cancelled', 'canceled', 'timeout', 'killed', 'error'}
NOTIF_TASK_ID = re.compile(r'<task-id>([ab][a-z0-9]+)</task-id>')
NOTIF_STATUS = re.compile(r'<status>([a-z_]+)</status>')

launched = set()
terminated = set()

def scan_text(text):
    if not text:
        return
    for m in LAUNCH_RE.finditer(text):
        tid = m.group(1) or m.group(2)
        if tid:
            launched.add(tid)
    if '<task-notification>' in text:
        # A single line can contain multiple <task-notification> blocks.
        # Walk them via splits on the closing tag.
        for chunk in text.split('</task-notification>'):
            mid = NOTIF_TASK_ID.search(chunk)
            mst = NOTIF_STATUS.search(chunk)
            if mid and mst and mst.group(1) in TERMINAL_STATUSES:
                terminated.add(mid.group(1))

try:
    with open(path, 'r', errors='replace') as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            msg = d.get('message')
            if isinstance(msg, dict):
                content = msg.get('content')
                if isinstance(content, list):
                    for x in content:
                        if isinstance(x, dict) and x.get('type') == 'tool_result':
                            c = x.get('content', '')
                            if isinstance(c, list):
                                for y in c:
                                    if isinstance(y, dict) and y.get('type') == 'text':
                                        scan_text(y.get('text', ''))
                            elif isinstance(c, str):
                                scan_text(c)
                elif isinstance(content, str):
                    scan_text(content)
            att = d.get('attachment')
            if isinstance(att, dict):
                scan_text(att.get('prompt', ''))
            if d.get('type') == 'queue-operation':
                scan_text(d.get('content', ''))
except OSError:
    sys.exit(0)

# Exit 1 if any launched task lacks a terminal notification (= still running).
sys.exit(1 if launched - terminated else 0)
PYEOF
  then
    exit 0
  fi
fi

play
exit 0
