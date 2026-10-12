# Saved template list regression — build 23

Verified October 5, 2026.

Root cause: the app persisted one custom description, while both selectors enumerated only the static AnswerTemplate cases. Saving never created a list entry.

The preparation and Settings selectors now share a named saved-template collection. Saving selects and persists the entry; editing updates its stable ID. New custom template creates a separate entry. Legacy single descriptions migrate once to My saved template without changing their content. Unsaved new descriptions cannot be used for answers.

Validation:
- `./scripts/check.sh` passed: 224 native tests discovered, 213 passed, 11 opt-in skipped; 2 companion tests passed. Strict release compilation, formatting, secret check and companion packaging passed.
- Four new regression tests cover multiple entries, built-in/saved selection, restart, editing without duplicates, empty rejection, legacy migration, corrupt collection fallback, default names and description length limits.
- Signed installed app is version 0.9.1 build 23.
- Manual installed-app verification: the existing user format appeared as My saved template in the selector alongside both built-ins and New custom template. Switched to a built-in and back, reopened preparation, saved the existing format unchanged, restarted the app and verified the same selected entry and full description. No audio capture, screen capture or live API calls were started. Preparation remains open so the user can review/rename their saved item.
