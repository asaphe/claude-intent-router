# claude-intent-router

UserPromptSubmit hook that detects high-confidence short-phrase intents and
injects skill-routing or rigor-checklist context. Configurable, works with
generic fallback text out of the box.

## Install

```
/plugin marketplace add asaphe/claude-intent-router
/plugin install intent-router@claude-intent-router
```

## Usage

Detects short-phrase intents — "status?", "merged", "check for comments",
"ship it", "pause" — and injects skill-routing or rigor-checklist context so
the assistant doesn't have to re-derive intent every time. High precision by
design: patterns require the prompt to be short (≤400 chars) and match a
well-known trigger; the hook never invokes a skill itself, only injects
context, so the assistant still decides.

Most intents are whole-prompt anchored, because a substring match on a phrase
like "merge it" would fire on "dont merge it yet". Workflow verbs that
habitually arrive as a trailing clause — "fix everything **then finalize**",
"wait for CI, **resolve comments**, finalize" — are matched as substrings
instead, guarded by a negative pattern so non-PR senses ("finalize the naming
convention") still don't fire.

Every intent's injected text is generic by default and works with zero
setup. Copy `examples/intent-router.config.example.json` to
`~/.claude/intent-router.config.json` and fill in whichever fields apply
(leave the rest as empty strings — a field left empty, including an unedited
copy of the example file, is read as "not configured" and falls back to
generic text; there is no placeholder value that could be mistaken for a
real one).

| Field | Meaning |
| --- | --- |
| `ticket_system` | Name of your ticket tracker, e.g. `Jira`, `Linear`, `GitHub Issues` |
| `ticket_id_pattern` | Your ticket-ID format, e.g. `PROJ-1234` |
| `tracker_path` | Path to your personal task-scratch file, if you keep one |
| `watch_bot_pattern` | Name of your PR review bot, e.g. `codecov\|renovate` |
| `pr_check_skill` | Name of your PR-comment-sweep skill, if you have one |
| `pr_review_skill` | Name of your PR-review skill, if you have one |
| `pr_finalize_skill` | Name of your pre-merge-check skill, if you have one |
| `pr_resolver_skill` | Name of your PR-comment-resolution skill, if you have one |
| `planning_skill` | Name of your planning/RFC skill, if you have one |
| `reviewer_roster` | Comma-separated list of your reviewer agents, if any |
| `env_axis_label` | Your environment/blast-radius classification axis, e.g. staging/prod or tenant tier |
| `rigor_doc_path` | Path or name of a rigor/review-discipline doc to cite, if you have one |
| `skeptic_rule_sources` | Array of paths to rigor/engineering-standards docs for the bundled skeptic agent to read |
| `code_review_skill` | Name of your code-review skill/process, for the skeptic agent's fallback routing |
| `extra_patterns` | Object of `intent -> [fragment, ...]` adding your own trigger vocabulary — see below |

### `extra_patterns`

The bundled patterns cover ordinary English. Your own habits — a recurring
typo, an in-house verb, a team shorthand — belong in your config, not in the
plugin, so they never ship to anyone else:

```json
"extra_patterns": {
  "finalize": ["finalz", "wrap it up"],
  "resolver": ["triage threads"]
}
```

Fragments are **additive**: they extend the shipped alternation and can never
replace or disable it, so a bad value degrades to the stock behaviour rather
than breaking the intent. Recognised keys are `finalize` and `resolver`.

Each fragment must consist of letters, digits, `_`, spaces or `-`, and contain
at least one letter or digit; anything else is dropped. Fragments are matched
against a lowercased prompt and are case-folded for you, so `"FINALZ"` and
`"finalz"` behave identically. Empty, whitespace-only and `|`-bearing values
are rejected rather than spliced — an empty alternation branch matches *every*
prompt on GNU grep and is a hard regex error on BSD grep, so one stray entry
would otherwise either fire the intent on every turn or silently kill it.

Prefer sharing a redacted config when reporting a routing bug: the same file
carries `ticket_system`, `rigor_doc_path` and `skeptic_rule_sources`, which
often name internal systems and document paths.

Intents that route to a specific skill (comment sweep, PR review, finalize,
resolver, planning) only emit a hard `Skill()` mandate when the relevant slot
is configured; otherwise they fall back to an inline checklist. A read-only
`skeptic` agent ships alongside it for root-cause/debugging/incident
answers — see `agents/skeptic.md`.

## Contributing

Validate the manifest locally before pushing:

```
claude plugin validate .
```
