#!/usr/bin/env bash
# See: ../README.md for design rationale and the configuration schema.

INPUT=$(cat)
PROMPT=$(printf '%s\n' "$INPUT" | jq -r '.prompt // empty')

# Skip long/slash-command prompts — this hook is precision-first, short-phrase only.
[ -z "$PROMPT" ] && exit 0
# 400, not 200: real workflow asks trail a clause onto other instructions ("wait for CI, resolve comments, finalize").
[ "${#PROMPT}" -gt 400 ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

NORM=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')

CONFIG_FILE="${HOME}/.claude/intent-router.config.json"

# Single jq read for the whole file — avoids a fresh jq spawn per slot lookup on this hot path.
if [ -f "$CONFIG_FILE" ]; then
  # Keys are whitelisted before eval — an unsanitized key could inject a command even with @sh-quoted values.
  eval "$(jq -r '
    (to_entries
     | map(select(.key | test("^[A-Za-z0-9_]+$")))
     | map(select(.value != null and .value != false))
     | map(select(.key != "extra_patterns"))
     | map("CFG_" + (.key | ascii_upcase) + "=" + ((.value | if type == "array" then join(", ") else tostring end) | @sh)))
    + (try ((.extra_patterns // {})
     | to_entries
     | map(select(.key | test("^[A-Za-z0-9_]+$")))
     | map(select(.value | type == "array"))
     | map("CFG_XP_" + (.key | ascii_upcase) + "=" + ((.value | map(tostring) | map(ascii_downcase) | map(select(test("^[a-z0-9_ -]+$") and test("[a-z0-9]"))) | join("|")) | @sh))) catch [])
    | .[]
  ' "$CONFIG_FILE" 2>/dev/null)"
fi

# slot <key> <default> — resolved value from the loaded config, or the generic default.
slot() {
  local key="$1" default="$2" upper var
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  var="CFG_${upper}"
  if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; else printf '%s' "$default"; fi
}

# has_slot <key> — true only if the config file sets a non-empty value for key.
has_slot() {
  local key="$1" upper var
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  var="CFG_${upper}"
  [ -n "${!var:-}" ]
}

# xp <intent> — additive user trigger fragments as a leading-'|' alternation tail; see: ../README.md § extra_patterns
xp() {
  local upper var val
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  var="CFG_XP_${upper}"
  val="${!var:-}"
  [ -z "$val" ] && return 0
  case "$val" in *[!A-Za-z0-9_\ \|-]*) return 0 ;; esac
  # An empty alternation branch matches every prompt on GNU grep and is a hard regex error on BSD/ugrep — reject rather than splice.
  case "$val" in '|'*|*'|'|*'||'*) return 0 ;; esac
  # A branch of only spaces matches almost everything; jq drops these, this is the belt-and-braces half.
  case "$val" in *[!\ \|]*) ;; *) return 0 ;; esac
  printf '|%s' "$val"
}

TICKET_SYSTEM=$(slot ticket_system "your ticket system")
TICKET_ID_PATTERN=$(slot ticket_id_pattern "your ticket-ID pattern")
TRACKER_PATH=$(slot tracker_path "your task-scratch file, if one exists")
BOT_PATTERN=$(slot watch_bot_pattern "bot")
# Same two hazards xp() guards: a disallowed char could close Intent 8's group early, and a boundary '|' yields an empty branch that matches every prompt on GNU grep and errors on BSD.
case "$BOT_PATTERN" in *[!A-Za-z0-9_\|-]*|'|'*|*'|'|*'||'*) BOT_PATTERN="bot" ;; esac

# A declined watch/plan/bundle request ("don't plan this yet") shouldn't fire the affirmative intent for it.
NEGATION_MATCH=0
printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(dont|do not|don.t|never|no need to|not necessary|skip (it|this|that))( |$)' && NEGATION_MATCH=1

CTX=""

# Intent 1: merge report — user-driven, happens outside Claude's tool surface.
if printf '%s\n' "$NORM" | grep -qE '^(i merged|merged|pr merged|merged all|merged the (pr|branch|changes?)|merged [0-9]+)[.?!]?$'; then
  CTX="${CTX}INTENT — USER-INITIATED MERGE DETECTED. Required before any other response:
  1. Cite the PR number + ticket (parse the branch name for ${TICKET_ID_PATTERN} if not stated).
  2. Confirm the ticket status in ${TICKET_SYSTEM} → 'done'.
  3. Surface unresolved follow-ups from this session (open PRs, deferred items, pending CI).
  4. State the next item in the work queue, or ask explicitly if no queue exists.
  Do not lead with a new question — lead with state confirmation.
"
fi

# Intent 2: status probe — a promised proactive report never landed.
if printf '%s\n' "$NORM" | grep -qE '^(status\??|any (status(es)?|updates?)\??|update( me)?\??|how is it going|where are we|where we at|what(.?s| is) the status)[.?!]?$'; then
  CTX="${CTX}INTENT — STATUS PROBE. User is checking on prior in-flight work. Before answering:
  1. Enumerate ALL pending state: background jobs, dispatched agents, CI runs being watched, in-flight skills.
  2. For each: fetch current state.
  3. Report concrete state — not 'let me check', not 'I'll get back to you'. The user is asking BECAUSE you didn't surface proactively.
"
fi

# Intent 14 is detected here, ahead of Intent 3, because "resolve comments" satisfies both and the two emit conflicting Skill() mandates.
RESOLVER_MATCH=0
if printf '%s\n' "$NORM" | grep -qE "(^|[^a-z])/?pr[ /-]?resolv(e|er|ed)?([^a-z]|\$)|(^|[^a-z])(run|use) (the )?resolver"; then
  RESOLVER_MATCH=1
else
  # "unresolved follow-ups" is the dominant false positive, so the state form only counts alongside a review-thread object.
  RES_STRIPPED=$(printf '%s' "$NORM" | sed -E 's/un-?res(olv|ovl)[a-z]*/UNRES/g')
  # "issue" is deliberately not an object on its own — "resolve the issue" is generic English; it only counts via the PR marker below.
  RES_OBJ='(comment|ocmment|commnet|thread|feedback|finding|suggestion|(^|[^a-z])nit([^a-z]|$)|bugbot|bot review|pullrequestreview)'
  # 3-digit floor on #N: "[image #2]" is an attachment ref, not a PR reference. A bare number is NOT a marker — "resolve the 502 errors" is not a PR.
  RES_PR='(^|[^a-z])prs?([^a-z]|$)|#[0-9]{3,}|/pull/'
  if printf '%s\n' "$RES_STRIPPED" | grep -qE "(^|[^a-z])(resolv|resovl|resolev$(xp resolver))e?[a-z]*" \
     && printf '%s\n' "$NORM" | grep -qE "$RES_OBJ|$RES_PR" \
     && ! { printf '%s\n' "$NORM" | grep -qE 'follow.?up' && ! printf '%s\n' "$NORM" | grep -qE "$RES_OBJ"; }; then
    RESOLVER_MATCH=1
  elif printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])un-?res(olv|ovl)[a-z]*' \
     && printf '%s\n' "$NORM" | grep -qE "$RES_OBJ"; then
    RESOLVER_MATCH=1
  fi
fi

# Intent 3: comment sweep — raw API calls skip codified per-comment discipline. Yields to Intent 14: fixing the finding supersedes triaging it.
if [ "$RESOLVER_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE '^((any |new )?comments?\??|check (for |the )?comments?( on (the )?prs?)?|(review|address|resolve) (comments?|threads?|feedback)( on (the )?prs?)?|what(.?s| is) on the pr|pr feedback)[.?!]?$'; then
  if has_slot pr_check_skill; then
    PR_CHECK_SKILL=$(slot pr_check_skill "")
    CTX="${CTX}INTENT — COMMENT/THREAD SWEEP (skill routing). The user is asking for a survey of the review comments/threads on a PR. REQUIRED: your next tool call MUST be Skill(skill='${PR_CHECK_SKILL}'), passing the PR number as args if the user named one. That skill is the configured owner of this intent — sweeping the comments yourself via raw API calls is a skill-routing violation. Apply whatever comment-review discipline the skill defines rather than substituting an ad-hoc pass. Exception: if the user's ask is materially narrower than the skill scope (e.g., 'how many comments?'), surface the mismatch and act on the answer.
"
  else
    CTX="${CTX}INTENT — COMMENT/THREAD SWEEP. Route to your PR-comment-review skill if you have one configured. If not, apply this discipline inline: pull every review thread with a per-comment multi-field projection (never a bulk summary), classify each comment individually (never bulk-label a batch as 'stale'), reply then resolve each addressed thread via a proper resolve mutation (not a raw close), and minimize rather than blank out stale bot-review summaries. Exception: if the user's ask is materially narrower (e.g., 'how many comments?'), surface the mismatch and act on the answer.
"
  fi
fi

# Intent 4: PR review request. See: README.md § PR review for the shape/authorship rationale.
REVIEW_LEAD='((please|pls|can you|could you|can we|lets|let.s|let us|go ahead and|now) )*'
REVIEW_NOUN='(pr|adversarial|code|full|deep|proper)[ -]review'
REVIEW_ACT='(do|run|trigger|start|kick ?off|launch|dispatch|spin up) (the |a |an )?(pr |adversarial |code )?review(ers?)?( of (the |this |my |our )?(prs?|pull requests?|diffs?|changes))?'
# Objects stay disjoint from Intent 3's (comments/threads/feedback) so "review comments" keeps routing there.
REVIEW_OBJ='(re-?)?review (the |this |that |my |our )?(prs?|pull requests?|diffs?|changes)'
# Trailing punctuation repeats: the pre-1.2.0 "reviewers?\??" branch accepted two marks, so "reviewers??" must keep firing.
REVIEW_TAIL='( ?#?[0-9]{1,7}| https?://[^ ]+)?( please| now| again)?'
if [ "$NEGATION_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE "^${REVIEW_LEAD}(${REVIEW_NOUN}|${REVIEW_ACT}|${REVIEW_OBJ}|reviewers?$(xp review))${REVIEW_TAIL}[.?!]*$"; then
  if has_slot pr_review_skill; then
    PR_REVIEW_SKILL=$(slot pr_review_skill "")
    REVIEW_ROUTE="REQUIRED: your next tool call MUST be Skill(skill='${PR_REVIEW_SKILL}'), passing the PR number as args if named."
    # Own-PR vs someone-else's-PR are different jobs; one target silently applies the wrong one.
    if has_slot pr_review_nonauthor_skill; then
      PR_REVIEW_NONAUTHOR_SKILL=$(slot pr_review_nonauthor_skill "")
      REVIEW_ROUTE="AUTHORSHIP DECIDES THE TARGET — the only tool calls permitted before routing are the two authorship lookups, \`gh pr view <PR> --json author --jq .author.login\` and \`gh api user --jq .login\`. Once authorship is known: self-authored → REQUIRED: your next tool call MUST be Skill(skill='${PR_REVIEW_SKILL}'); authored by anyone else → REQUIRED: your next tool call MUST be Skill(skill='${PR_REVIEW_NONAUTHOR_SKILL}') instead, which owns the CI verification and reviewer-scope resolution the own-PR path deliberately skips. Authorship you cannot resolve counts as non-author. Pass the PR number as args if named."
    fi
    CTX="${CTX}INTENT — PR REVIEW (skill routing). The user is asking for a review of the PR diff. ${REVIEW_ROUTE} That skill is the configured owner of this intent — reviewing the diff yourself is a skill-routing violation. Apply whatever review discipline the skill defines rather than substituting your own. If the mandated skill is not loadable in this session (a repo-scoped skill while the working directory sits outside that repo), say so plainly and review instead with independent per-axis passes covering correctness, security and any domain-specific risk the diff touches, labelling that as a fallback — do not silently improvise a review in its place. Exception: if the user's ask is narrower (e.g., 'is the diff sane?'), surface and confirm.
"
  else
    REVIEWER_ROSTER=$(slot reviewer_roster "one per axis")
    CTX="${CTX}INTENT — PR REVIEW. Route to your PR-review skill/agents if configured. If not, fan out to independent reviewer passes (${REVIEWER_ROSTER}) covering at minimum correctness, security, and any domain-specific risk the diff touches; apply a mechanical comment-style + privacy pre-gate before presenting findings; require every dismissed finding to carry demonstrable evidence, not assertion. A single undifferentiated pass skips the independent-perspective and dismissal-log discipline. Exception: if the user's ask is narrower (e.g., 'is the diff sane?'), surface and confirm.
"
  fi
fi

if [ "$RESOLVER_MATCH" -eq 1 ]; then
  if has_slot pr_resolver_skill; then
    PR_RESOLVER_SKILL=$(slot pr_resolver_skill "")
    CTX="${CTX}INTENT — PR COMMENT RESOLUTION (skill routing). The user is asking you to act on the review findings, not merely triage them. REQUIRED: your next tool call MUST be Skill(skill='${PR_RESOLVER_SKILL}'), passing the PR number as args if the user named one. That skill is the configured owner of this intent — replying-and-resolving the threads yourself is a skill-routing violation. If a finalize intent also fired this turn, resolve first and finalize after; never call the merge command yourself either way. Exception: if the ask is materially narrower (e.g., 'how many are unresolved?'), surface the mismatch and act on the answer.
"
  else
    CTX="${CTX}INTENT — PR COMMENT RESOLUTION. Route to your PR-comment-resolution skill if you have one configured. If not, apply this discipline inline: fix each finding in code rather than replying that it is acknowledged, commit the fixes, re-review the changed lines, then reply and resolve each thread individually via a proper resolve mutation. If a finalize intent also fired this turn, resolve first and finalize after; never merge either way. Exception: if the ask is materially narrower (e.g., 'how many are unresolved?'), surface the mismatch and act on the answer.
"
  fi
fi

# Intent 5: finalize / merge-intent phrasing — catches "ship it" before a raw merge attempt.
FINALIZE_MATCH=0
# Merge phrasings stay whole-prompt anchored: "merge it" as a substring fires on "dont merge it yet".
printf '%s\n' "$NORM" | grep -qE '^(is (the )?pr ready|ready to merge|merge ready|wrap up (the )?pr|pre-merge|all (set|done|good) for merge|merge it|merge th(is|ese)( one| pr)?|(please )?go ahead and merge|(lets|let.?s) merge( it| this)?|ship it|ok(ay)? merge( it)?|merge please|merge (it |this )?now)[.?!]?$' && FINALIZE_MATCH=1
# The finalize verb is matched as a substring: it is nearly always a trailing clause ("fix everything then finalize"), never the whole prompt.
if printf '%s\n' "$NORM" | grep -qE "(^|[^a-z])(pr[ -]?)?(finaliz|finalis$(xp finalize))[a-z]*" \
   && ! printf '%s\n' "$NORM" | grep -qE '(finalist|(finaliz|finalis)[a-z]*( [a-z]+){0,3} (naming|convention|approach|design|wording|schema|spec|rfc|doc|docs|document|version|draft|plan|copy|list|format|structure|architecture|decision|name|policy|template|title|message|notes|scheme))'; then
  FINALIZE_MATCH=1
fi
if [ "$FINALIZE_MATCH" -eq 1 ]; then
  if has_slot pr_finalize_skill; then
    PR_FINALIZE_SKILL=$(slot pr_finalize_skill "")
    CTX="${CTX}INTENT — FINALIZE PRE-MERGE GATE (skill routing). The user is signalling the PR is done and should be taken to its pre-merge end state. REQUIRED: your next tool call MUST be Skill(skill='${PR_FINALIZE_SKILL}'), passing PR number(s) as args if named. That skill is the configured owner of this intent — running your own ad-hoc pre-merge checklist instead is a skill-routing violation. Whatever the skill reports, never call the merge command yourself: merging is the user's action. Exception: if the ask is narrower (e.g., 'just check CI'), surface and confirm.
"
  else
    CTX="${CTX}INTENT — FINALIZE PRE-MERGE GATE. Route to your pre-merge-check skill if configured. If not, run this checklist inline before considering the PR mergeable, and never call the merge command yourself even if every check passes: CI is green, every review thread is resolved or explicitly addressed, the PR body matches the actual diff, commit history is clean, the tracked ticket (if any) is up to date, the PR has an assignee, and a final scan for personal paths/secrets/AI-attribution in the diff. Exception: if the ask is narrower (e.g., 'just check CI'), surface and confirm.
"
  fi
fi

# Intent 6: session queue / next item.
if printf '%s\n' "$NORM" | grep -qE '^(anything else( from this session)?\??|what(.?s| is) (left|next|still pending)|what(.?s| is) next( item)?|next( task| item| pr)?\??|what(.?s| is) remaining|are we done|done\??|is the session done)[.?!]?$'; then
  CTX="${CTX}INTENT — SESSION QUEUE / NEXT ITEM. The user is asking what remains. Before answering:
  1. List all PRs touched this session — their state (open/merged/closed), CI status, open threads.
  2. List all tickets touched in ${TICKET_SYSTEM} — status, blockers.
  3. List deferred items the user explicitly named ('out of scope', 'follow-up', 'next session').
  4. Then propose the next concrete action or confirm session can close.
  Do not answer 'yes' or 'no' without the enumeration above.
"
fi

# Intent 7: link request.
if printf '%s\n' "$NORM" | grep -qE '^(links?( to (the )?(pr|prs))?\??|link to (the )?pr|where.{0,15}pr|url|share the link|give me the link)[.?!]?$'; then
  CTX="${CTX}INTENT — PR URL REQUEST. User wants the URL(s) of the PR(s) under work. Fetch them for the current branch and any other PRs opened in this session. Surface as a list with PR number + title + URL. Do not summarize — just give links.
"
fi

# Intent 8: CI watch / wait-for — a promise the assistant must track and resolve.
if [ "$NEGATION_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE "(wait for (ci|the ci|${BOT_PATTERN}|review)|watch (the )?ci|watch (the )?pr|(report when|notify (me )?when|let me know when|tell me when)( (ci|${BOT_PATTERN}|done|ready))?)[.?!]?$"; then
  CTX="${CTX}INTENT — PROACTIVE-REPORT PROMISE. The user is asking you to watch and report back. Required: (a) state the polling mechanism you'll use (a watch/checks command, a background loop, agent dispatch), (b) state the success/failure criteria, (c) commit to surfacing the result before yielding silently.
"
fi

# Intent 9: rigor-amplifier branch is a broad substring match, so only the precise planning-verb branch may hard-mandate.
PLANNING_VERB_MATCH=0
[ "$NEGATION_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(plan (this|that|it)|plan the .+|let.?s plan|need to plan|draft (a |the )?plan|prepare (a |the )?plan|present (the )?plan|planning)[.?!]?$' && PLANNING_VERB_MATCH=1
RIGOR_AMPLIFIER_MATCH=0
[ "$NEGATION_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE '(evidence[- ]based|1000.{0,5}(% )?sure|100% sure|bulletproof|mock and test|verify (everything|the plan|all)|fully verify|before (we|i) (run|execute|merge|apply|destroy|remove))' && RIGOR_AMPLIFIER_MATCH=1
if [ "$PLANNING_VERB_MATCH" -eq 1 ] || [ "$RIGOR_AMPLIFIER_MATCH" -eq 1 ]; then
  if [ "$PLANNING_VERB_MATCH" -eq 1 ] && has_slot planning_skill; then
    PLANNING_SKILL=$(slot planning_skill "")
    CTX="${CTX}INTENT — PLANNING WITH RIGOR (skill routing). The user is asking for a plan or design, not an immediate implementation. REQUIRED: your next tool call MUST be Skill(skill='${PLANNING_SKILL}'), passing the prompt content as args. That skill is the configured owner of this intent — presenting a plan you assembled yourself instead is a skill-routing violation. Apply whatever phase gates and rigor checklist the skill defines; do not solution ahead of them. Exception: if the ask is narrower than the full pipeline, surface the mismatch and act on the answer. This hook only fires on short trigger phrasing (prompt ≤400 chars) — invoke the skill on your own judgment for longer freeform planning-shaped prompts too.
"
  else
    ENV_AXIS_LABEL=$(slot env_axis_label "your environment/blast-radius classification axis")
    CTX="${CTX}INTENT — PLANNING WITH RIGOR. Route to your planning skill if configured. If not, apply this checklist inline before presenting any plan: research before solving (no solution before evidence), a destructive-op resource table (Resource | ${ENV_AXIS_LABEL} | Verified-where | Status, no open rows), live classification from the source of truth rather than memory, evidence from live state only, ≥3 alternatives when comparing approaches, you as the default executor, and ≥1 adversarial failure mode named per major step. This hook only fires on short trigger phrasing (prompt ≤400 chars) — apply this on your own judgment for longer freeform planning-shaped prompts too.
"
  fi
fi

# Intent 10: adversarial review priming — user framing IS a finding-equivalent.
if printf '%s\n' "$NORM" | grep -qE '(wtf|rose.{0,5}tinted|pink.{0,5}tinted|verify if (this|that|it.?s|the).{0,5}(needed|correct|valid|right|wrong|necessary)|is the author|what is the author|messing with|this (is|looks) (wrong|garbage|broken|bad)|are you (stupid|sure)|take off (your |the )(rose|pink))'; then
  RIGOR_DOC=$(slot rigor_doc_path "")
  RIGOR_NOTE=""
  if [ -n "$RIGOR_DOC" ]; then RIGOR_NOTE=" Per ${RIGOR_DOC}."; fi
  CTX="${CTX}INTENT — ADVERSARIAL REVIEW. User framing is a finding-equivalent. Required posture this turn:
  1. Default-skeptical. Change is wrong until per-axis evidence proves otherwise. 'Matches existing pattern' / 'consistent posture' / 'narrow like X' require grep counts, file:line citations, or consumer counts in same paragraph — or get cut.
  2. Adversarial pass REQUIRED regardless of verdict — construct ≥1 credible failure mode per modified file; EMIT only material ones (not already a finding, non-trivial real-harm probability), else collapse to the 'Steelman: no material failure modes beyond the findings above.' marker. Net-negative/marginal goes on the Verdict line, not a bullet.
  3. Mechanical pre-gate before verdict — grep diff for: multi-line comment blocks, personal paths, AI attribution, internal-tool name leaks. Cross-repo claims verified by fetching the actual ref, NOT by trusting the PR description.
  4. Axes independent — trust principals, secret paths, env scope, naming, blast radius, derivation-vs-passthrough evaluated separately. Approval on one ≠ approval on others.
  5. 'Your instinct is partially wrong' opener FORBIDDEN. Lean MORE adversarial when user opens skeptical, not less.${RIGOR_NOTE}
"
fi

# Intent 11: bundling preference — user prefers extending the open PR over splitting.
if [ "$NEGATION_MATCH" -eq 0 ] && printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(bundle|just bundle|bundle (them|all|it|in|as)|in (one|the same|a single) pr|fold (it |this )?(in|into)|why (do we need )?(a |another |a new )?pr|now (we|i) need (another|a new) pr|need another pr)[.?!]?$'; then
  CTX="${CTX}INTENT — BUNDLING. User prefers extending the open PR over splitting. Default for related work in this session: extend the open PR. Splitting requires explicit current-message user request, not 'this fits better in a follow-up' reasoning. Before proposing a new branch/PR for related work — check if an open PR for the current ticket exists; if yes, extend it.
"
fi

# Intent 12: root-cause / debugging / incident — advisory only, never invokes the agent itself.
if printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(why (did|is|are|does|would|wont|won.?t).{0,40}(fail|failing|break|broke|broken|crash|error|down|timeout|timing out|not work|stuck)|root.?cause|rca([^a-z]|$)|whats? (causing|caused)|what is causing|figure out why|find out why|debug (this|the|why)|diagnose)' \
   || printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(the |my |our )?(job|pod|build|deploy|deployment|pipeline|workflow|run|apply|migration|service|container|test) (failed|is failing|keeps failing|crashed|keeps crashing|is broken|broke|timed out|wont start|won.?t start|is stuck)'; then
  CTX="${CTX}INTENT — ROOT-CAUSE / DEBUGGING / INCIDENT. Before presenting an answer, EVALUATE routing it through the read-only skeptic auditor bundled with this plugin: Agent(subagent_type='intent-router:skeptic'). Use it when the answer names a root cause, the failure is non-trivial, or you'd otherwise be presenting a first-fit hypothesis. To submit, assemble the briefing it requires — ORIGINAL USER ASK (verbatim) / TASK TYPE / CLAIMS each with file:line|command+output|url|none / ASSUMPTIONS / WHAT WAS NOT CHECKED — then spawn it and act on the verdict (ACCEPT / NEEDS-MORE-WORK / REJECT). A wrapper-level cause ('pod never Ready', 'CI exited 1', 'test failed') is a SYMPTOM, not a root cause — keep digging (logs, metrics, init containers, app stdout, sibling successful runs) until the underlying fault is named. Skip the skeptic only for trivial/obvious causes — and say so if you skip.
"
fi

# Intent 13: pause — literal trigger word, high precision by design.
if printf '%s\n' "$NORM" | grep -qE '^(please )?(lets |let.s )?pause( here| now| for now| everything| work| session| please)?[.,!? ]*$'; then
  CTX="${CTX}INTENT — PAUSE (graceful stop + resume packet). Required now, before anything else:
  1. Finish only the current atomic step safely — no new multi-step or destructive actions this turn.
  2. Emit the full handoff packet (ticket/task, decisions made, live-state snapshots, next steps, file paths) as the LAST message content.
  3. If an active task-tracking file exists for this work (e.g. ${TRACKER_PATH}), sync it with the same content (current phase, decisions, blockers, next action) — so resume survives even without re-pasting chat. No tracker file → handoff stays inline in chat only.
  4. Do not start new work, ask a new question, or treat this as an implicit answer to any question already pending.
"
fi

# Intent 15: imperative / defect-declarative — anchored hard because a false positive suppresses a clarifying question that may have been owed.
if [ "$NEGATION_MATCH" -eq 0 ] && { \
     printf '%s\n' "$NORM" | grep -qE '^([0-9]+[.)] *)?(ok|okay|yes|right)?[,. ]*(just )?(do it|proceed|go ahead|continue)( now| already| please)?( with [a-z0-9 ._-]{1,40})?[.!]*$' \
  || printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(stop asking|quit asking|is wrong because|thats wrong because)' \
  || printf '%s\n' "$NORM" | grep -qE '(^|[^a-z])(thats|that.s|its|it.s|this is) not (useful|general enough|right|correct|helpful|what i (asked|meant|wanted))' \
  || printf '%s\n' "$NORM" | grep -qE 'not useful[.!]*$'; }; then
  CTX="${CTX}INTENT — IMPERATIVE / DEFECT-DECLARATIVE. The user is instructing, not asking. Both an imperative ('do it', 'proceed', 'stop asking') and a declarative naming a defect ('X is wrong because Y', 'that's not useful') are instructions. Required posture this turn:
  1. Your next turn is a TOOL CALL, not a clarifying question and not an analysis of whether they are right. The premise was settled in a prior turn — re-arguing it spends a turn re-litigating what was already decided.
  2. Do NOT undo a change you made at their direction while 'looking into it'. Reverting their work is an action, not a neutral pause.
  3. A named defect is a report to fix, not a claim to evaluate. Verify by reading the artifact, then correct it — do not open by defending the prior version.
  4. Carve-out, unchanged: a shared-state mutation (force-push, history rewrite, deletion, production change, external post) still requires its own explicit approval. 'Proceed' authorizes the work, never the approval gate on top of it.
"
fi

[ -z "$CTX" ] && exit 0

jq -n --arg ctx "$CTX" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
