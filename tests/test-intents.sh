#!/usr/bin/env bash
# Regression suite for hooks/intent-router.sh — run before every push, not only via bot review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/intent-router.sh"

PASS=0
FAIL=0

# jq -n, not printf: a " or \ in the prompt built malformed JSON, and the silent hook that followed scored as a pass.
run_hook() {
  jq -n --arg p "$1" '{prompt: $p}' | "$HOOK" 2>/dev/null
}

assert_match() {
  local prompt="$1" expect="$2" raw out
  raw=$(run_hook "$prompt")
  if [ -z "$raw" ]; then out="NO_MATCH"; else out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext'); fi
  if printf '%s' "$out" | grep -qF "$expect"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL match:    "%s" expected to contain "%s", got: %.80s\n' "$prompt" "$expect" "$out"
  fi
}

assert_no_match() {
  local prompt="$1" raw
  raw=$(run_hook "$prompt")
  if [ -z "$raw" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL no-match: "%s" expected no match, got: %.80s\n' "$prompt" "$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')"
  fi
}

# Intents are disjoint by construction; nothing but this proves a widened pattern hasn't started double-firing.
assert_lacks() {
  local prompt="$1" unexpected="$2" raw out
  raw=$(run_hook "$prompt")
  # A silent hook satisfies every negative assertion, so absence only counts once something was emitted.
  if [ -z "$raw" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL lacks:    "%s" emitted nothing — a vacuous pass, not a disjointness proof\n' "$prompt"
    return
  fi
  out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
  if printf '%s' "$out" | grep -qF "$unexpected"; then
    FAIL=$((FAIL + 1))
    printf 'FAIL lacks:    "%s" expected NOT to contain "%s"\n' "$prompt" "$unexpected"
  else
    PASS=$((PASS + 1))
  fi
}

# ---------- Phase A: no config present — every intent must resolve to generic fallback text ----------
TMPHOME_A=$(mktemp -d)
export HOME="$TMPHOME_A"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

echo "=== Phase A: zero-config (generic fallback) ==="

# Intent 1 — merge detected
assert_match    "merged" "USER-INITIATED MERGE"
assert_match    "i merged" "USER-INITIATED MERGE"
assert_match    "pr merged" "USER-INITIATED MERGE"
assert_match    "merged all" "USER-INITIATED MERGE"
assert_match    "merged the pr" "USER-INITIATED MERGE"
assert_match    "merged the branch" "USER-INITIATED MERGE"
assert_match    "merged the changes" "USER-INITIATED MERGE"
assert_match    "merged 5" "USER-INITIATED MERGE"
assert_match    "merged?" "USER-INITIATED MERGE"
assert_match    "merged!" "USER-INITIATED MERGE"
assert_no_match "update the readme"
assert_no_match "merged the css into one file"
assert_no_match "merged all the css into one file"

# Intent 2 — status probe
assert_match    "status" "STATUS PROBE"
assert_match    "status?" "STATUS PROBE"
assert_match    "status!" "STATUS PROBE"
assert_match    "any status" "STATUS PROBE"
assert_match    "any statuses" "STATUS PROBE"
assert_match    "any updates" "STATUS PROBE"
assert_match    "any update" "STATUS PROBE"
assert_match    "update me" "STATUS PROBE"
assert_match    "how is it going" "STATUS PROBE"
assert_match    "where are we" "STATUS PROBE"
assert_match    "what is the status" "STATUS PROBE"
assert_match    "whats the status" "STATUS PROBE"
assert_match    "what's the status" "STATUS PROBE"
assert_no_match "update the readme"
assert_no_match "any updates to the css"

# Intent 3 — comment sweep
assert_match    "comments" "COMMENT/THREAD SWEEP"
assert_match    "comments?" "COMMENT/THREAD SWEEP"
assert_match    "any comments" "COMMENT/THREAD SWEEP"
assert_match    "new comments" "COMMENT/THREAD SWEEP"
assert_match    "check comments" "COMMENT/THREAD SWEEP"
assert_match    "check for comments" "COMMENT/THREAD SWEEP"
assert_match    "review comments" "COMMENT/THREAD SWEEP"
assert_match    "what is on the pr" "COMMENT/THREAD SWEEP"
assert_match    "whats on the pr" "COMMENT/THREAD SWEEP"
assert_match    "pr feedback" "COMMENT/THREAD SWEEP"
assert_no_match "comment on this approach"

# Intent 4 — PR review request
assert_match    "review the pr" "PR REVIEW"
assert_match    "review pr" "PR REVIEW"
assert_match    "review this pr" "PR REVIEW"
assert_match    "run the review" "PR REVIEW"
assert_match    "trigger the review" "PR REVIEW"
assert_match    "adversarial review" "PR REVIEW"
# Noun order, PR refs and politeness wrappers — the shapes the anchored pattern used to miss entirely.
assert_match    "pr review" "PR REVIEW"
assert_match    "PR Review" "PR REVIEW"
assert_match    "code review" "PR REVIEW"
assert_match    "review pr 123" "PR REVIEW"
assert_match    "review pr #42" "PR REVIEW"
assert_match    "review the pr https://github.com/o/r/pull/7" "PR REVIEW"
assert_match    "can you review the pr" "PR REVIEW"
assert_match    "lets review the pr" "PR REVIEW"
assert_match    "review this pr please" "PR REVIEW"
assert_match    "please do a pr review" "PR REVIEW"
assert_match    "review the diff" "PR REVIEW"
assert_match    "review the changes" "PR REVIEW"
assert_match    "run the reviewers" "PR REVIEW"
assert_match    "reviewers" "PR REVIEW"
assert_match    "reviewers?" "PR REVIEW"
# The pre-1.2.0 branch was "reviewers?\??" — two trailing marks fired then and must still fire.
assert_match    "reviewers??" "PR REVIEW"
assert_match    "reviewer??" "PR REVIEW"
assert_match    "reviewers?!" "PR REVIEW"
# Possessives and the spelled-out object: "review my pr" is the commonest form the first cut missed.
assert_match    "review my pr" "PR REVIEW"
assert_match    "review our pr" "PR REVIEW"
assert_match    "review my changes" "PR REVIEW"
assert_match    "review the pull request" "PR REVIEW"
assert_match    "do a review of the pr" "PR REVIEW"
# The noun separator is mandatory, so run-together words are not review triggers.
assert_no_match "prreview"
assert_no_match "deepreview"
assert_no_match "reviewers usually miss this kind of bug"
assert_no_match "dont review the pr"
assert_no_match "review"
assert_no_match "review this"
# Intent 3 owns comment objects — widening Intent 4 must not poach them.
raw=$(run_hook "review comments")
out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
if printf '%s' "$out" | grep -qF "COMMENT/THREAD SWEEP" && ! printf '%s' "$out" | grep -qF "PR REVIEW"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf 'FAIL: "review comments" must stay with the comment sweep, got: %.120s\n' "$out"
fi

# Intent 5 — finalize / merge-intent phrasing
assert_match    "finalize" "FINALIZE"
assert_match    "is the pr ready" "FINALIZE"
assert_match    "ready to merge" "FINALIZE"
assert_match    "ship it" "FINALIZE"
assert_match    "ship it!" "FINALIZE"
assert_match    "merge it" "FINALIZE"
assert_match    "merge please" "FINALIZE"
assert_no_match "finalize the naming convention"
# Trailing-clause forms — the shape the anchored pattern used to miss entirely.
assert_match    "run finalize" "FINALIZE"
assert_match    "finalize the pr" "FINALIZE"
assert_match    "finalize prs" "FINALIZE"
assert_match    "fix and address everything then finalize" "FINALIZE"
assert_match    "when done finalize" "FINALIZE"
assert_match    "check prs for issues/comments and finalize" "FINALIZE"
assert_match    "1184 needs pr-finalize" "FINALIZE"
assert_match    "did you run pr-finalize on each?" "FINALIZE"
assert_match    "wait for ci to complete on all three and run pr-finalize" "FINALIZE"
assert_match    "make sure to finalize the pr and close any gaps" "FINALIZE"
assert_no_match "we create a finalized rfc that others can review"
assert_no_match "finalize the wording of the error message"

# Intent 14 — PR comment resolution
assert_match    "pr-resolver" "PR COMMENT RESOLUTION"
assert_match    "run pr-resolver and then finalize" "PR COMMENT RESOLUTION"
assert_match    "run resolver then run finalize" "PR COMMENT RESOLUTION"
assert_match    "resolve comments and finalize" "PR COMMENT RESOLUTION"
assert_match    "resolve issues with pr" "PR COMMENT RESOLUTION"
assert_match    "1202 has comments. resolve and finalize" "PR COMMENT RESOLUTION"
assert_match    "address/resolve comments on pr and finalize" "PR COMMENT RESOLUTION"
assert_match    "re-check both prs and resolve all comments if any" "PR COMMENT RESOLUTION"
assert_match    "there is an unresolved comment on the pr" "PR COMMENT RESOLUTION"
# "unresolved follow-ups" is a session-summary idiom, not a request to touch review threads.
assert_no_match "prepare follow-up prompt for unresolved"
assert_no_match "can we resolve the footgun?"
assert_no_match "i would like to resolve it"
# Object tokens need word boundaries: "nit" must not match inside "unit"/"init".
assert_no_match "resolve the unit test failures"
assert_no_match "resolve the init script"
# A bare number is not a PR reference.
assert_no_match "resolve the 502 errors"
assert_no_match "can you resolve the 4096 byte limit"
assert_no_match "the finalists were announced"

# Intent 3 yields to Intent 14 — "resolve comments" satisfies both, and two hard Skill() mandates would conflict.
raw=$(run_hook "resolve comments")
out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
if printf '%s' "$out" | grep -qF "PR COMMENT RESOLUTION" && ! printf '%s' "$out" | grep -qF "COMMENT/THREAD SWEEP"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf 'FAIL: "resolve comments" must route to resolver only, got: %.120s\n' "$out"
fi
# Resolver is emitted before finalize so a combined ask reads in workflow order.
raw=$(run_hook "resolve comments and finalize")
out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
# Prefix-trim rather than grep -b: BusyBox grep has no byte-offset flag.
before_res="${out%%PR COMMENT RESOLUTION*}"
before_fin="${out%%FINALIZE PRE-MERGE GATE*}"
if [ "${#before_res}" -lt "${#before_fin}" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf 'FAIL: resolver must be injected before finalize\n'
fi

# Intent 6 — session queue / next item
assert_match    "anything else" "SESSION QUEUE"
assert_match    "whats left" "SESSION QUEUE"
assert_match    "whats next" "SESSION QUEUE"
assert_match    "whats next item" "SESSION QUEUE"
assert_match    "what is next" "SESSION QUEUE"
assert_match    "next task" "SESSION QUEUE"
assert_match    "are we done" "SESSION QUEUE"
assert_match    "done" "SESSION QUEUE"
assert_match    "done?" "SESSION QUEUE"
assert_no_match "next add tests"

# Intent 7 — link request
assert_match    "link" "PR URL REQUEST"
assert_match    "link?" "PR URL REQUEST"
assert_match    "links to the pr" "PR URL REQUEST"
assert_match    "url" "PR URL REQUEST"
assert_match    "share the link" "PR URL REQUEST"
assert_no_match "link the two services together"

# Intent 8 — CI watch / wait-for
assert_match    "wait for ci" "PROACTIVE-REPORT"
assert_match    "watch the ci" "PROACTIVE-REPORT"
assert_match    "notify me when" "PROACTIVE-REPORT"
assert_match    "let me know when" "PROACTIVE-REPORT"
assert_match    "let me know when done" "PROACTIVE-REPORT"
assert_match    "tell me when ready" "PROACTIVE-REPORT"
assert_no_match "let me know when you are free for lunch"
assert_no_match "dont wait for ci"

# Intent 9 — planning with rigor (soft path, no planning_skill configured)
assert_match    "plan this" "PLANNING"
assert_match    "plan the migration" "PLANNING"
assert_match    "lets plan" "PLANNING"
assert_match    "100% sure" "PLANNING"
assert_match    "verify everything is not broken before we proceed" "PLANNING"
assert_match    "verify everything" "PLANNING"
assert_no_match "dont plan this"
assert_no_match "never mind, dont plan the migration"

# Intent 16 — design document (soft path, no design_doc_skill configured)
assert_match    "write an hld for the billing service" "DESIGN DOCUMENT"
assert_match    "draft an rfc" "DESIGN DOCUMENT"
assert_match    "review this rfc" "DESIGN DOCUMENT"
assert_match    "review the design doc" "DESIGN DOCUMENT"
assert_match    "is this hld any good" "DESIGN DOCUMENT"
assert_match    "grade my adr" "DESIGN DOCUMENT"
assert_match    "hld review" "DESIGN DOCUMENT"
assert_match    "write a technical spec" "DESIGN DOCUMENT"
# Revising an existing document is the same intent as writing one.
assert_match    "update the hld" "DESIGN DOCUMENT"
assert_match    "revise the design doc" "DESIGN DOCUMENT"
# A connector after the type noun keeps the noun as the artifact, so these stay live.
assert_match    "review my adr please" "DESIGN DOCUMENT"
assert_match    "draft an rfc for v2 of the api" "DESIGN DOCUMENT"
# A bare noun after the type noun makes it a modifier — these ask for code, not a document.
assert_no_match "write a design doc parser"
assert_no_match "create a design doc review agent"
assert_no_match "draft an rfc template generator"
assert_no_match "write an hld linter in python"
assert_no_match "create an adr directory in the repo"
assert_no_match "assess the rfc parsing library"
assert_no_match "review the design doc workflow code"
# A published-standard citation is not a request to author one.
assert_no_match "review rfc 7231"
assert_no_match "read rfc #2616"
# ...but a citation elsewhere in the prompt must not veto a genuine ask.
assert_match    "review the design doc then check rfc 7231" "DESIGN DOCUMENT"
assert_no_match "dont write an hld yet"
# The type nouns stay disjoint from the PR-review intent's objects, so each fires exactly one mandate.
assert_lacks    "review this rfc" "PR REVIEW"
assert_lacks    "review the pr" "DESIGN DOCUMENT"
# No planning verb here — this is the whole reason the intent exists.
assert_lacks    "write an hld for the billing service" "PLANNING"
# Co-firing is real but needs the document verb to lead, since this intent is head-anchored.
assert_match    "draft an rfc, then lets plan the rollout" "DESIGN DOCUMENT"
assert_match    "draft an rfc, then lets plan the rollout" "PLANNING"
assert_lacks    "lets plan the migration and draft an rfc" "DESIGN DOCUMENT"
assert_no_match "the architecture is fine"

# Intent 10 — adversarial review priming (substring by design)
assert_match    "this looks garbage" "ADVERSARIAL REVIEW"
assert_match    "wtf" "ADVERSARIAL REVIEW"
assert_match    "are you sure" "ADVERSARIAL REVIEW"
assert_no_match "taking out the garbage tonight"

# Intent 11 — bundling preference
assert_match    "bundle" "BUNDLING"
assert_match    "bundle!" "BUNDLING"
assert_no_match "no need to bundle this"
assert_no_match "bundle this webpack config"

# Intent 12 — root-cause / debugging (substring by design)
assert_match    "rca" "ROOT-CAUSE"
assert_match    "root cause" "ROOT-CAUSE"
assert_match    "why is this failing" "ROOT-CAUSE"
assert_no_match "orca sighting today"

# Intent 13 — pause
assert_match    "pause" "PAUSE"
assert_match    "please pause" "PAUSE"

# Intent 15 — imperative / defect-declarative
assert_match    "proceed" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "just do it" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "do it now" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "go ahead" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "stop asking me and just fix it" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "that's not useful" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "the regex is wrong because it misses the anchor" "IMPERATIVE / DEFECT-DECLARATIVE"
# A numbered reply is the ordinary shape when answering a multi-part question.
assert_match    "1. proceed" "IMPERATIVE / DEFECT-DECLARATIVE"
# "proceed with the merge" is the highest-stakes imperative and fired NO intent before the tail was widened.
assert_match    "proceed with the merge" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_match    "proceed with the merge" "still requires its own explicit approval"
assert_match    "go ahead with the rebase" "IMPERATIVE / DEFECT-DECLARATIVE"
assert_no_match "should I proceed with the merge?"
# The carve-out is the whole reason this intent is safe to fire — a rewrite that drops it silently authorizes destructive work.
assert_match    "proceed" "still requires its own explicit approval"
# Interrogatives must stay silent: firing here suppresses a clarifying question that was owed.
assert_no_match "should I proceed?"
assert_no_match "do you think we should do it now?"
assert_no_match "can you continue the migration tomorrow?"
assert_no_match "why is this not useful to the reviewer?"
assert_no_match "is that not correct in your view?"
assert_no_match "3. continue reading the plan and tell me what you think"
# The shared negation guard must suppress a declined imperative.
assert_no_match "don't do it yet"

rm -rf "$TMPHOME_A"

# ---------- Phase B: config present — hard-mandate routing, null/false handling, injection safety ----------
TMPHOME_B=$(mktemp -d)
mkdir -p "$TMPHOME_B/.claude"
jq -n '{
  ticket_system: "ClickUp",
  pr_finalize_skill: "pr-finalize",
  pr_resolver_skill: "pr-resolver",
  planning_skill: null,
  watch_bot_pattern: "x)|(.*",
  extra_patterns: { finalize: ["finalz"], resolver: ["x)|(.*"] }
}' > "$TMPHOME_B/.claude/intent-router.config.json"
export HOME="$TMPHOME_B"

echo "=== Phase B: config present (hard mandates, null handling, adversarial values) ==="

assert_match    "ship it" "Skill(skill='pr-finalize')"
assert_match    "merged" "ClickUp"
assert_match    "resolve comments on pr" "Skill(skill='pr-resolver')"
# extra_patterns is additive: a configured typo form routes exactly like the bundled spelling.
assert_match    "run finalzie" "Skill(skill='pr-finalize')"
assert_match    "finalzie the prs" "Skill(skill='pr-finalize')"
# An unbalanced fragment is dropped, not spliced in — the bundled resolver pattern must still work and must not start matching everything.
assert_match    "resolve the comments" "Skill(skill='pr-resolver')"
assert_no_match "deploy the staging cluster"
raw=$(run_hook "plan this")
out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
if printf '%s' "$out" | grep -qF "Skill(skill="; then
  FAIL=$((FAIL + 1))
  printf 'FAIL: null planning_skill produced a hard mandate: %.80s\n' "$out"
else
  PASS=$((PASS + 1))
fi
assert_no_match "totally unrelated short prompt"

rm -rf "$TMPHOME_B"

# ---------- Phase C: extra_patterns fragments that pass a character whitelist but are semantically hazardous ----------
TMPHOME_C=$(mktemp -d)
mkdir -p "$TMPHOME_C/.claude"
export HOME="$TMPHOME_C"
CFG_C="$TMPHOME_C/.claude/intent-router.config.json"

echo "=== Phase C: hazardous-but-whitelisted extra_patterns ==="

# An empty alternation branch matches every prompt on GNU grep and is a hard regex error on BSD/ugrep. Both outcomes are wrong; neither may reach the matcher.
for bad in '["finalz",""]' '["finalz|"]' '["|finalz"]' '["finalz||wrap"]' '[" "]' '["  ","finalz"]'; do
  jq -n --argjson f "$bad" '{pr_finalize_skill:"pr-finalize", extra_patterns:{finalize:$f}}' > "$CFG_C"
  assert_no_match "deploy the staging cluster"
  assert_no_match "hello"
  assert_match    "finalize the pr" "Skill(skill='pr-finalize')"
done

# watch_bot_pattern feeds Intent 8's alternation the same way extra_patterns feeds 5/14 — it needs the same boundary-pipe guard.
for bad in 'bugbot|' '|bugbot' 'bugbot||x' ; do
  jq -n --arg b "$bad" '{watch_bot_pattern:$b}' > "$CFG_C"
  assert_match    "wait for ci" "PROACTIVE-REPORT"
  assert_no_match "deploy the staging cluster"
done
jq -n '{watch_bot_pattern:"bugbot"}' > "$CFG_C"
assert_match "wait for bugbot" "PROACTIVE-REPORT"

# Intent 4 gained an extra_patterns hook; it must be additive exactly like finalize/resolver.
jq -n '{pr_review_skill:"pr-review", extra_patterns:{review:["revoo","look at the pr"]}}' > "$CFG_C"
assert_match    "revoo" "Skill(skill='pr-review')"
assert_match    "look at the pr" "Skill(skill='pr-review')"
assert_match    "review the pr" "Skill(skill='pr-review')"
assert_no_match "deploy the staging cluster"
for bad in '["revoo",""]' '["|revoo"]' '[" "]'; do
  jq -n --argjson f "$bad" '{pr_review_skill:"pr-review", extra_patterns:{review:$f}}' > "$CFG_C"
  assert_no_match "deploy the staging cluster"
  assert_match    "review the pr" "Skill(skill='pr-review')"
done

# Fragments are matched against a lowercased prompt, so they must be case-folded rather than silently dead.
jq -n '{pr_finalize_skill:"pr-finalize", extra_patterns:{finalize:["FINALZ"]}}' > "$CFG_C"
assert_match "run finalz" "Skill(skill='pr-finalize')"
assert_match "run FINALZ" "Skill(skill='pr-finalize')"

# A malformed extra_patterns must not take the rest of the config down with it.
jq -n '{pr_finalize_skill:"pr-finalize", extra_patterns:"oops-a-string"}' > "$CFG_C"
assert_match "finalize the pr" "Skill(skill='pr-finalize')"
jq -n '{pr_finalize_skill:"pr-finalize", extra_patterns:{finalize:"not-an-array"}}' > "$CFG_C"
assert_match "finalize the pr" "Skill(skill='pr-finalize')"

# The negative guard must survive words between the verb and the excluded noun.
rm -f "$CFG_C"
assert_no_match "finalize the api design doc"
assert_no_match "i finalized the tenant naming scheme"
assert_no_match "we finalized the migration plan last week"
assert_no_match "lets finalize the release notes"

rm -rf "$TMPHOME_C"

# ---------- Phase D: configured-branch text — Phase B leaves pr_check/pr_review unset and planning null, so those branches never run there ----------
TMPHOME_D=$(mktemp -d)
mkdir -p "$TMPHOME_D/.claude"
jq -n '{
  pr_check_skill: "pr-check",
  pr_review_skill: "pr-review",
  pr_review_nonauthor_skill: "adversarial-pr-review",
  pr_finalize_skill: "pr-finalize",
  pr_resolver_skill: "pr-resolver",
  planning_skill: "planning",
  design_doc_skill: "design-doc"
}' > "$TMPHOME_D/.claude/intent-router.config.json"
export HOME="$TMPHOME_D"

echo "=== Phase D: configured-branch text integrity ==="

assert_match "check comments" "Skill(skill='pr-check')"
assert_match "review the pr" "Skill(skill='pr-review')"
assert_match "lets plan this" "Skill(skill='planning')"
assert_match "write an hld" "Skill(skill='design-doc')"

# A rewrite that drops either half of mandate-plus-escape-hatch is otherwise a silent regression.
for p in "check comments" "review the pr" "ship it" "resolve comments on pr" "lets plan this" "write an hld"; do
  assert_match "$p" "REQUIRED: your next tool call MUST be Skill("
  assert_match "$p" "Exception:"
done

# The routing intents must keep telling the model to forward the PR number.
for p in "check comments" "review the pr" "ship it" "resolve comments on pr"; do
  assert_match "$p" "as args if"
done

# Ordering and the never-merge prohibition must outlive any rewrite of the surrounding prose.
assert_match "resolve comments on pr" "resolve first and finalize after"
assert_match "resolve comments on pr" "never call the merge command yourself"
assert_match "ship it" "never call the merge command yourself"

# A configured skill can still be unreachable; the mandate must carry its own escape hatch.
assert_match "review the pr" "not loadable in this session"

# Authorship split: both targets named, and the own-PR skill is still the self-authored branch.
assert_match "review the pr" "AUTHORSHIP DECIDES THE TARGET"
assert_match "review the pr" "Skill(skill='adversarial-pr-review')"
assert_match "review the pr" "Skill(skill='pr-review')"
# The lookups must be carved out explicitly, or "next tool call MUST be Skill()" is unsatisfiable.
assert_match "review the pr" "the only tool calls permitted before routing"
# The escape hatch must state its fallback, not point at text that only the else-branch emits.
for p in "check comments" "review the pr" "ship it" "resolve comments on pr" "lets plan this"; do
  raw=$(run_hook "$p")
  out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
  if printf '%s' "$out" | grep -qF "discipline below"; then
    FAIL=$((FAIL + 1)); printf 'FAIL: "%s" references absent "discipline below" text\n' "$p"
  else
    PASS=$((PASS + 1))
  fi
done

# With no non-author skill configured, the split must vanish rather than degrade to a half-mandate.
jq -n '{pr_review_skill: "pr-review"}' > "$TMPHOME_D/.claude/intent-router.config.json"
assert_match "review the pr" "Skill(skill='pr-review')"
assert_match "review the pr" "REQUIRED: your next tool call MUST be Skill("
raw=$(run_hook "review the pr")
out=$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext')
if printf '%s' "$out" | grep -qF "AUTHORSHIP DECIDES THE TARGET"; then
  FAIL=$((FAIL + 1)); printf 'FAIL: authorship split leaked without pr_review_nonauthor_skill set\n'
else
  PASS=$((PASS + 1))
fi

rm -rf "$TMPHOME_D"

# ---------- Phase E: fallback-only slots — an unset var expands to empty, so a dropped assignment yields "()" unnoticed ----------
TMPHOME_E=$(mktemp -d)
mkdir -p "$TMPHOME_E/.claude"
export HOME="$TMPHOME_E"

echo "=== Phase E: fallback-slot interpolation ==="

assert_match "review the pr" "passes (one per axis) covering"
assert_match "lets plan this" "your environment/blast-radius classification axis"

jq -n '{reviewer_roster: "sec-reviewer, perf-reviewer", env_axis_label: "prod/staging"}' \
  > "$TMPHOME_E/.claude/intent-router.config.json"
assert_match "review the pr" "passes (sec-reviewer, perf-reviewer) covering"
assert_match "lets plan this" "Resource | prod/staging | Verified-where"

rm -rf "$TMPHOME_E"

# ---------- Phase F: prompts carrying JSON metacharacters — a malformed payload silences the hook, and silence is what a negative assertion wants to see ----------
TMPHOME_F=$(mktemp -d)
mkdir -p "$TMPHOME_F/.claude"
export HOME="$TMPHOME_F"

echo "=== Phase F: prompt metacharacters survive the harness ==="

assert_match 'write an hld for the "billing" service' "DESIGN DOCUMENT"
assert_match 'review the rfc for the "checkout" flow' "DESIGN DOCUMENT"
assert_match 'write an hld for the c\dev service' "DESIGN DOCUMENT"
assert_lacks 'write an hld for the "billing" service' "PLANNING"
assert_no_match 'write a "design doc" parser'

rm -rf "$TMPHOME_F"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
