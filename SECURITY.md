# Security and privacy

Agent Trail is an alpha. Security fixes focus on the latest source revision; no older release line has a separate support commitment.

## Data boundaries

The app reads configured local histories on the Mac: Claude desktop session indexes and JSONL transcripts, Codex rollout JSONL under the profile home (default `~/.codex`), and Grok `summary.json` plus `updates.jsonl` (default `~/.grok`). It does not decompress Codex `.jsonl.zst` archives or treat assistant databases as edit evidence. It writes its own settings and incremental activity caches under `~/Library/Application Support/AgentTrail/`. Claude uses `activity-cache.json`. Codex and Grok use `activity-cache-codex.json` and `activity-cache-grok.json`. It does not change assistant records, install hooks, send telemetry, or upload histories. After a user click, it opens a session link (Claude's `claude://code/continue`, Codex's `codex://threads/<id>`) or brings an already running app forward. Link ids are validated before use, and links go only to a running app. With several Claude instances it brings the identified instance forward first and sends the link only once that instance is frontmost; otherwise it shows a hint instead. The app does not launch, quit, kill, or restart assistants, and it uses no Automation or Accessibility permission. Live session titles, Claude's needs-action sentence, and pull request links are read from local records for display only: they stay in memory and are never cached, exported, or logged.

Live reads Claude process-registry records matched to desktop sessions; Codex app-server writer-handle presence and read-only turn metadata; and Grok active-session registry plus explicit lifecycle events matched to the exact PID start. These readers do not signal or modify assistants. Registry fields, database rows, paths, and process IDs are untrusted input. Omit dead/reused processes and sessions that cannot be matched. A recent edit, a leftover lock file, or registry presence alone must not create a live-status claim.

Each cache retains confirmed tool IDs with edit dates and workspace paths, plus file positions and related indexing metadata. They support daily statistics, computed in memory on local activity days, and deduplicate replayed/cross-file results. The Codex and Grok caches also keep the parent folders of edited files, and the Claude cache can briefly keep the target path of an Edit or Write awaiting its result. They do not retain prompts, commands, patches, diffs, or conversation text. Unknown or unreadable cache versions are rebuilt.

Local paths, profile names, tool IDs, and timestamps can reveal private information. An indexing cache or diagnostic report is not automatically safe to publish. Session logs can contain prompts, source code, commands, credentials, and other secrets. Never attach complete real logs to a public issue.

## Live-status limits

Claude Needs input, Working, and Idle map from explicit `waiting`, `busy`, and `idle` reports. They do not prove actual file activity or completion. Claude writes reports on status changes rather than a guaranteed heartbeat. A recognized report may remain valid for the same verified running process despite its age. Without verified process-start identity, the fallback requires a report no older than 90 seconds. Unsupported flags, implausibly future-dated reports, and stale fallback reports are Unknown. Report age stays visible to the user; CPU usage, file modification times, and saved history do not establish live status.

Claude Needs input requires an explicit `waiting` report, which can represent an input request, approval, or another dialog/request needing attention. It does not always imply a typed answer. Idle means reported idle/ready for the next prompt, not proof of an unanswered request; elapsed inactivity must not create an input request. Live status does not use question, approval, or request text to classify a session.

Codex Working means a loaded thread has an explicit in-progress turn; completed/interrupted/failed turns are Idle. Codex input dialogs cannot currently be distinguished. Grok Working and Idle follow lifecycle events; unresolved explicit permission requests become Needs input. Missing or unsupported lifecycle evidence is Unknown. Live cursors stay in memory; request text is not persisted.

Project cards combine history and reported live sessions without treating one as evidence for the other. A missing live report is not Idle. A project present only in live reports must not gain invented edit/session history. Mixed needs-input/working/idle/unknown counts remain separate, including by profile.

Project cards and expanded live details can show private project/workspace paths, profile names, process IDs, and report times. Use sample mode for public images; do not publish real registry records or unredacted project screenshots.

## Activity images

Growth visualizes available local records; its charts are not Git ancestry and its counts do not measure code quality, lines of code, or productivity. Edit counts come from confirmed file edits on local activity days, which start at 05:00 in the Mac's time zone: Claude `Edit`/`Write`, Codex completed `FileChange`, and Grok completed `write`/`search_replace`. Sessions are grouped by the day they started. The hour-of-day rhythm is shown in the app only. Missing logs, shell commands, and external changes can leave the history incomplete.

PNG export saves only to a user-selected local location and never posts or uploads a card. Project and profile names are hidden by default and can be included with a toggle; folder paths and the hour-of-day rhythm are never included. Totals, dates, and day patterns in the mini calendar remain visible. Review an image before sharing it.

`--demo`, `--render-demo`, `--render-growth-demo`, and `--render-share-demo` use synthetic sample data rather than reading local assistant history or process-registry records. The older `--render-live-demo` flag is an alias for the combined Projects preview. Use these modes for public screenshots. Screenshots of the ordinary app may contain private project names and paths.

## Input and distribution

The alpha uses private on-disk formats. Treat records and process information as untrusted input. Unknown data must not result in guessed authorship or arbitrary application activation. Distributed alpha bundles are ad-hoc signed, without Developer ID signing or Apple notarization.

## Report a vulnerability

On GitHub, use **Security → Advisories → Report a vulnerability** when private reporting is enabled. Include the affected revision, a minimal reproduction with synthetic records, and the impact. Do not include live tokens, private conversations, or complete histories.

If private reporting is unavailable, open an issue that only requests a private contact channel. Keep the vulnerability details and sensitive data out of that public request. There is no published response-time guarantee during the alpha.

For an ordinary parsing or compatibility bug, use the issue template with redacted examples. See [CONTRIBUTING.md](CONTRIBUTING.md) for fixture guidance.
