# Changelog

## Unreleased

- A project is now the Git checkout where confirmed edits landed. Each Claude, Codex, or Grok edit counts for the checkout containing its files after following links. A session started in a parent folder joins that checkout when its edits landed in exactly one, and its card shows **Launched from**. Edits spanning several checkouts are not merged, and repositories are never matched by name or remote.
- Moved repositories keep their history. A link left at the old path is remembered, so removing it later changes nothing. A plain move on the same disk is followed through a bookmark and folder identity. A move never seen can be fixed once with **Locate…**. Cards show **Previously at** and offer **Forget earlier locations…**.
- A new folder at an earlier location stays a separate project; only records made before it appeared count for the moved one. A repository at the home folder or above it is never treated as a project.
- Codex helper threads with no repository edits of their own join their parent thread's project when started in the same folder.
- Live Codex and Grok sessions started outside a project appear on the project their edits landed in. Claude windows still reporting a moved folder appear at its new location.
- Files written outside any checkout stay on the folder the session was started in. Edits under a vanished folder are reported with a **Locate…** action.
- Search matches earlier locations and launch folders. Live session rows say Worktree, Subfolder, or Launched outside instead of calling every other folder a worktree.
- New `project-locations.json` (mode 0600) stores paths, bookmarks, and folder identity only. Codex and Grok caches rebuild once as version 4 and now keep recorded evidence, so learned locations never require reparsing logs. The Claude cache is unchanged.
- `AgentTrailInspect` reports learned locations, re-homed sessions, and missing folders, and accepts `--locations`.
- Fixed a folder-walk loop that could exhaust memory for paths outside every repository in the unreleased resolver.

## 0.1.0-alpha.6 — 2026-10-31

- Live Codex status joins verified app-server thread-writer handles to explicit turn metadata, opened read-only. Loaded in-progress turns show Working; ended turns show Idle. Leftover lock files and unloaded historical turns do not create live sessions. Codex approval/input dialogs cannot yet be distinguished from an in-progress turn.
- Live Grok status joins registered sessions to explicit lifecycle events and verifies the exact PID birth time. Active turns show Working, ended/cancelled turns show Idle, and unresolved permission requests show Needs input. Registry presence without recognized lifecycle evidence remains Unknown.
- All three assistants share the Projects view, per-profile live counts, attention filters, and workspace/report-age details. Claude focus remains available; Codex/Grok do not gain a misleading focus button by default.
- Daily edits gets a taller plot, at most four compact Y-axis labels, lighter guides, a wrapping profile legend, and selected-day focus. Existing chart/number transitions and Reduce Motion remain supported.
- Profile colors stay consistent across Projects, Growth, and exported portraits. Synthetic previews now include four profiles across Claude, Codex, and Grok.
- Published optional GitHub Sponsors and Buy Me a Coffee funding links. No crypto addresses are configured.
- Added read-only `AgentTrailInspect --live` diagnostics, without scanning edit history.

These runtime formats are private and version-dependent. No assistant is launched, stopped, or modified. Builds remain ad-hoc signed and unnotarized.

## 0.1.0-alpha.5 — 2026-10-31

- Recorded local history from Codex and Grok, merged with Claude when the canonical project folder is the same.
- Codex counts one completed `FileChange` item as one edit. The project is the session `cwd`. A turn counts only inside that session's known roots. Shell commands, `apply_patch` without a completed `FileChange`, and compressed `.jsonl.zst` archives are not counted.
- Grok counts one completed `write` or `search_replace` as one edit. The project path is `summary.json` `info.cwd`; the encoded session-directory name is not decoded. Update timestamps may be ISO-8601, Unix seconds, or Unix milliseconds. A missing `updates.jsonl` still lists the session and reports that edit history is unavailable.
- Profiles gain an `assistant` field (`claude`, `codex`, or `grok`). Older files without that field stay Claude. A saved `profiles.json` is not rewritten; add Codex and Grok from Profiles, or edit the file and reload. New defaults apply only when the settings file is absent.
- Codex and Grok profiles omit desktop user data. An empty bundle identifier means history only and does not focus an app. Claude's bundle identifier is rejected on those profiles.
- Live status and one-click focus remain Claude Desktop. Codex and Grok homes are not read as Claude registries, and `active_sessions.json` is not a live status.
- Separate incremental caches: `activity-cache-codex.json` and `activity-cache-grok.json`, beside the existing Claude cache. They keep tool IDs, dates, and paths, and do not store prompts, commands, patches, diffs, or conversation text.
- Added Needs input for Claude's explicit `waiting` registry status, distinct from reported Idle. The signal can represent an input request, approval, or another dialog/request needing attention.
- Project cards show needs-input counts in total and by profile alongside working/idle/unknown counts. One shared project can show a waiting session and a working session at the same time.
- Projects needing input sort first, followed by working projects. An amber header count and Needs input filter surface those reports. Selecting Needs input and Working now together includes either state while preserving search/Shared only constraints.
- Idle means reported idle/ready for the next prompt; it does not imply an unanswered request. Inactivity and edit history never create a needs-input state.
- Needs-input reports use the existing profile/session matching, process verification, and freshness checks. Local polling, privacy boundaries, and Claude lifecycle behavior are unchanged.
- Review fixes isolate custom scan caches, preserve unscanned assistants during indexing, validate Codex move destinations and worktree roots, and require positive Grok edit results. Adapter caches rebuild once as version 2.
- Oversized JSONL records are skipped before parsing, including records ending just beyond the size boundary.

Gemini CLI, OpenCode, and Cursor remain unsupported. Donation addresses remain unconfigured. Shell attribution, hotkey, launch-at-login, and notarization are unchanged.

## 0.1.0-alpha.3 — 2026-10-30

- Combined project history and live session state in the Projects tab. Cards show working/idle/unknown counts in total and by profile, with expandable workspace and last-report details.
- Projects with reported working sessions sort first; the Working now filter can combine with search and Shared only.
- Historical projects without live reports remain distinct from idle projects. Live-only projects appear without fabricated edit/session history.
- Projects and Growth are now the two tabs in the same 600 × 680 panel. The former Live preview command remains an alias for the merged Projects view.
- Project/period changes draw Growth branches outward, reveal activity nodes, and grow bars from zero using the actual data scale. Totals stay synchronized with the selection; Reduce Motion disables the growth animation.
- Updated synthetic Projects/Growth previews and removed the separate Live preview image.

Live polling and process verification are unchanged: local checks every 3 seconds, explicit Claude status reports, verified process identity, and the 90-second fallback for unverifiable starts. Claude Desktop remains the only supported assistant, and donations remain unconfigured.

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
