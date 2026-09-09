---
name: codex-review
description: Use when the user asks for a code review by Codex, requests a second-opinion review from a different model, says "have codex check/review this", or when you want diverse-model verification of a branch, commit, or uncommitted changes before merge. Invokes the local `codex review` CLI.
---

# Codex Code Review

## Overview

`codex review` is OpenAI Codex CLI's purpose-built code-review subcommand. It runs non-interactively, walks the diff, and prints findings. Useful as a second-opinion review pass — different model than Claude, fresh perspective, no shared context.

Reach for it when:
- The user explicitly says "have codex review", "second opinion from codex", "ask codex"
- A large or risky change is about to merge and you want orthogonal eyes
- Claude already reviewed and you want diverse-model corroboration

Don't reach for it when:
- A focused, in-line review by Claude is faster (small diff, clear scope)
- The user is mid-thought and hasn't asked for review
- You're trying to avoid doing your own review

## Quick Reference

| Goal | Command (run from inside the repo) |
|---|---|
| Review the current branch vs `main` | `codex review --base main` |
| Review against a different base | `codex review --base <branch>` |
| Review one commit | `codex review --commit <sha>` |
| Review staged + unstaged + untracked | `codex review --uncommitted` |
| Add a title to the review summary | `codex review --base main --title "Phase 1 foundation"` |

`codex review` runs from the **current working directory** — there is no `--cd` flag on this subcommand. `cd` into the right repo first (or run from a worktree).

## Canonical Invocation

```bash
# In the worktree at /home/brian/docker/kanban-v2-phase1, branch feature/v2-phase-1
cd /home/brian/docker/kanban-v2-phase1
codex review --base main --title "Phase 1: SQLite migration + cutover" \
  2>&1 | tee /tmp/codex-review-$(date +%s).log
```

Tee to a log file so the output is captured even if the user's terminal scrollback truncates. Show the user the log path along with the findings summary.

## Reporting Back to the User

Codex's review output is markdown-flavored prose with severity-tagged findings. After it finishes:

1. Skim the output for **Critical** / **Important** / **Minor** sections (or whatever Codex emitted).
2. Summarize the top 3–5 findings in your reply with file/line references — don't paste the entire log.
3. Flag any finding that contradicts Claude's own prior review explicitly; the user benefits from seeing the disagreement.
4. Offer to act on findings (e.g., "want me to fix the Important issues?").

## Common Mistakes

| Mistake | Fix |
|---|---|
| Running from the wrong directory | `cd <repo>` first; `codex review` has no `-C/--cd` flag (unlike `codex exec`) |
| Forgetting `--base` on a feature branch | Without it, Codex picks a default and may review the wrong span |
| Pasting the full Codex log into chat | Summarize. Save the log file path and reference it. |
| Running review on a merge commit's repo HEAD | Use `--commit <sha>` to scope to a single commit instead |

## When NOT to Use

- The user is venting / brainstorming, not asking for review
- The diff is tiny (< 50 lines) and Claude can review it directly faster
- Codex was just invoked moments ago; don't loop-review

## Auth Note

`codex login status` reports the active auth method (typically ChatGPT or API key). If it errors, the skill can't proceed — surface the error and stop.
