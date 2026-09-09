#!/usr/bin/env bash
# Publish this Claude session's state to its tmux pane so the status bar can
# render it. Called from settings.json hooks with one verb:
#
#   working         UserPromptSubmit, PostToolUse - mid-turn, Claude is busy
#   blocked         PermissionRequest             - Claude needs YOU, now
#   notify          Notification                  - amber, but only mid-turn
#   done            Stop                          - turn over; see below
#   reset           SessionStart                  - drop leaked markers, repaint
#   subagent-start  SubagentStart                 - marker on, reads stdin JSON
#   subagent-stop   SubagentStop                  - marker off, reads stdin JSON
#
# `done` is not taken at face value. A turn can END while work it started is
# still running - a background shell, or a subagent - and those panes look
# identical to a finished one, so you go and look at a pane that has nothing
# for you. So `done` COUNTS outstanding work and writes `waiting` instead when
# there is any. Green means the ball is in your court; waiting means the agent
# is still going and needs nothing.
#
# Outstanding work is counted from two independent sources, because neither
# sees the other:
#   1. live tool-call shells - children of the claude process whose argv holds
#      a shell-snapshot source line. Sibling HOOK invocations look identical
#      (they source the same snapshot), so anything naming ~/.claude/hooks/ is
#      excluded - otherwise this hook would forever count itself as work.
#      KNOWN LIMIT, stated not hidden: that exclusion matches the PATH TEXT
#      anywhere in argv, so a background task whose command merely MENTIONS
#      ~/.claude/hooks/ is invisible to the count and its pane will read done
#      instead of waiting. The bias is deliberate: counting a sibling hook as
#      work would strand a pane in blue forever, which is the worse failure.
#   2. subagent markers - one file per live agent_id. Subagents are NOT
#      children of the claude process, so ps cannot see them at all.
#
# Reads the pane from $TMUX_PANE, which tmux exports into every pane and every
# child inherits. No-ops silently outside tmux. Never blocks; always exits 0,
# so a tmux hiccup can never fail a Claude turn.
#
# Seams, all unset in production (see tests/test-tmux-claude-state.sh):
#   CLAUDE_STATE_TMUX       the tmux command, so tests target their own socket
#   CLAUDE_STATE_PID        the claude pid whose children are scanned
#   CLAUDE_STATE_AGENT_DIR  where subagent markers live
# They inject the SUBJECT, never the answer: the count is always computed by
# this code against real processes and real files.

set -u

verb="${1:-}"
[ -n "$verb" ]          || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

# Word-split on purpose: the seam may carry arguments ("tmux -L cstest").
read -r -a TM <<< "${CLAUDE_STATE_TMUX:-tmux}"
command -v "${TM[0]}" >/dev/null 2>&1 || exit 0

# Markers are per PANE, not per pid: pids are reused, panes are what the status
# bar draws, and SessionStart -> reset clears the pane a new session lands in.
AGENT_DIR="${CLAUDE_STATE_AGENT_DIR:-$HOME/.claude/state/tmux-subagents/${TMUX_PANE#%}}"

# The claude process whose children are the tool-call shells. Walk up from here
# rather than trusting $PPID: hooks run at the end of a chain of shells.
claude_pid() {
  local p line ppid comm
  p="${CLAUDE_STATE_PID:-}"
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    line="$(ps -o ppid=,comm= -p "$p" 2>/dev/null)" || return 0
    [ -n "$line" ] || return 0
    read -r ppid comm <<< "$line"
    [ "$comm" = "claude" ] && { printf '%s' "$p"; return 0; }
    p="$ppid"
  done
}

count_outstanding() {
  local n=0 pid cpid cargs f
  pid="$(claude_pid)"
  if [ -n "$pid" ]; then
    while read -r cpid cargs; do
      case "$cargs" in *shell-snapshots/snapshot-*) ;; *) continue ;; esac
      case "$cargs" in *"/.claude/hooks/"*) continue ;; esac
      n=$((n+1))
    done < <(ps -o pid=,args= --ppid "$pid" 2>/dev/null)
  fi
  for f in "$AGENT_DIR"/*; do
    [ -e "$f" ] && n=$((n+1))
  done
  printf '%s' "$n"
}

set_state() {
  "${TM[@]}" set-option -p -t "$TMUX_PANE" @claude_state "$1" 2>/dev/null || true
}

# done, but only if nothing this session started is still running.
settle() {
  if [ "$(count_outstanding)" -gt 0 ]; then set_state waiting; else set_state done; fi
}

# Subagent hooks are the only ones that read stdin. -t 1 so a hook fired
# without a payload can never hang a turn.
agent_id_from_stdin() {
  local payload="" id=""
  IFS= read -r -d '' -t 1 payload || true
  id="$(printf '%s' "$payload" | sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  # The id becomes a filename; keep it to characters that cannot escape the dir.
  printf '%s' "$id" | tr -cd 'A-Za-z0-9_.-'
}

case "$verb" in
  working|blocked)
    set_state "$verb"
    ;;
  notify)
    # Notification is fired for two unrelated things: Claude genuinely wants an
    # answer mid-turn (real amber - a question in a brainstorm), and an idle nag
    # ~60s AFTER a turn ends. Keyed on the CURRENT STATE rather than the
    # message text, which is undocumented and can drift: a finished pane
    # (`done`) or one whose agent is still running unattended (`waiting`) is
    # never news, so amber is refused there. Anything else is mid-turn.
    # PermissionRequest carries no such ambiguity and uses `blocked` directly.
    case "$("${TM[@]}" show-options -p -t "$TMUX_PANE" -v @claude_state 2>/dev/null)" in
      done|waiting) : ;;
      *) set_state blocked ;;
    esac
    ;;
  done)
    settle
    ;;
  reset)
    rm -f "$AGENT_DIR"/* 2>/dev/null || true
    settle
    ;;
  subagent-start)
    id="$(agent_id_from_stdin)"
    [ -n "$id" ] && { mkdir -p "$AGENT_DIR" 2>/dev/null && : > "$AGENT_DIR/$id"; }
    ;;
  subagent-stop)
    id="$(agent_id_from_stdin)"
    [ -n "$id" ] && rm -f "$AGENT_DIR/$id" 2>/dev/null
    ;;
esac

exit 0
