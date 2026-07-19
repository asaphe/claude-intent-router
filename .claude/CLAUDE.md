# claude-intent-router

Claude Code plugin: `UserPromptSubmit` hook that detects high-confidence
short-phrase intents and injects skill-routing or rigor-checklist context.

## Conventions

- This repo IS the plugin — `.claude-plugin/plugin.json` lives at the root,
  alongside a self-referencing `.claude-plugin/marketplace.json` so it can be
  installed directly with `/plugin marketplace add`.
- No personal-machine paths (`/Users/`, `~/`, `.dotfiles`), personal Google
  Drive references, or hardcoded company-internal identifiers (account IDs,
  tenant IDs, internal service names) — this is meant to be installed by
  anyone, on any machine. Anything person- or project-specific belongs in
  `examples/intent-router.config.example.json` or the user's own
  `~/.claude/intent-router.config.json`, never hardcoded into the hook/agent
  body.
- Run `claude plugin validate .` locally before pushing — there is no CI on
  this repo yet, so nothing else catches a manifest typo.
