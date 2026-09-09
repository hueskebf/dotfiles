#!/usr/bin/env bash
# SessionStart hook: remember which Claude session is living in this tmux pane,
# so ~/bin/clauded can resume it after the tmux server dies.
#
# Fires on every SessionStart source - startup, resume, clear, compact, fork -
# which is the point. `/clear` mints a NEW session id, and a wrapper that only
# recorded the id at launch would go on resuming a conversation you deliberately
# threw away.
#
# Writes one tab-separated line: <session_id> <cwd> <transcript_path>
# The cwd and the transcript are not decoration - they are what lets the reader
# refuse: a transcript that no longer exists, or a pane that has moved to a
# different directory, means "start fresh", never "resume something else".
#
# Never blocks; always exits 0, so a bad record can never fail a Claude turn.

set -u

[ -n "${TMUX_PANE:-}" ] || exit 0
KEY="$("${PANE_SESSION_KEY:-/home/brian/.claude/hooks/pane-session-key.sh}" 2>/dev/null)"
[ -n "$KEY" ] || exit 0

payload=""
IFS= read -r -d '' -t 1 payload || true
[ -n "$payload" ] || exit 0

field() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
sid="$(field session_id)"
tpath="$(field transcript_path)"
cwd="$(field cwd)"
[ -n "$sid" ] || exit 0

STORE="${PANE_SESSION_STORE:-$HOME/.claude/state/pane-sessions}"
mkdir -p "$STORE" 2>/dev/null || exit 0
printf '%s\t%s\t%s\n' "$sid" "$cwd" "$tpath" > "$STORE/$KEY" 2>/dev/null || true
exit 0
