#!/bin/bash
# SessionStart hook: show in-progress kanban so every session opens grounded in actual work.
# Post v2 cutover (2026-05-04): reads from kanban.hueske.family API; auth via the
# bearer token + board id in the sibling .kanban.env (chmod 600). The Downstairs
# jeeves-kanban container is no longer the source of truth.
set -u
ENV_FILE="$(dirname "$0")/.kanban.env"
if [ ! -r "$ENV_FILE" ]; then
    echo "kanban hook: $ENV_FILE missing or unreadable"
    exit 0
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${KANBAN_BEARER:?missing in .kanban.env}" 2>/dev/null || { echo "kanban hook: KANBAN_BEARER not set"; exit 0; }
: "${KANBAN_BRIAN_BOARD_ID:?}" 2>/dev/null || { echo "kanban hook: KANBAN_BRIAN_BOARD_ID not set"; exit 0; }
: "${KANBAN_API:=https://kanban.hueske.family}"

BOARD_FILE=$(mktemp)
trap 'rm -f "$BOARD_FILE"' EXIT
if ! curl -fs --max-time 5 -H "Authorization: Bearer $KANBAN_BEARER" \
        "$KANBAN_API/api/boards/$KANBAN_BRIAN_BOARD_ID" > "$BOARD_FILE" 2>/dev/null \
   || ! [ -s "$BOARD_FILE" ]; then
    echo "kanban hook: API fetch failed ($KANBAN_API/api/boards/$KANBAN_BRIAN_BOARD_ID)"
    exit 0
fi
export BOARD_FILE
python3 <<'PYEOF'
import json, os
try:
    with open(os.environ['BOARD_FILE']) as f:
        d = json.load(f)
    ip = [c for c in d.get('cards', []) if c.get('column') == 'in-progress']
    if not ip:
        print('=== Kanban: nothing in-progress ===')
    else:
        print('=== In-Progress Kanban ===')
        # Build a lookup from category id (UUID) to category name for display
        cats = { c['id']: c.get('name') for c in d.get('categories', []) }
        for c in ip:
            sts = c.get('subtasks') or []
            done = sum(1 for s in sts if s.get('done'))
            tot = len(sts)
            cat_id = c.get('category')
            cat = cats.get(cat_id, cat_id) if cat_id else '—'
            pri = c.get('priority') or '—'
            print(f"  [{pri}] {cat}: {c['title']} ({done}/{tot})")
            undone = [s['title'] for s in sts if not s.get('done')][:2]
            for t in undone:
                print(f"      ☐ {t}")
        print()
except Exception as e:
    print(f'kanban hook parse error: {e}')
PYEOF
