#!/usr/bin/env bash
# Regression suite for hooks/intent-router.sh — run before every push, not only via bot review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/intent-router.sh"

PASS=0
FAIL=0

run_hook() {
  printf '{"prompt":"%s"}' "$1" | "$HOOK" 2>/dev/null
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
assert_match    "run the review" "PR REVIEW"
assert_match    "trigger the review" "PR REVIEW"
assert_match    "adversarial review" "PR REVIEW"
assert_match    "reviewers" "PR REVIEW"
assert_match    "reviewers?" "PR REVIEW"
assert_no_match "reviewers usually miss this kind of bug"

# Intent 5 — finalize / merge-intent phrasing
assert_match    "finalize" "FINALIZE"
assert_match    "is the pr ready" "FINALIZE"
assert_match    "ready to merge" "FINALIZE"
assert_match    "ship it" "FINALIZE"
assert_match    "ship it!" "FINALIZE"
assert_match    "merge it" "FINALIZE"
assert_match    "merge please" "FINALIZE"
assert_no_match "finalize the naming convention"

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

rm -rf "$TMPHOME_A"

# ---------- Phase B: config present — hard-mandate routing, null/false handling, injection safety ----------
TMPHOME_B=$(mktemp -d)
mkdir -p "$TMPHOME_B/.claude"
jq -n '{
  ticket_system: "ClickUp",
  pr_finalize_skill: "pr-finalize",
  planning_skill: null,
  watch_bot_pattern: "x)|(.*"
}' > "$TMPHOME_B/.claude/intent-router.config.json"
export HOME="$TMPHOME_B"

echo "=== Phase B: config present (hard mandates, null handling, adversarial values) ==="

assert_match    "ship it" "Skill(skill='pr-finalize')"
assert_match    "merged" "ClickUp"
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

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
