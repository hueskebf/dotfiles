---
name: delegating-to-codex
description: Use when the user asks Codex to do something specific ("have codex do X", "ask codex to verify", "run that through codex"), wants diverse-model verification of a result, or when delegating an isolated task to a separate agent process is appropriate. Invokes `codex exec` non-interactively from the shell.
---

# Delegating to Codex

## Overview

`codex exec` runs an OpenAI Codex CLI session non-interactively — give it a prompt, optionally bound to a working directory, and it returns the agent's final message. Useful as a second-agent surface for diverse-model verification, alternative-implementation attempts, or when the user explicitly asks Codex to do something.

This is a *peer-agent* delegation, not a tool call. Codex runs in its own process, with its own model, sandbox, and permissions. Treat its output as advisory unless the user told you to apply it.

## When to Use

- User explicitly says "have codex…", "use codex to…", "ask codex…"
- You want orthogonal verification of a result Claude produced (different model = different blind spots)
- You want to attempt the same task two ways and compare
- A long-running task could run in parallel — though prefer Claude's own background-mode tools when possible

## When NOT to Use

- The task is well within Claude's competence and there's no diversity benefit
- The user wants Claude to do it, not delegate
- You're trying to skip work — Codex isn't a way to escape doing your own job
- The task requires conversation context Claude has and Codex doesn't

## Quick Reference

| Flag | Purpose |
|---|---|
| `-C, --cd <DIR>` | Working directory for Codex's tools (essential for repo work) |
| `-s, --sandbox <MODE>` | `read-only`, `workspace-write`, or `danger-full-access` |
| `-m, --model <MODEL>` | Override default model (e.g., `gpt-5.1`) |
| `-o, --output-last-message <FILE>` | Capture final response to a file (recommended) |
| `--json` | Stream events as JSONL on stdout |
| `--ephemeral` | No session persistence to disk |
| `--skip-git-repo-check` | Run outside a git repo |
| `--dangerously-bypass-approvals-and-sandbox` | Don't, unless user explicitly asks |

## Canonical Invocation

```bash
OUT=/tmp/codex-out-$(date +%s).md
codex exec \
  -C /home/brian/docker/kanban-v2-phase1 \
  -s read-only \
  -o "$OUT" \
  "Read src/auth.js and report any places where bcrypt cost factor is below 12. Output: file:line + the literal cost value. Be terse." \
  >/dev/null 2>&1
cat "$OUT"
```

Then read the captured file with the `Read` tool, summarize for the user, and offer next actions.

### Sandbox mode selection

| Task type | Sandbox |
|---|---|
| Pure read/analysis (review, audit, lookup) | `read-only` (default-safe) |
| Local code edits inside a worktree | `workspace-write` |
| Anything destructive or affecting shared systems | Don't delegate — do it yourself, asking the user to confirm |

`danger-full-access` is for deliberately externally-sandboxed environments. On Brian's machine, prefer `workspace-write` and let Codex prompt for things outside its workspace.

## Prompt Construction

Codex doesn't see the conversation Claude is having. Write self-contained prompts:

- State the goal in one sentence
- Name the file paths or symbols Codex should look at
- Specify the output format you want back ("file:line list", "JSON of findings", "max 200 words")
- Don't reference "this conversation" or "what we just discussed"

A bad prompt: *"Verify the work we did is correct."*
A good prompt: *"Read src/queries/cards.js and src/routes/cards.js. Verify that every public route handler uses one of the query functions exported from src/queries/cards.js — i.e., no inline SQL in the route file. Output a yes/no plus a list of any inline SQL with file:line."*

## Reporting Back to the User

1. Surface Codex's conclusion in 1–3 sentences
2. Reference the captured output file path so the user can read the full transcript
3. Flag any disagreement with Claude's prior conclusion explicitly
4. Offer next actions

## Common Mistakes

| Mistake | Fix |
|---|---|
| Forgetting `-C` and Codex runs from your cwd | Always pass `-C <repo>` for repo work |
| Skipping `-o <file>` and parsing stdout | Use `-o`; stdout has progress noise |
| Vague prompts that assume context | Make every prompt self-contained |
| Using `workspace-write` when read suffices | Default to `read-only`; escalate only when needed |
| Running Codex when Claude could just answer | Don't delegate gratuitously — slow + extra cost |

## Auth Note

`codex login status` reports the active auth method. If it fails, surface the error and stop — there's no way to delegate without auth.
