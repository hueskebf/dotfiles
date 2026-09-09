#!/usr/bin/env bash
# Print a stable, filename-safe key identifying the tmux pane we are running
# in, or nothing at all when we are not in tmux.
#
# This is the ONE definition of "which pane is this", shared by
# record-session.sh (which writes a pane's session id) and ~/bin/clauded
# (which reads it back). They are separate programs run at different times;
# if each computed the key its own way the two would drift and a pane would
# silently stop resuming. One fact, one home.
#
# The key is deliberately NOT the pane id (%6): tmux reassigns pane ids when
# the server restarts, which is precisely the moment this has to work. What
# tmux-resurrect does restore is the session name, the window name and the
# pane index, so the key is built from those three.
#
# Collisions are possible - two windows with the same name in one session -
# so the caller ALSO checks the recorded cwd before resuming anything. A
# missed resume is a shrug; resuming the wrong conversation is not.

set -u

[ -n "${TMUX_PANE:-}" ] || exit 0
read -r -a TM <<< "${PANE_SESSION_TMUX:-tmux}"
command -v "${TM[0]}" >/dev/null 2>&1 || exit 0

raw="$("${TM[@]}" display-message -p -t "$TMUX_PANE" \
       '#{session_name}|#{window_name}|#{pane_index}' 2>/dev/null)" || exit 0
[ -n "$raw" ] || exit 0

IFS='|' read -r sess win idx <<< "$raw"
san() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_.-' '_'; }
printf '%s--%s--%s' "$(san "$sess")" "$(san "$win")" "$(san "$idx")"
exit 0
