#!/bin/bash
# Stop hook: end-of-session checklist, only when code was modified
# Reads hook input from stdin. Silent if no Edit/Write/MultiEdit occurred.

input=$(cat)
transcript=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

[ -z "$transcript" ] && exit 0
[ ! -f "$transcript" ] && exit 0

# Only fire if there were Edit/Write/MultiEdit operations in this session
if ! grep -qE '"name":"(Edit|Write|MultiEdit)"' "$transcript" 2>/dev/null; then
  exit 0
fi

cat <<'EOF'
─── Session-end checks (code was modified) ───
☐ Tests added for new features? (coding-standards Rule 7 + 25, testing-standards.md)
☐ Events emitted for state changes? (enterprise/middle tier)
☐ Kanban subtasks updated?
☐ Pattern library updated if new reusable patterns emerged?

Product tiers: Applica/Aligned=enterprise, Akela=middle, Mulch/TaT=local-tool
See: /home/brian/docker/cadre-ops/ops/product-tiering.md
EOF

exit 0
