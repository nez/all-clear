#!/usr/bin/env bash
# all-clear — play a sound only when the Claude Code session is fully idle.
#
# When Claude Code launches a background task (Bash with run_in_background:true),
# the turn ends while the task is still running and the Stop hook fires. When
# the task finishes, Claude wakes up, responds, and Stop fires again. Without
# gating, a notification sound plays for each of those Stops. This hook plays
# the sound only on the *final* Stop — the one where no background tasks in
# this session are still active.
#
# Per-session attribution (Linux):
#   Claude Code redirects background Bash task stdout/stderr to
#     /tmp/claude-<uid>/<cwd-encoded>/<session_id>/tasks/<task-id>.output
#   Hook stdout captures live in the same dir as `hook_<pid>.output`.
#   Any process with fd/1 or fd/2 pointing at a non-hook_ output file in this
#   session's tasks/ dir is a live background task.
#
# Configuration (env vars):
#   ALL_CLEAR_SOUND   Path to a sound file. Defaults to the plugin's bundled
#                     sounds/default.mp3.
#   ALL_CLEAR_PLAYER  Command to play the sound file. Defaults: paplay (Linux),
#                     afplay (macOS), aplay (Linux fallback).

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
