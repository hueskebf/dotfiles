#!/usr/bin/env bash
# Tests for tmux-claude-state.sh
#
# Runs against a THROWAWAY tmux server on its own socket (-L cstest), so the
# real server and Brian's live panes are never touched.
#
# Seams used (all no-ops in production):
#   CLAUDE_STATE_TMUX      - the tmux command, so we can target the test socket
#   CLAUDE_STATE_PID       - the "claude" pid whose children are scanned
#   CLAUDE_STATE_AGENT_DIR - where subagent markers live
#
# The seams inject the SUBJECT, never the answer: the outstanding-work count is
# always computed by the real code against real processes and real files.

set -u
HOOK="${HOOK:-/home/brian/.claude/hooks/tmux-claude-state.sh}"
SOCK=cstest
TM="tmux -L $SOCK"
pass=0; fail=0
AGENT_DIR=$(mktemp -d)
declare -a KIDS=()

cleanup() { for k in "${KIDS[@]:-}"; do kill "$k" 2>/dev/null; done; $TM kill-server 2>/dev/null; rm -rf "$AGENT_DIR"; }
trap cleanup EXIT

ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; }
state(){ $TM show-options -p -t "$PANE" -v @claude_state 2>/dev/null; }
run()  { CLAUDE_STATE_TMUX="$TM" CLAUDE_STATE_PID="$FAKE_CLAUDE" CLAUDE_STATE_AGENT_DIR="$AGENT_DIR" \
         TMUX_PANE="$PANE" "$HOOK" "$@"; }
is()   { local want="$1" got; got="$(state)"; [ "$got" = "$want" ] && ok "$2" || bad "$2" "$want" "$got"; }

# Fixture children. NOTE: stdout/stderr MUST be redirected. A backgrounded
# child inherits the caller's stdout, so `x=$(spawn ...)` would block forever
# waiting for a pipe that the still-running child holds open.
# Sets LAST_PID rather than echoing, for the same reason.
spawn_toolcall() {
  bash -c "source /nonexistent/shell-snapshots/snapshot-bash-test.sh 2>/dev/null; while :; do sleep 1; done" >/dev/null 2>&1 &
  LAST_PID=$!; KIDS+=($LAST_PID)
}
# A child that looks like a sibling HOOK invocation - must NOT count as work.
spawn_hook() {
  bash -c "source /nonexistent/shell-snapshots/snapshot-bash-test.sh 2>/dev/null; : /home/brian/.claude/hooks/stop-reminder.sh; while :; do sleep 1; done" >/dev/null 2>&1 &
  LAST_PID=$!; KIDS+=($LAST_PID)
}

$TM kill-server 2>/dev/null
$TM new-session -d -s t
PANE=$($TM list-panes -F '#{pane_id}' | head -1)
FAKE_CLAUDE=$$          # this test shell stands in for the claude process
echo "pane=$PANE  fake-claude-pid=$FAKE_CLAUDE  agents=$AGENT_DIR"
echo

echo "-- safety: never crash, never act outside tmux"
( TMUX_PANE="" "$HOOK" working >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "no TMUX_PANE exits 0" || bad "no TMUX_PANE exits 0" 0 $?
run "" >/dev/null 2>&1; [ $? -eq 0 ] && ok "empty verb exits 0" || bad "empty verb exits 0" 0 $?

echo "-- direct states"
run working; is working "working sets working"
run blocked; is blocked "blocked sets blocked"

echo "-- CLEANUP: blocked must now overwrite done (PermissionRequest is precise)"
run done; is done "done sets done (nothing outstanding)"
run blocked
is blocked "blocked OVERWRITES done - the old refuse-to-overwrite hack is gone"

echo "-- notify: Notification is OVERLOADED, so amber is conditional"
# Claude Code fires Notification twice over: once when Claude genuinely wants
# an answer mid-turn (a question in a brainstorm - real amber), and again ~60s
# after a turn ENDS, saying "waiting for your input" - which must not repaint a
# finished pane. PermissionRequest has no such ambiguity and keeps using
# `blocked` directly; this verb is only for the overloaded event.
run working; run notify; is blocked "notify mid-turn -> amber (Claude asked you something)"
run done;    run notify; is done    "notify over done -> stays green (the ~60s idle nag)"
$TM set-option -p -t "$PANE" @claude_state waiting
run notify; is waiting "notify over waiting -> stays blue (agent is still going)"
$TM set-option -p -t "$PANE" -u @claude_state
run notify; is blocked "notify over unknown -> amber (unset is not a finished turn)"

echo "-- background shells decide done vs waiting"
run done; is done "no outstanding work -> done"
spawn_toolcall; BG=$LAST_PID; sleep 0.3
run done; is waiting "a live tool-call shell -> waiting"
kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; sleep 0.3
run done; is done "EXIT EDGE: shell gone -> back to done"

echo "-- a sibling hook process is not work"
spawn_hook; HK=$LAST_PID; sleep 0.3
run done; is done "sibling hook child is excluded"
kill "$HK" 2>/dev/null; wait "$HK" 2>/dev/null

echo "-- subagents (markers keyed on agent_id from stdin)"
echo '{"hook_event_name":"SubagentStart","agent_id":"agent-abc"}' | run subagent-start
[ -e "$AGENT_DIR/agent-abc" ] && ok "subagent-start writes a marker" || bad "subagent-start writes a marker" exists missing
run done; is waiting "a live subagent -> waiting"
echo '{"hook_event_name":"SubagentStop","agent_id":"agent-abc"}' | run subagent-stop
[ -e "$AGENT_DIR/agent-abc" ] && bad "subagent-stop clears the marker" gone exists || ok "subagent-stop clears the marker"
run done; is done "EXIT EDGE: subagent gone -> back to done"

echo "-- reset clears leaked markers"
echo '{"agent_id":"leaked-1"}' | run subagent-start
echo '{"agent_id":"leaked-2"}' | run subagent-start
run done; is waiting "leaked markers -> waiting"
run reset; is done "reset -> done"
[ -z "$(ls -A "$AGENT_DIR" 2>/dev/null)" ] && ok "reset empties the marker dir" || bad "reset empties the marker dir" empty "$(ls -A "$AGENT_DIR")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
