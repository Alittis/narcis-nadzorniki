# CLAUDE.md — Terenska beležnica

`project/` is canonical. Read it before analysis or edits:

- `project/ARCHITECTURE.md`
- `project/DEPLOYMENT.md`
- `project/OPERATIONS.md`
- `project/STATE.json`
- `project/BACKLOG.md`

Those files are the source of truth for architecture, deployment, operations,
runtime assumptions and open work — ahead of anything inferred from the code.

Also in `project/`: `PLAY_CLOSED_TEST.md` — read what the task touches.

## Backlog

`project/BACKLOG.md` is the single source of truth for feedback, bugs and tasks.
Item id prefix `TB-`, repo-scoped, never reused. Types: 🐞 Bug · ✨ Enhancement ·
❓ Needs discussion · 🔧 Chore. Priority P1 (soon) · P2 (planned) · P3
(nice-to-have). Status: Triage → Todo → Doing → Blocked → Done, kept current in the
same task that changes it.

Start the implementing commit's subject with the item id (`TB-12: …`). That link is
the only thing tying the backlog to git history. Keep Done items for traceability.

## Keep the docs current

A change that touches architecture, deployment, operations, dependencies, runtime
behaviour, env vars, ports, process model, rollback or risk profile updates the
matching `project/` file in the same commit. `STATE.json` stays machine-readable and
consistent with the markdown.
Mark what you cannot confirm as `STATUS: UNKNOWN – REQUIRES CONFIRMATION` rather
than guessing. No speculative infrastructure, services or commands.

## Secrets and local-only files

Never hand-edit `.env*` files, and never take a secret value through chat. A secret
reaches an env file only through an interactive prompt script — convention
`deploy/scripts/setup-<service>-env.sh` — that reads with `read -rs`, refuses a
target that is not gitignored, `chmod 600`s it, and is re-runnable.

`/misc/` is gitignored, local-only scratch: never commit its contents, never quote
them outward.

## Releases are local-only

Release builds (AAB/IPA), signing and store uploads need the local macOS toolchain —
Flutter, Xcode, the keystore — and cannot run in a cloud session. Code, tests and docs
here are portable; the release procedure is not.

## Working style

The smallest change that solves the problem. Touch only what the request requires,
match the surrounding style, and do not refactor what is not broken — if you spot
unrelated dead code, say so rather than deleting it. Check an external library's API
against the installed version and its current docs rather than from memory. State
assumptions; ask when two readings of the request would produce materially
different work.
