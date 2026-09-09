#!/usr/bin/env bash
# Tests for pane-session-key.sh, record-session.sh and ~/bin/clauded.
#
# Runs against a THROWAWAY tmux server on its own socket (-L psstest) and a
# FAKE claude that only records its argv, so no real agent is ever launched
# and the real store is never touched.
#
# Seams (all unset in production):
#   PANE_SESSION_TMUX   the tmux command, so tests target their own socket
#   PANE_SESSION_STORE  where per-pane session records live
#   CLAUDED_CLAUDE      the claude binary the wrapper execs
#
# The seams inject the SUBJECT, never the answer: the key is always computed
# by the real code from real tmux state, and the wrapper's decision is always
# made by the real code from a real record file.

set -u
KEYSH="${KEYSH:-/home/brian/.claude/hooks/pane-session-key.sh}"
HOOK="${HOOK:-/home/brian/.claude/hooks/record-session.sh}"
WRAP="${WRAP:-/home/brian/bin/clauded}"
SOCK=psstest
TM="tmux -L $SOCK"
pass=0; fail=0

TMPD=$(mktemp -d); STORE="$TMPD/store"; mkdir -p "$STORE"
FAKE="$TMPD/claude"; ARGV="$TMPD/argv.log"
cat > "$FAKE" <<FAKEEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ARGV"
FAKEEOF
chmod +x "$FAKE"

cleanup() { $TM kill-server 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

key_for() { PANE_SESSION_TMUX="$TM" TMUX_PANE="$1" "$KEYSH"; }
run_hook() { PANE_SESSION_TMUX="$TM" PANE_SESSION_STORE="$STORE" TMUX_PANE="$1" "$HOOK"; }
# The wrapper runs INSIDE the pane, so its cwd is the pane's cwd - that is what
# it compares the recorded cwd against. Run it from $TMPD, where the fixture
# panes live, so the comparison is the one production makes.
run_wrap() { : > "$ARGV"; ( cd "${2:-$TMPD}" && PANE_SESSION_TMUX="$TM" PANE_SESSION_STORE="$STORE" \
             CLAUDED_CLAUDE="$FAKE" TMUX_PANE="$1" "$WRAP" >/dev/null 2>&1 ); cat "$ARGV"; }

$TM kill-server 2>/dev/null
$TM new-session -d -s Alpha -n one -c "$TMPD"
$TM split-window -t Alpha:one -c "$TMPD"
$TM new-window   -t Alpha -n two -c "$TMPD"
$TM new-session -d -s Beta  -n one -c "$TMPD"
P11=$($TM list-panes -t Alpha:one -F '#{pane_id}' | sed -n 1p)
P12=$($TM list-panes -t Alpha:one -F '#{pane_id}' | sed -n 2p)
P2=$($TM  list-panes -t Alpha:two -F '#{pane_id}' | sed -n 1p)
PB=$($TM  list-panes -t Beta:one  -F '#{pane_id}' | sed -n 1p)
echo "panes: Alpha:one=[$P11 $P12] Alpha:two=[$P2] Beta:one=[$PB]"
echo

echo "-- the key identifies a PANE, not a pane id"
K11=$(key_for "$P11"); K12=$(key_for "$P12"); K2=$(key_for "$P2"); KB=$(key_for "$PB")
[ -n "$K11" ] && ok "a key is produced inside tmux" || bad "a key is produced inside tmux" nonempty ""
[ "$K11" != "$K12" ] && ok "two panes in one window differ" || bad "two panes in one window differ" "different" "$K11"
[ "$K11" != "$K2" ]  && ok "same pane index, different window differs" || bad "same pane index, different window differs" "different" "$K11"
[ "$K11" != "$KB" ]  && ok "same window name, different session differs" || bad "same window name, different session differs" "different" "$K11"
eq "the key is stable across calls" "$K11" "$(key_for "$P11")"
case "$K11" in */*|*' '*) bad "the key is safe as a filename" "no slashes or spaces" "$K11";; *) ok "the key is safe as a filename";; esac
out=$(TMUX_PANE="" "$KEYSH" 2>/dev/null; echo "rc=$?")
eq "outside tmux: empty key, exit 0" "rc=0" "$out"

echo "-- the hook records what the wrapper needs"
T1="$TMPD/t1.jsonl"; : > "$T1"
echo "{\"session_id\":\"sess-aaa\",\"transcript_path\":\"$T1\",\"cwd\":\"$TMPD\",\"hook_event_name\":\"SessionStart\"}" | run_hook "$P11"
[ -s "$STORE/$K11" ] && ok "SessionStart writes a record for this pane" || bad "SessionStart writes a record for this pane" exists missing
grep -q 'sess-aaa' "$STORE/$K11" 2>/dev/null && ok "the record holds the session id" || bad "the record holds the session id" sess-aaa "$(cat "$STORE/$K11" 2>/dev/null)"
[ ! -e "$STORE/$K12" ] && ok "a sibling pane is untouched" || bad "a sibling pane is untouched" missing exists

echo "-- the wrapper resumes, or does not, and never guesses"
eq "no record -> fresh launch" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions" "$(run_wrap "$P12")"
eq "a valid record -> resume THAT session" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --resume sess-aaa" "$(run_wrap "$P11")"

echo "-- refusing to resume is always safer than resuming the wrong thing"
rm -f "$T1"
eq "transcript gone -> fresh, not an error" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions" "$(run_wrap "$P11")"
: > "$T1"
printf 'sess-aaa\t/somewhere/else\t%s\n' "$T1" > "$STORE/$K11"
eq "recorded cwd no longer matches -> fresh (key collision guard)" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions" "$(run_wrap "$P11")"
out=$(: > "$ARGV"; PANE_SESSION_STORE="$STORE" CLAUDED_CLAUDE="$FAKE" TMUX_PANE="" "$WRAP" >/dev/null 2>&1; cat "$ARGV")
eq "outside tmux -> fresh, no crash" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions" "$out"

echo "-- the hook and the wrapper must agree on the key (they are separate programs)"
echo "{\"session_id\":\"sess-bbb\",\"transcript_path\":\"$T1\",\"cwd\":\"$TMPD\",\"hook_event_name\":\"SessionStart\"}" | run_hook "$P2"
eq "what the hook wrote, the wrapper reads back" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --resume sess-bbb" "$(run_wrap "$P2")"

echo "-- /clear mints a new id; the record must follow it"
echo "{\"session_id\":\"sess-ccc\",\"transcript_path\":\"$T1\",\"cwd\":\"$TMPD\",\"hook_event_name\":\"SessionStart\"}" | run_hook "$P2"
eq "a later SessionStart overwrites the record" \
   "--channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --resume sess-ccc" "$(run_wrap "$P2")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
