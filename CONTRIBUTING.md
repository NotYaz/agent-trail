# Contributing

Agent Trail is an early native macOS app for tracing recent activity across coding assistants. Reports from real multi-profile setups are especially useful.

## Get started

Use macOS 14+ and Swift 6+ from Xcode or the Command Line Tools. From the repository root:

```sh
swift test
./scripts/build-app.sh
swift run AgentTrail --demo
```

The app uses AppKit and SwiftUI; the core and tests are a Swift package. No third-party package dependencies or developer account are required for a local build.

For sample Projects, Growth, and share-card images, render synthetic data directly:

```sh
swift run AgentTrail --render-demo /tmp/agent-trail-projects.png
swift run AgentTrail --render-growth-demo /tmp/agent-trail-growth.png
swift run AgentTrail --render-share-demo /tmp/agent-trail-share.png
```

These commands do not read assistant history or live process-registry data. The README previews use sample images at `docs/assets/demo.png`, `docs/assets/growth.png`, and `docs/assets/share-card.png`. Projects and Growth previews should show the same 600 × 680 floating-panel layout. Renders pin the clock, so they are repeatable; add `--light` to check the light appearance and `--height N` to see content below the fold. Check both appearances for Growth, which is no longer dark-only. `--render-live-demo` remains a compatibility alias for the merged Projects preview; do not add a separate Live-tab screenshot.

The Map has no sample data. To check it against a project, save a snapshot and draw it:

```sh
swift run AgentTrailInspect --map ~/Developer/my-app > /tmp/my-app-map.json
swift run AgentTrailInspect --map-summary /tmp/my-app-map.json --range 7d
swift run AgentTrail --render-map /tmp/my-app-map.json /tmp/my-app-map.png --mode lanes --range 7d
```

`--map PATH` prints the project's session trails, Git history, and live sessions as JSON. `--map-summary SNAPSHOT` prints the lanes, bundles, runs, and commits built from it, for `--range today|7d|30d|all` (default 7d); `--all-branches` turns off bundles and streams. `--render-map SNAPSHOT OUTPUT.png` also takes `--mode lanes|tree|orbit|log`, `--window WxH` to render the Map window's content (640x640 to 4000x4000), `--pin KIND` to pin an item as a click would (live, session, lane, trunk, commit, merge, group, bundle, or fold), `--open-bundles`, `--all-branches`, `--light`, and `--theme NAME`. A snapshot of a real project contains its paths, profile folders, session IDs, branch names, and commit subjects: never commit one, or a render of one, and use synthetic data for any image in the repository. Map tests build synthetic `.git` folders in temporary directories (`GitHistoryTests`) or `GitHistory` values directly (`ProjectMapTests`).

To measure scrolling, run the scroll benchmark from a release build. It opens the panel in a popover, scrolls it one step per display frame, and prints main-thread CPU per frame, frames over the frame budget, late frames, and what an idle open panel spends on live ticks:

```sh
swift build -c release
.build/release/AgentTrail --benchmark-scroll projects --copies 8
.build/release/AgentTrail --benchmark-scroll growth --copies 8
```

`--copies N` repeats the five sample projects, and `--real` reads your own history the way the app does. `--quiet` stops the refresh and live timers for steadier comparisons. `--offscreen` steps on a timer and renders each step itself when no display link runs, for example on a locked screen; only its CPU figures are meaningful. Compare builds on the same Mac with the pointer in the same place, over several runs. Under Instruments, scrolling and idle time appear as points of interest. A card that scrolls into sight is built, measured, and given its AppKit views in a single frame, so keep cards cheap to create: avoid nested `ViewThatFits`, a SwiftUI `Menu` per row, and a timeline per row. Keep cards equatable, so a live tick redraws only the cards whose project changed.

## Make a focused change

Describe the user-visible problem, the proposed behavior, and how you checked it. Keep changes small enough to review. Run `swift test` and a release build before opening a pull request. For interface changes, include a screenshot from demo mode and verify readability in light and dark appearances.

For panel changes, check that project switching clears old graph inspection and that routine background scans do not replace complete history with partial totals. Check graph transitions on both project and period changes: bars start at zero against the target data's actual scale, branches/nodes reveal together, and totals reflect the selected data. Keep transitions quiet and respect macOS Reduce Motion.

Tests should cover behavior and regressions using synthetic fixtures. Never commit real session logs, conversation content, project paths, profile settings, caches, tokens, or signing material. Diagnostic output can contain sensitive paths even when it contains no conversation text.

For project identity changes, use synthetic `.git` folders, links, and moves in temporary directories. Cover parent-folder launches, edits spanning two checkouts, scratch files outside any checkout, a link left after a move and then removed, a plain move followed by bookmark, a new folder at an earlier path, a same-name clone elsewhere, and a repository at the home folder. Never match repositories by name or remote.

For history changes, cover local activity days (05:00 rollover, time zones, DST), sessions assigned to their start day, replayed results, cross-file duplicates, incremental scans, and rebuilding older caches. Keep counts grounded in confirmed tool operations. One successful operation is one edit, not an estimate of changed lines: Claude `Edit`/`Write`, Codex completed `FileChange`, or Grok completed `write`/`search_replace`. Shell commands, failed tools, and user-modified results do not count. Charts must not imply Git ancestry, code quality, or productivity. Compute statistics in `StatsIndex` and test them there; views read precomputed values and never derive statistics in `body`.

For live-status changes, use synthetic registry records, lifecycle events, read-only database fixtures, and injected process/lock checks. Cover Codex loaded versus stale locks, newest-turn selection, Grok permission resolution/cancellation, and profile isolation. Cover explicit `waiting` → Needs input, `busy` → Working, `idle` → Idle, desktop/profile matching, process start verification, PID reuse, dead processes, unknown statuses, and the fallback freshness limit. Claude's registry records reflect status transitions, not a guaranteed heartbeat. Do not infer any status from recent history, CPU usage, or file timestamps, or describe Working as proof of file writes. Idle must not become Needs input because a session has been inactive. Needs input may represent an approval or other dialog/request; do not label every waiting session as a natural-language question.

For combined project cards, cover mixed needs-input/working/idle/unknown sessions, per-profile counts, attention-first then working-first sorting, and the Needs input and Working filters. When both status filters are selected, include either state; search and Shared remain additional constraints. Missing live reports must not become Idle, and live-only projects must not gain fabricated saved history. Keep workspace and report-age details attached to the correct project/profile.

For export changes, preserve local-only PNG saving, names hidden by default, and exclusion of folder paths in every mode. Check the resulting image for private labels and clipping. An anonymized card can still reveal dates, totals, and activity patterns; do not describe it as containing no sensitive information.

Do not add telemetry or network requests to the indexing path. Do not quit, restart, inject into, or modify a running assistant. Focusing an assistant must remain a deliberate user action that identifies a unique instance.

## Add an assistant adapter

`Sources/AgentTrailCore/Models.swift` defines `ActivityProvider`, `ProjectActivity`, and project aggregation. `CompositeActivityProvider` routes each profile by `AssistantKind` and merges projects that share a canonical folder.

A new assistant needs three pieces, and the compiler asks for each one:

1. A case in `AssistantKind` and its `AssistantDescriptor` in `AssistantDescriptor.swift`: name, home folder and its environment variable, how sessions are hosted (desktop app, app or terminal, terminal), the app to focus, whether it reports delegated edits, its in-project worktree folder, and the one-line edit definition Growth shows. Shared code reads these fields where they apply. A few paths still name their assistant, so review them when you add one: Claude Desktop and Codex thread links (`SessionLauncher.jump`), Claude's two-folder process match (`ProcessIdentity.matches`), and Claude's default desktop folder and its message (`ProfileConfiguration.validate`).
2. A `HistoryAdapter`: discover sessions, record evidence as `HistorySession` values, and fold them with `HistoryFold`. `HistoryCache` keeps the versioned per-file cache, and `JSONLTail` reads append-only logs incrementally.
3. An entry in `AssistantRegistry` for the history adapter, and for a live reader if the assistant's live state can be read.

The current readers are:

- `ClaudeActivityProvider` reads desktop session metadata and transcript JSONL. A successful `Edit` or `Write` tool result is one edit. Claude live status stays in `LiveActivityProvider`; `CompositeLiveActivityProvider` routes each assistant to its own runtime reader.
- `CodexActivityProvider` reads `rollout-*.jsonl` under `sessions/` and `archived_sessions/` in the profile’s configured home (default `~/.codex`). A completed `FileChange` item is one edit. The project is `session_meta` `cwd`. Known roots are that cwd plus `runtime_workspace_roots`. A turn cwd outside those roots drops the edit. Do not decompress `.jsonl.zst`, and do not count `apply_patch` unless a completed `FileChange` is present. Do not read `history.jsonl`, `session_index.jsonl`, or SQLite for edit attribution. `CodexLiveActivityProvider` may read turn metadata from SQLite strictly read-only, and only for threads with a current writer handle held by a verified app-server.
- `GrokActivityProvider` reads `summary.json` and the sibling `updates.jsonl` under the profile’s configured home (default `~/.grok`). The project is `info.cwd` and the session id is `info.id`. Do not decode the directory slug. A completed `write` or `search_replace` (`_meta["x.ai/tool"].name`) is one edit when `EditsApplied` paths stay inside that cwd. The update `timestamp` may be ISO-8601 or a Unix number: seconds, or milliseconds when it is at least 13 digits. Do not treat `active_sessions.json` or `signals.json` as edits. `GrokLiveActivityProvider` joins the active registry to explicit lifecycle events, matching the session/profile and exact process birth time; registry presence alone is not a live state.
- `CopilotActivityProvider` reads two stores for one profile. Copilot Chat in VS Code: under the profile's VS Code user-data folder, each `User/workspaceStorage/<hash>/workspace.json` gives the window's folders, `chatSessions/<id>.jsonl` is replayed as VS Code's mutation log (kind 0 snapshot, 1 set, 2 push with optional truncation `i`, 3 delete), and `chatEditingSessions/<id>/state.json` proves which files VS Code applied per request (operations before `timeline.currentEpoch`, not rejected in `recentSnapshot`, not undone by a later request's `editedFileEvents`). One edit tool call naming an applied file is one edit. Remote and folderless windows are skipped. Do not read `state.vscdb`. Copilot CLI: `session-state/<uuid>/events.jsonl` under the Copilot home; a `tool.execution_complete` with `success: true` is one edit, its files from `fileEdits` or the start event's `path` argument; skip `checkpoint` records. `CopilotLiveActivityProvider` accepts an `inuse.<pid>.lock` only while that PID is alive and started before the lock was created, and reads only events written after it.
- `OpenCodeActivityProvider` reads `opencode.db` (and `opencode-<channel>.db`, not `opencode-next.db`) in the profile's OpenCode data folder, or the database file the profile names whatever it is called, through `ReadOnlySQLite`. Recognize each generation by its tables and columns, never by version: 1.x `session`/`message`/`part`, OpenCode 2 `session_v2`/`session_message` with inline `content[]`, plus `session_part` rows. A `tool` item or part in state `completed` is one edit when its tool is `edit`, `write`, `patch`, `multiedit`, or `apply_patch`; take its files from `metadata.files[]`, else `metadata.filepath` or `filediff.file` when absolute, else `input.filePath` (1.x, relative to the message's `path.cwd`) or `input.path` (OpenCode 2, relative to the location at that step). Branch on the recorded keys, not the tool name. Key edits by call id plus completion milliseconds, so forks, imports, and part rows count once. A fork's copied steps (its rows created before the fork) resolve in the folders its parent was in, and its own steps start in the folder it was made in. Extract JSON fields inside SQLite, so tool input and diffs never reach the app. `OpenCodeLiveActivityProvider` accepts `~/.local/state/opencode/service.json` only while its PID is alive and started before the file was written, reads only `pid`, and reports executing sessions as Working, or Needs input when the current step has a running `question` call or an `edit`, `write`, `patch`, or `read` call running for `approvalDelay` (5 seconds): OpenCode keeps approval prompts in memory and stores a call waiting for one like a running call, so elapsed time on these quick calls is the only on-disk sign. Never apply that rule to calls that legitimately run long (shell, subagent, web fetches). `opencode acp`, `--standalone`, and a hand-run `opencode serve` run their own server on the same database, so it hides a turn whose newest `event` row is a `session.execution.interrupted` with reason `shutdown`, reports a turn as Unknown while an `opencode` or `opencode-cli` process run with `serve` but not `--service` that started before the turn is running, and hides a turn seen then once that process is gone.

An adapter should:

- Record evidence exactly as logged: where the session was started, its declared roots, and each confirmed edit's working folder and target parent folders, with symbolic links unresolved. Pass these to `HistoryFold`, which decides at fold time which checkout each edit landed in, where the session belongs, and which earlier locations apply. Never apply containment or location policy while parsing, so caches stay valid when locations are learned. Do not lift a worktree to a parent repository.
- Keep general activity separate from confirmed file-edit evidence. Do not invent Working, Needs input, or Idle from history, CPU, or file timestamps.
- Supply each confirmed edit's time (`editMoments`, with `delegated` when it came from a subagent or spawned thread) and each session's start (`sessionStarts`), alongside the UTC day buckets. Deduplicate replayed and cross-file tool IDs; the moment counts must equal the day-bucket totals.
- Keep the incremental cache free of prompts, commands, patches, diffs, and conversation text. Preserve partial trailing lines, skip oversized lines, and rebuild an unknown cache version.
- Document unsupported operations and format assumptions.
- Surface missing or unreadable data as a profile notice. Do not replace it with guessed authorship.
- Use synthetic fixtures to cover partial writes, malformed records, failed tools, paths outside the project, and incremental indexing. Never commit real session logs, paths, caches, or tokens.

Leave `bundleIdentifier` empty when the assistant has no desktop app to focus. Do not assign Claude's bundle identifier to another assistant. `userDataDirectory` applies to Claude profiles (the desktop data folder) and Copilot profiles (the VS Code user-data folder) only.

Gemini CLI and Cursor stay unsupported until a confirmed local tool-result schema exists. Do not add a parser from directory names, SQLite that has no verified tool-part records, or file modification times.

An mtime alone cannot identify the assistant that made a change. Please open a feature request before a substantial provider or format change so we can agree on evidence and scope.

## Report an issue

Include macOS version, CPU architecture, Agent Trail version or commit, the assistant and its version, and a short reproduction. Replace private paths with fictitious examples. If a screenshot is needed, use `--demo` or redact it carefully.

For a potential vulnerability, follow [SECURITY.md](SECURITY.md). Contributions are made under this repository's [MIT license](LICENSE).
