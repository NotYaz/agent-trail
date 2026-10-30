# Changelog

## 0.1.0-alpha.2 — 2026-10-30

- Projects, Live, and Growth now share one 600 × 680 menu-bar panel.
- Live tab shows Claude Desktop's reported Working, Idle, or Unknown state, matched to configured profiles and desktop sessions. Process identity checks preserve status-change reports for the same running process; records without a verified process start use a 90-second freshness fallback. Dead/reused processes are omitted.
- Live reports show their age and remain separate from recorded-edit history. A reported busy state does not claim that a file is being written.
- Switching Growth projects resets graph inspection and keeps node identity aligned with the selection.
- Routine refreshes preserve the last complete history while indexing, preventing partial totals and chart flicker.
- Gentle tab/update transitions respect macOS Reduce Motion.
- Updated synthetic panel previews and added direct Live demo-image rendering.

Claude Desktop remains the only supported assistant; Codex and Grok adapters are not implemented. Donations remain unconfigured. Existing edit-attribution and distribution limitations still apply.

## 0.1.0-alpha.1 — 2026-10-30

Initial alpha prepared for public release.

- Native menu-bar panel with search, shared-project filtering, worktree context, and quick focus for identified running Claude instances.
- Separate indicators for successful recorded `Edit`/`Write` operations and general saved activity.
- Growth window with an activity tree, daily edit chart, session totals, and project plus 7/30/90-day or all-history filters.
- PNG activity portraits saved locally, with project/profile names hidden by default and no folder paths or automatic posting.
- Daily counts per agent profile: confirmed edits by UTC day and saved sessions by UTC creation day.
- Incremental local indexing with a version 2 metadata cache, replay/cross-file tool-result deduplication, and profile notices. Older caches rebuild once for daily statistics.
- Configurable Claude profiles and refresh interval.
- Demo mode with synthetic projects, plus direct Growth/share-card image rendering for previews.
- MIT license, contribution and security guidance, and macOS test/build workflows.
- Architecture-specific and universal2 bundle packaging with ZIP checksums and ad-hoc signatures.

Known limits: Claude Desktop only; shell and external edits are not attributed; focus does not navigate to an exact project or conversation. The activity tree is a visual summary, not Git ancestry or a measure of lines of code, code quality, or productivity. No global hotkey, launch-at-login item, Developer ID signing, or notarization yet. Claude's private local formats can change.
