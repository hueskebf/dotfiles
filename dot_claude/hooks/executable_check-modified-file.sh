#!/bin/bash
# PostToolUse hook: syntax-check modified files, flag state-changes without events on enterprise-tier products
# Fires after Edit/Write tool calls. Reads hook input JSON from stdin.

input=$(cat)
file=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

[ -z "$file" ] && exit 0
[ ! -f "$file" ] && exit 0

# --- Syntax check: JS/TS files ---
case "$file" in
  *.js|*.mjs|*.cjs)
    if ! node --check "$file" 2>/dev/null; then
      echo "⚠️  Syntax issue in $file (coding-standards Rule 6). Verify: node --check \"$file\""
    fi
    ;;
esac

# --- State-change without event emission: enterprise + middle tier products ---
# Applies to Applica, Aligned, Akela. Skips Mulch, Touch a Truck, Troop 39 Mulch.
# See cadre-ops/ops/product-tiering.md
case "$file" in
  */applica/*|*/aligned/*|*/akela/*)
    case "$file" in
      *.js|*.ts|*.mjs|*.cjs|*.sql)
        if grep -qiE "(UPDATE [a-zA-Z_]+ SET|INSERT INTO [a-zA-Z_]+|DELETE FROM [a-zA-Z_]+)" "$file" 2>/dev/null; then
          if ! grep -qE "emitEvent|events\.(insert|create)|event_type\s*:" "$file" 2>/dev/null; then
            echo "💭 State-change detected in $file. Is event emission present?"
            echo "   Rule: cadre-ops/ops/event-driven-architecture-principle.md"
          fi
        fi
        ;;
    esac
    ;;
esac

exit 0
