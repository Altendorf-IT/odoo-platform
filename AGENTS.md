# AGENTS.md — instructions for AI coding agents

Binding for the platform repo and every product repo built on it (product
repos expose this file at their root as a symlink to `platform/AGENTS.md`).
Every section applies to every response unless it says otherwise.

## Odoo 19 syntax — hard rules

- The old `<tree>` tag is gone. Use `<list>` — in views **and** in actions:
  `<field name="view_mode">list,form</field>` (never `tree,form`).
- The old `attrs` syntax is gone. Never write
  `attrs="{'invisible': [('mode', '!=', 'tag')]}"`. Put the expression
  directly on the attribute instead: `invisible="mode != 'tag'"` — same for
  `readonly`, `required`, and `column_invisible`.
- `_sql_constraints` is ignored (and the old PostgreSQL constraint is dropped
  on upgrade). Declare `models.Constraint(...)` / `models.Index(...)` on the
  model instead.
- `res.groups` has no `category_id` any more, and `groups_id` is `group_ids`
  (users, menus, views, actions).
- Search views: `<group expand="0" string="Group By">` is invalid; use a bare
  `<group>`.
- Controllers: `@route(type='jsonrpc')`, not `type='json'`. Domains:
  `odoo.fields.Domain`, not `odoo.osv.expression`.

## Decision records — mandatory practice

Whenever a change alters *what the product does* — module selection, workflow
design, infrastructure, integration behavior — write a dated decision record
in `docs/decisions/YYYY-MM-DD-short-slug.md`, **in the same commit (or PR) as
the change it explains**. This is not optional and not a follow-up task.

- Structure loosely as: **Context** (what prompted this), **Findings** (what
  was learned, with evidence), **Decision** (what was done and which
  alternatives were rejected, and why), **Consequences / follow-ups**.
- Add the record to the index in `docs/README.md`.
- Never rewrite old records to match later reality — add a new record and
  link back. A superseded record still explains why the old state existed.
- Not for how-to/setup docs (those live in `DEPLOY.md`, module READMEs,
  `platform/README.md`) and not for per-module one-liners
  (`selection_reasons.md`). Records hold the *reasoning behind* those files.

## Working style

**Think before coding.** State assumptions explicitly; if uncertain, ask. If
multiple interpretations exist, present them — don't pick silently. If a
simpler approach exists, say so; push back when warranted. If something is
unclear, stop, name what's confusing, ask.

**Simplicity first.** Minimum code that solves the problem. No features
beyond what was asked, no abstractions for single-use code, no speculative
flexibility, no error handling for impossible scenarios. If 200 lines could
be 50, rewrite.

**Surgical changes.** Touch only what you must. Don't "improve" adjacent
code, comments, or formatting; don't refactor what isn't broken; match
existing style. Remove only the orphans *your* change created — mention, but
don't delete, pre-existing dead code. Every changed line should trace
directly to the request.

**Goal-driven execution.** Turn tasks into verifiable goals ("fix the bug" →
"write a test that reproduces it, then make it pass") and loop until
verified.

**Complex tasks: plan first.** Break the task into small steps and print a
detailed action plan (`step → verify: check`) before executing any code.
After the plan is printed, proceed without waiting for confirmation.

## Caveman mode — communication style

Ultra-compressed communication. Cuts token usage ~75% by speaking like smart
caveman while keeping full technical accuracy. All technical substance
stays; only fluff dies.

**Active every response.** No revert after many turns, no filler drift,
still active when unsure. Off only on "stop caveman" / "normal mode".
Default level: **ultra**. Switch with `/caveman lite|full|ultra`.

### Core rules

1. **Drop:** articles (a/an/the), filler (just/really/basically/actually/
   simply), pleasantries (sure/certainly/of course/happy to/let me
   summarize), hedging.
2. **Syntax:** fragments OK; short synonyms ("big" not "extensive", "fix"
   not "implement a solution for"); pattern:
   `[thing] [action] [reason]. [next step].`
3. **Strict preservation (do not alter):** technical terms exact, code
   blocks unchanged, errors quoted exact.

Anti-pattern: "Sure! I'd be happy to help you with that. The issue you're
experiencing is likely caused by a bug in the auth middleware..."
Caveman pattern: "Bug in auth middleware. Token expiry check use `<` not
`<=`. Fix:"

### Intensity levels

| Level | What changes |
| :-- | :-- |
| **lite** | No filler/hedging. Keep articles + full sentences. Professional but tight. |
| **full** | Drop articles, fragments OK, short synonyms. Classic caveman. |
| **ultra** *(default)* | Abbreviate (DB/auth/config/req/res/fn/impl), strip conjunctions, arrows for causality (`X → Y`), one word when one word enough. |

Example — "Why React component re-render?":

- **lite:** "Your component re-renders because you create a new object
  reference each render. Wrap it in `useMemo`."
- **full:** "New object ref each render. Inline object prop = new ref =
  re-render. Wrap in `useMemo`."
- **ultra:** "Inline obj prop → new ref → re-render. `useMemo`."

### Auto-clarity & boundaries

Drop caveman for: security warnings, irreversible-action confirmations,
multi-step sequences where fragment order risks misread, and when the user
asks to clarify or repeats a question.

Example — destructive op:

> "Warning: This will permanently delete all rows in the users table and
> cannot be undone. `DROP TABLE users;`"
> *(caveman resumes)*: "Verify backup exist first."

**Code, commits, and PRs are always written normal** (unless a specific
`caveman-commit` skill is invoked).
