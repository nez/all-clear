#!/usr/bin/env bash
# all-clear — play a sound only when the Claude Code session is fully idle.
#
# A Stop hook fires every time Claude returns control after a turn. Two kinds
# of work can leave a session "busy" past one of those Stops, and we suppress
# the sound while either is still active:
#
#   1. Pending TaskCreate items — ~/.claude/tasks/<session_id>/<n>.json with
#      status "pending" or "in_progress". When the parent dispatches work as
#      tracked tasks (e.g. background Agent subagents), it updates each task
#      as that subagent returns and stops in between, so Stop fires once per
#      completion. The user wants the sound only on the final completion.
#
#   2. Background Bash tasks (run_in_background:true) — regular .output files
#      under /tmp/claude-<uid>/<cwd>/<session_id>/tasks/ with the spawned
#      shell's fd 1 or 2 still pointing at them. Hook stdout captures live in
#      the same dir as hook_<pid>.output, which we ignore.
#
# Configuration (env vars):
#   ALL_CLEAR_SOUND   Path to a sound file. Defaults to plugin's bundled
#                     sounds/default.mp3.
#   ALL_CLEAR_PLAYER  Command to play the sound file. Defaults: paplay
#                     (Linux), afplay (macOS), aplay (Linux fallback).

set -u

input=$(cat)

session_id=$(printf '%s' "$input" | /usr/bin/tr -d '\n' \
  | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

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

# (2) Any background Bash task still running?
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

play
exit 0
