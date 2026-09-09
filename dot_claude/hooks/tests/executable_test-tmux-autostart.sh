#!/usr/bin/env bash
# Tests for ~/bin/tmux-autostart.
#
# This runs on EVERY interactive terminal, so a mistake here is met constantly.
# Every skip condition is asserted, and the happy path is asserted to issue
# exactly the tmux commands expected - against a FAKE tmux that models sessions,
# so no server is ever started.
#
# NOTE: `tmux start-server` cannot be used to hold a server open while continuum
# restores - a server with no sessions exits immediately (measured). So the
# script creates a PLACEHOLDER session, waits for the restore to bring back real
# ones, kills the placeholder, and attaches. These tests pin that sequence.
#
# Seams (all unset in production):
#   TMUX_AUTOSTART_TMUX      the tmux command
#   TMUX_AUTOSTART_SAVEFILE  the resurrect 'last' marker it looks for
#   TMUX_AUTOSTART_WAIT      seconds to wait for a restore to produce a session

set -u
SUT="${SUT:-/home/brian/bin/tmux-autostart}"
PH="_autostart_boot"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
FAKE="$TMPD/tmux"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
# A fake tmux that models a session list, so the script's real decisions are
# exercised. Never starts anything.
S="$FAKE_STATE"; SESS="$S/sessions"
printf '%s\n' "$*" >> "$S/calls.log"
touch "$SESS"
case "$1" in
  has-session)  [ -s "$SESS" ] && exit 0 || exit 1 ;;
  new-session)  echo "${!#}" >> "$SESS"; touch "$S/created"; exit 0 ;;
  kill-session) t="$3"; grep -vxF "$t" "$SESS" > "$SESS.tmp" 2>/dev/null; mv "$SESS.tmp" "$SESS"
                printf '%s\n' "$t" >> "$S/killed"; exit 0 ;;
  list-sessions)
      # simulate the restore landing after N polls
      if [ -f "$S/restore-after" ]; then
        n=$(cat "$S/restore-after"); n=$((n-1)); echo "$n" > "$S/restore-after"
        [ "$n" -le 0 ] && ! grep -qxF Restored "$SESS" && echo Restored >> "$SESS"
      fi
      cat "$SESS"; [ -s "$SESS" ] && exit 0 || exit 1 ;;
  attach)       touch "$S/attached"; printf '%s\n' "${3:-}" > "$S/attached-to"; exit 0 ;;
esac
exit 0
FAKEEOF
chmod +x "$FAKE"

setup() { S="$TMPD/case-$1"; mkdir -p "$S"; : > "$S/calls.log"; : > "$S/sessions"; }
verbs()    { awk '{print $1}' "$S/calls.log" | tr '\n' ' ' | sed 's/ $//'; }
attached() { [ -e "$S/attached" ] && echo yes || echo no; }
created()  { [ -e "$S/created" ]  && echo yes || echo no; }
killed()   { tr '\n' ' ' < "$S/killed" 2>/dev/null | sed 's/ $//'; }
sessions() { tr '\n' ' ' < "$S/sessions" 2>/dev/null | sed 's/ $//'; }
run() { FAKE_STATE="$S" TMUX_AUTOSTART_TMUX="$FAKE" TMUX_AUTOSTART_WAIT=1 \
        TMUX_AUTOSTART_SAVEFILE="$S/last" "$@" "$SUT" >/dev/null 2>&1; echo "rc=$?"; }

echo "-- it must never break a shell, and never nest"
setup nest;   touch "$S/last"; run env TMUX=/tmp/x,1,0 >/dev/null
eq "already inside tmux: does nothing" "" "$(verbs)"
setup notmux; touch "$S/last"; run env -u TMUX NO_TMUX=1 >/dev/null
eq "NO_TMUX escape hatch: does nothing" "" "$(verbs)"
setup vscode; touch "$S/last"; run env -u TMUX TERM_PROGRAM=vscode >/dev/null
eq "vscode integrated terminal: does nothing" "" "$(verbs)"
setup missing; touch "$S/last"
out=$(FAKE_STATE="$S" TMUX_AUTOSTART_TMUX="$TMPD/no-such-tmux" TMUX_AUTOSTART_SAVEFILE="$S/last" \
      env -u TMUX "$SUT" >/dev/null 2>&1; echo "rc=$?")
eq "tmux not installed: exits 0, no crash" "rc=0" "$out"
setup rc; touch "$S/last"; echo Existing > "$S/sessions"
eq "always exits 0" "rc=0" "$(run env -u TMUX)"

echo "-- only the FIRST terminal attaches"
setup second; touch "$S/last"; echo Existing > "$S/sessions"; run env -u TMUX >/dev/null
eq "a server already exists: creates nothing" "no" "$(created)"
eq "a server already exists: does not attach" "no" "$(attached)"
eq "and it asked exactly once" "has-session" "$(verbs)"

echo "-- first terminal: placeholder holds the server open while the restore lands"
setup first; touch "$S/last"; echo 3 > "$S/restore-after"; run env -u TMUX >/dev/null
eq "creates a placeholder session" "yes" "$(created)"
eq "attaches once the restore lands" "yes" "$(attached)"
eq "kills the placeholder before attaching" "$PH" "$(killed)"
eq "leaves only the restored session behind" "Restored" "$(sessions)"
case "$(verbs)" in
  "has-session new-session"*kill-session\ attach) ok "order: check, create, poll, kill, attach" ;;
  *) bad "order: check, create, poll, kill, attach" "has-session new-session ... kill-session attach" "$(verbs)" ;;
esac

echo "-- if nothing is restored, leave no trace"
setup empty; touch "$S/last"; run env -u TMUX >/dev/null
eq "placeholder was created" "yes" "$(created)"
eq "nothing restored: does NOT attach" "no" "$(attached)"
eq "nothing restored: placeholder is cleaned up" "$PH" "$(killed)"
eq "no sessions left behind" "" "$(sessions)"

echo "-- no save file means nothing to restore: do not pause, do not create"
setup nosave; run env -u TMUX >/dev/null
eq "no resurrect save: only the server check" "has-session" "$(verbs)"
eq "no resurrect save: creates nothing" "no" "$(created)"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
