# Changelog

## 0.1.0-alpha.1 — 2026-10-30

Initial alpha prepared for public release.

- Native menu-bar panel with search, shared-project filtering, worktree context, and quick focus for identified running Claude instances.
- Separate indicators for successful recorded `Edit`/`Write` operations and general saved activity.
- Incremental local indexing with a metadata-only cache and profile notices.
- Configurable Claude profiles and refresh interval.
- Demo mode with synthetic projects for safe previews.
- MIT license, contribution and security guidance, and macOS test/build workflows.
- Architecture-specific and universal2 bundle packaging with ZIP checksums and ad-hoc signatures.

Known limits: Claude Desktop only; shell and external edits are not attributed; focus does not navigate to an exact project or conversation. No global hotkey, launch-at-login item, Developer ID signing, or notarization yet. Claude's private local formats can change.
