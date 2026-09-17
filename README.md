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
| `pr_review_nonauthor_skill` | Name of a separate skill for reviewing a PR you did *not* author, if you have one. Set it **alongside** `pr_review_skill` and the PR-review mandate resolves authorship first and routes to the matching skill; leave it empty and `pr_review_skill` handles both cases. On its own it is a no-op — the routing branch is gated on `pr_review_skill` |
| `pr_finalize_skill` | Name of your pre-merge-check skill, if you have one |
| `pr_resolver_skill` | Name of your PR-comment-resolution skill, if you have one |
| `planning_skill` | Name of your planning/RFC skill, if you have one |
| `design_doc_skill` | Name of your design-document skill, if you have one — the one that owns HLD/LLD/RFC/ADR *authoring and critique*, as opposed to the planning process around it |
| `reviewer_roster` | Comma-separated list of your reviewer agents, if any. Fallback text only — ignored when `pr_review_skill` is set |
| `env_axis_label` | Your environment/blast-radius classification axis, e.g. staging/prod or tenant tier. Fallback text only — ignored when `planning_skill` is set |
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
  "resolver": ["triage threads"],
  "review": ["look it over"]
}
```

Fragments are **additive**: they extend the shipped alternation and can never
replace or disable it, so a bad value degrades to the stock behaviour rather
than breaking the intent. Recognised keys are `finalize`, `resolver` and
`review`.

Two caveats specific to `review`. Its fragments splice into a **whole-prompt
anchored** pattern, whereas `finalize` and `resolver` splice into substring
matchers — so `"triage threads"` fires inside a longer sentence while
`"look it over"` only fires as the entire prompt. And a fragment that restates
another intent's trigger (`"review comments"`, `"resolve the pr"`) makes both
intents fire and emit two conflicting `Skill()` mandates; the shipped
alternations are disjoint by construction, but nothing validates a fragment
against them.

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

### PR review

The PR-review intent is whole-prompt anchored like most others, but tolerates
the three shapes a strict verb-first pattern rejects outright: noun order
(`pr review`, `code review`), a trailing PR reference (`review pr 123`,
`review pr #42`, a pasted `/pull/` URL), and a politeness or imperative
wrapper (`can you review the pr`, `please do a pr review`). Its objects
(`pr`, `diff`, `changes`) are kept disjoint from the comment-sweep intent's
(`comments`, `threads`, `feedback`) so `review comments` routes to exactly one
of them rather than firing both mandates.

Reviewing your own PR and reviewing someone else's are different jobs — CI
verification, reviewer-scope resolution and pushback posture apply only to the
latter — so a single configured target silently applies the wrong discipline to
one of them. Set `pr_review_nonauthor_skill` alongside `pr_review_skill` and the
mandate resolves authorship first, then routes to the matching skill; authorship
that cannot be resolved is treated as non-author. Setting it without
`pr_review_skill` does nothing, since the whole routing branch is gated on the
latter. The mandate also carries an
explicit escape hatch for a configured skill that is not loadable in the current
session — a repo-scoped skill while the working directory sits outside that
repo — so the assistant says so instead of quietly improvising a review.

### Design documents

"Write an HLD for X", "review this RFC", "is this design doc any good" are
document asks, and none of them contains a planning verb — so the planning
intent never sees them, which is the gap this intent closes. It fires on a
document-type noun (`hld`, `lld`, `rfc`, `adr`, `design doc`, `architecture
document`, `tech spec`) reached from an authoring verb (`write`, `draft`,
`update`, `revise`, …) or a critique verb (`review`, `critique`, `grade`, …),
allowing a short run of words between the two so `write a billing-service hld`
still fires.

What may follow the type noun is deliberately closed: punctuation, or a
connector such as `for`, `about`, `then` or `please`. A bare noun after it means
the type is being used as a modifier rather than as the artifact, so `write a
design doc parser` and `create an adr directory` are asking for code and do not
fire. The same rule drops `review rfc 7231`, where the digit marks a citation of
a published standard — and because it is scoped to the matched noun rather than
to the whole prompt, `review the design doc then check rfc 7231` still fires.

The type nouns are kept disjoint from the PR-review intent's objects (`pr`,
`diff`, `changes`), so `review the rfc` and `review the pr` each fire exactly
one mandate. Planning and design-document asks can legitimately both fire, and
the injected text says which owns what: planning owns the process, this owns the
artifact. Because this intent is head-anchored, co-firing needs the document verb
to lead — `draft an RFC, then let's plan the rollout` fires both, while `let's
plan the migration and draft an RFC` fires planning alone.

### Mined phrasings

The patterns started from the phrasings their author guessed people would
type. Comparing the hook against a semantic classifier over a month of real
prompts, with the disagreements judged blind, showed the guess was too narrow:
the hook fired on about a quarter of the prompts that carried an intent, while
almost every fire it did make was right. The 1.6 patterns close the gap
without giving up the precision, by admitting the shapes the real prompts
actually take rather than by loosening the anchors:

- **A PR number or object around the verb.** `1532 merged`, `merged both PRs`,
  `merged the readme pr`, `merged 837 and 11456`, and a trailing clause after
  it (`merged. we should learn from this`, `1611 merged. proceed`). A bare
  `the <noun>` only counts for a PR, a branch or `the changes`, so `merged the
  two configs into one` and `merged the upstream changes` stay silent, as does
  a local squash (`merged 2 and 3 into a single commit`), and `merged?` stays a
  whole-prompt question.
- **A PR reference after the review noun.** `pr review - <url> this part is
  sensitive`, `review pr 1234 but ignore the tests`, `review pr 1234
  thoroughly`: a URL, a `#N`, or a bare number of two or more digits fixes the
  intent and anything may follow. A single digit is a count unless it ends the
  clause, so `review pr 2` fires and `pr review - 2 blockers, address them`
  does not. The
  trailing-clause form yields to a resolver or finalize ask in the same prompt
  (`review pr 1234 and resolve the comments` routes to the resolver alone),
  and `review pr 1234 comments` is a comment sweep, not a review.
- **Status of in-flight work.** `status of <x>` at the head of a prompt; `report
  status`, `check pr status` when what follows is the end, a conjunction, or
  `of` an in-flight object — which may carry a determiner, a count, an
  adjective and PR numbers (`check the status of the 3 prs`, `status of prs
  1234 and 1235`, `status of the background jobs`) — never `status code`,
  `status on the pods` or `status of the pods`. Liveness fires with an
  agent-like subject (`subagents still running?`, `is ci still running?`, `is
  it still running`) or as a bare question (`still running?`, `still alive?`),
  never for `is the old cluster still running?` or an exclamation (`deployed.
  it's running!`). A negation anywhere in the prompt suppresses the branch.
- **What remains.** `anything else open from this session?`, `what are we
  waiting on`; a trailing `next steps` led by a report verb within a few words
  (`what are the next steps?`, `tell me the next steps`, `report on the plan
  and next steps`) — never a document noun (`update the readme with next
  steps`, `a summary with findings and next steps`); a trailing `what else?`
  after a sentence break or an acknowledgement (`ok, what else?`) — never a
  list's `, what else?`. A negation of the ask itself (`don't give me next
  steps`) is silent; a negation elsewhere (`I don't understand. what is left
  to do?`) is not.
- **Comments and findings.** `check prs for comments/issues` (a bare `issues`
  is a diff-review ask), yielding to a finalize ask that fires in the same
  prompt so only one skill mandate is emitted; `<n> has comments to address`,
  `fix/address all findings` (bare `fix` or `address` stay out).
- **The handoff resume.** `read <file> and continue` is the single most common
  prompt shape in the sample and carries the same posture as `continue`: the
  next turn is a tool call, not a question. Anything may follow (`… and
  continue - no slack messages`, `… and continue. when done, write a
  followup`) except a condition bound directly to it (`… and continue only if
  the plan makes sense`, `… but only if`, `… assuming ci is green`). `try
  again` after a fixed precondition (`the vpn is connected now. try again`) is
  the same instruction.
- **Challenges and incidents.** `I don't understand what you built and why`,
  `I don't understand what you're doing`, `I miss your point`, `why do we still
  have any tests?!` prime the adversarial posture; a request for an explanation
  (`I don't understand how workspaces work`) does not. `ci is red`, `I still see
  a red check`, `zizmor is stuck?`, `ci is stuck, check why`, `do we have a bug
  in …` prime the root-cause posture; every fragment is word-bounded, so `red
  xml`, `redshift` and `bugbot` do not.
- **The rest.** `fold into the existing pr`, `fold if possible`, `single pr for
  everything`; `report when ci is done`, `wait for ci to finish`; `why is this
  taking so long?`; plan-first asks that
  never end in a planning noun: `chart the path forward`, `run it through
  planning`, `read, verify, check. plan.`, `what is our plan to retire amd64`.

Every new branch was checked against the full month of prompts before it
landed; the ones that fired on anything the judges had not upheld were
tightened or dropped. Three independent reviews then probed each trigger word
in its other senses — as a noun (`status code`), negated (`don't pause now`),
interrogative (`should we pause here?`), as a count (`merge 3 commits`), in its
Terraform sense (`run the plan and wait for my go`) — and, the other way, each
promised shape with the words people put after it. Three mined families never
converged: every boundary that silenced their false fires also silenced real
asks. 1.6.2 therefore returns them to their pre-1.6 whole-prompt forms rather
than widening further: mid-prompt merge asks (`can I merge 1234 yet?`),
plan-first holds (`present to me and wait for my go`), and pauses inside a
longer prompt (`pausing here. write a follow-up`). Bare `merge it`, `ship it`,
`let's pause` and the planning verbs still fire as before. Every probe from
the reviews is a regression case.

## Contributing

Validate the manifests and run the test suite locally before pushing:

```
claude plugin validate . --strict
bash tests/test-intents.sh
```

`marketplace.json` declares this repo as the only plugin it ships
(`"source": "./"`), so that single validate command covers both manifests, and
`--strict` fails on fields the runtime would otherwise tolerate. CI runs the
same two checks, plus shellcheck and a second pass of the suite under BusyBox
grep.
