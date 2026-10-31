# Security and privacy

Agent Trail is an alpha. Security fixes focus on the latest source revision; no older release line has a separate support commitment.

## Data boundaries

The app reads configured local histories on the Mac: Claude desktop session indexes and JSONL transcripts, Codex rollout JSONL under the profile home (default `~/.codex`), and Grok `summary.json` plus `updates.jsonl` (default `~/.grok`). It does not decompress Codex `.jsonl.zst` archives or treat assistant databases as edit evidence. It writes its own settings and incremental activity caches under `~/Library/Application Support/AgentTrail/`. Claude uses `activity-cache.json`. Codex and Grok use `activity-cache-codex.json` and `activity-cache-grok.json`. It does not change assistant records, install hooks, send telemetry, or upload histories. Assistant focus requests target an identified running Claude instance after a user click. An empty bundle identifier is history only. The app does not launch, quit, kill, or restart assistants.

Live reads local Claude process-registry records and matches them to configured desktop sessions and known workspaces. Codex and Grok profiles are skipped. It checks process liveness and start identity without signalling or modifying the assistant. Registry fields and process IDs are untrusted input. Omit dead/reused processes and sessions that cannot be matched; never turn recent edit history, process lists, or Grok `active_sessions.json` into a live-status claim.

Each cache retains confirmed tool IDs with edit dates and workspace paths, plus file positions and related indexing metadata. They support daily UTC statistics and deduplicate replayed/cross-file results. They do not retain prompts, commands, patches, diffs, or conversation text. Unknown or unreadable cache versions are rebuilt.

Local paths, profile names, tool IDs, and timestamps can reveal private information. An indexing cache or diagnostic report is not automatically safe to publish. Session logs can contain prompts, source code, commands, credentials, and other secrets. Never attach complete real logs to a public issue.

## Live-status limits

Needs input, Working, and Idle are explicit reports from Claude, mapped from `waiting`, `busy`, and `idle`. They do not prove actual file activity or completion. Claude writes reports on status changes rather than a guaranteed heartbeat. A recognized report may remain valid for the same verified running process despite its age. Without verified process-start identity, the fallback requires a report no older than 90 seconds. Unsupported flags, implausibly future-dated reports, and stale fallback reports are Unknown. Report age stays visible to the user; CPU usage, file modification times, and saved history do not establish live status.

Needs input requires an explicit `waiting` report, which can represent an input request, approval, or another dialog/request needing attention. It does not always imply a typed answer. Idle means reported idle/ready for the next prompt, not proof of an unanswered request; elapsed inactivity must not create an input request. Live status does not inspect question, approval, or request text.

Project cards combine history and reported live sessions without treating one as evidence for the other. A missing live report is not Idle. A project present only in live reports must not gain invented edit/session history. Mixed needs-input/working/idle/unknown counts remain separate, including by profile.

Project cards and expanded live details can show private project/workspace paths, profile names, process IDs, and report times. Use sample mode for public images; do not publish real registry records or unredacted project screenshots.

## Activity images

Growth visualizes available local records; the tree is not Git ancestry and its counts do not measure code quality or lines of code. Edit counts come from confirmed file edits by UTC day: Claude `Edit`/`Write`, Codex completed `FileChange`, and Grok completed `write`/`search_replace`. Sessions are grouped by their UTC creation day. Missing logs, shell commands, and external changes can leave the history incomplete.

PNG export saves only to a user-selected local location and never posts or uploads a card. The Share action hides project/profile names and excludes folder paths. Totals, dates, and activity patterns remain visible. Review an image before sharing it.

`--demo`, `--render-demo`, `--render-growth-demo`, and `--render-share-demo` use synthetic sample data rather than reading local assistant history or process-registry records. The older `--render-live-demo` flag is an alias for the combined Projects preview. Use these modes for public screenshots. Screenshots of the ordinary app may contain private project names and paths.

## Input and distribution

The alpha uses private on-disk formats. Treat records and process information as untrusted input. Unknown data must not result in guessed authorship or arbitrary application activation. Distributed alpha bundles are ad-hoc signed, without Developer ID signing or Apple notarization.

## Report a vulnerability

On GitHub, use **Security → Advisories → Report a vulnerability** when private reporting is enabled. Include the affected revision, a minimal reproduction with synthetic records, and the impact. Do not include live tokens, private conversations, or complete histories.

If private reporting is unavailable, open an issue that only requests a private contact channel. Keep the vulnerability details and sensitive data out of that public request. There is no published response-time guarantee during the alpha.

For an ordinary parsing or compatibility bug, use the issue template with redacted examples. See [CONTRIBUTING.md](CONTRIBUTING.md) for fixture guidance.
