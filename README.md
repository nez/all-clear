# all-clear

A Claude Code plugin that plays a sound when the session becomes **fully idle** — suppressed while background tasks in the same session are still running.

## Why

Claude Code fires the `Stop` hook every time the main agent stops responding. When you launch a background bash task (`run_in_background: true`), the turn ends with the task still running, and Stop fires. When the task finishes, Claude wakes, responds, and Stop fires again. A standard "ding on Stop" hook gives you a noise for each of those — one per intermediate stop.

`all-clear` gates the sound: it only plays on the Stop where no background tasks in the same session are still active. One sound per truly-idle moment, per window.

## How it works

Linux-only, per-session attribution via `/proc`:

- Claude Code redirects every background task's stdout/stderr to `/tmp/claude-<uid>/<cwd>/<session_id>/tasks/<task-id>.output`.
- Hook stdout captures live in the same dir but named `hook_<pid>.output`.
- The hook reads `session_id` from the Stop payload on stdin, scans `/proc/*/fd/{1,2}`, and if any process is writing to a non-`hook_` file in this session's `tasks/` dir, it stays silent. Otherwise it plays the configured sound.

No heuristics, no debouncing. The signal is the presence of a live writer.

## Install

```
/plugin marketplace add nez/all-clear
/plugin install all-clear@all-clear
```

Then set the sound file (and optionally the player) in your environment:

```sh
export ALL_CLEAR_SOUND=$HOME/path/to/your-sound.mp3
# Optional: override the auto-detected player
# export ALL_CLEAR_PLAYER=paplay
```

If `ALL_CLEAR_SOUND` is unset or missing, the plugin is silent — i.e. a no-op until you opt in.

## Configuration

| Env var | Default | Description |
| :--- | :--- | :--- |
| `ALL_CLEAR_SOUND` | (unset) | Path to the sound file. Plugin is silent until set. |
| `ALL_CLEAR_PLAYER` | auto-detect | Command to play the file. Auto-detects `paplay`, `afplay`, `aplay`. |

## Requirements

- Linux with procfs (`/proc`). The detection logic reads `/proc/<pid>/fd/*`.
- A sound player on `PATH` (`paplay` / `afplay` / `aplay`) — or set `ALL_CLEAR_PLAYER`.

macOS is likely to work if `/proc` is available (it usually isn't) or if Claude Code uses a similar `/tmp/claude-<uid>/` layout. Not tested.

## Caveats

- **Long-running dev servers** launched with `run_in_background: true` (a `vite` server, say) keep the originating session silent as long as they're alive. Kill the server when you're done if you want the sound back.
- **Session scope is exact**: if you have three Claude Code windows open, each one decides independently based on its own `session_id`. No cross-session interference.
- **Final-Stop dependency**: the sound only plays when Claude actually produces a reply after the last background task finishes. If the session is killed before that reply, no sound.

## License

MIT
