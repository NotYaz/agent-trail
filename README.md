# Agent Trail

**Which agent touched this project last?**

A small native macOS menu-bar app that brings your coding projects into one place. See recorded edits and reported live status together on each project, then jump back to the right running app. Projects and Growth share one compact floating panel.

**0.1.0-alpha.6 · Public alpha · macOS 14+ · Claude, Codex, and Grok · MIT license**

Agent Trail reads local history and live status from Claude Desktop, Codex, and Grok. One-click focus is available for identified Claude Desktop instances. Gemini CLI, OpenCode, and Cursor are not supported.

<img src="docs/assets/demo.png" width="600" alt="Agent Trail Projects tab showing synthetic projects with live session counts, recorded edits, and quick-focus buttons">

*Sample data. Project names, profiles, paths, and counts in these previews are synthetic.*

## Why it exists

Two assistant instances. The same project open in both. Different worktrees, conversations, and changes. Returning to work should not begin with guessing which window has the latest context.

Agent Trail shows each project once, bringing its reported live sessions together with the **last recorded edit** and **latest saved activity** where history is available. A project is the Git checkout where an assistant's confirmed edits actually landed, so Claude, Codex, and Grok working in the same repository share one card even when they were started in different folders. A Claude worktree stays connected to that original folder, and a repository you move keeps its history.

- Search by project path or profile name.
- Filter to projects shared across profiles.
- See worktree context alongside recorded edits, and where a session was started when that was outside the project.
- Keep a project's history when you move its folder; earlier locations are remembered automatically.
- Focus an identified running Claude instance with one click. Codex and Grok profiles show local activity without an app-focus button by default.
- See live Needs input, Working, Idle, and Unknown counts inside each project card.
- Projects needing input sort first, followed by working projects; filter with **Needs input** or **Working now**.
- Explore an activity tree and daily edit/session counts by project and agent profile.
- Export a PNG activity portrait with project and profile names hidden by default.
- Keep everything local, with no account or telemetry.

<img src="docs/assets/growth.png" width="600" alt="Agent Trail Growth tab showing an activity tree and daily recorded-edit chart from synthetic sample projects">

## Try it

Build from source with **Swift 6+**, using Xcode or the Command Line Tools, on macOS 14 or later:

```sh
swift test
./scripts/build-app.sh
open "dist/Agent Trail.app"
```

Run these commands from the repository folder. The app opens its panel immediately and keeps a connected-dots icon in the menu bar, with no Dock icon. Switch between **Projects** and **Growth** inside the same 600 × 680 panel. Click away to hide it; click the icon to return. The first history scan runs in the background. Later history scans are incremental, every 15 seconds by default; live status checks run separately every 3 seconds.

Routine refreshes keep the last complete history visible while the next scan finishes. Tab changes and updates use gentle transitions that respect macOS Reduce Motion.

To install, copy `dist/Agent Trail.app` to your Applications folder. The script also creates an architecture-labeled ZIP and SHA-256 checksum in `dist/`. These alpha builds use an **ad-hoc signature** and are **not Apple-notarized**. A downloaded build may be blocked by Gatekeeper. Building locally is the supported starting point for this alpha; see Apple's [guidance for opening apps safely](https://support.apple.com/en-us/102445).

Claude profile buttons focus an existing Claude Desktop instance. They do not open a particular project or conversation. Codex and Grok profiles show local history and runtime status; an empty bundle identifier means there is no desktop app configured for focus. Agent Trail does not launch, quit, kill, or restart an assistant.

## Configure profiles

Open **Profiles…** from the panel's bottom menu to add or adjust profiles. When `profiles.json` is missing, the default configuration is:

| Profile | Assistant | Home | Desktop user data |
| --- | --- | --- | --- |
| Claude · Main | `claude` | `~/.claude` | Claude's default user-data location |
| Claude · Second | `claude` | `~/.claude-second` | `~/Library/Application Support/Claude-Second` |
| Codex | `codex` | `~/.codex` | none |
| Grok | `grok` | `~/.grok` | none |

Custom `CODEX_HOME` or `GROK_HOME` launch variables do not change history-scanning defaults; set each profile’s `configDirectory` to that custom home.

A settings file that already exists is left as it is. Add Codex and Grok from **Profiles…**, or add the entries below and choose **Reload profiles**. Agent Trail does not merge new default profiles into a saved file.

Settings are stored at `~/Library/Application Support/AgentTrail/profiles.json`. This example shows the file structure:

```json
{
  "refreshInterval": 15,
  "sources": [
    {
      "id": "claude-primary",
      "name": "Claude · Main",
      "assistant": "claude",
      "configDirectory": "~/.claude",
      "bundleIdentifier": "com.anthropic.claudefordesktop"
    },
    {
      "id": "claude-second",
      "name": "Claude · Second",
      "assistant": "claude",
      "configDirectory": "~/.claude-second",
      "userDataDirectory": "~/Library/Application Support/Claude-Second",
      "bundleIdentifier": "com.anthropic.claudefordesktop"
    },
    {
      "id": "codex",
      "name": "Codex",
      "assistant": "codex",
      "configDirectory": "~/.codex",
      "bundleIdentifier": ""
    },
    {
      "id": "grok",
      "name": "Grok",
      "assistant": "grok",
      "configDirectory": "~/.grok",
      "bundleIdentifier": ""
    }
  ]
}
```

Use unique, stable `id` values. A profile saved before `assistant` existed still loads as Claude. Each Claude profile needs its config directory and the matching desktop user-data folder. Only the main `~/.claude` profile may omit the desktop folder to use Claude's default. Codex and Grok profiles must omit `userDataDirectory`. Leave `bundleIdentifier` empty unless that assistant has its own app, and do not reuse Claude's bundle identifier. Set `refreshInterval` between 5 and 300 seconds. A complete [example configuration](docs/profiles.example.json) is included. Choose **Reload profiles** after editing this file by hand. Invalid settings are reported instead of silently scanning another configuration.

Claude instance matching uses the bundle identity, process arguments, and `CLAUDE_CONFIG_DIR`. Codex and Grok homes match `CODEX_HOME` and `GROK_HOME` when those variables are set, and the default `~/.codex` or `~/.grok` when they are not. Matching a home does not focus a CLI process. An outlined profile dot means a unique running instance could not be identified. When identity is ambiguous or unavailable, Agent Trail reports the problem.

## What the timestamps mean

| Label | Evidence |
| --- | --- |
| **Last recorded edit** | The newest confirmed file edit. Claude counts a successful `Edit` or `Write`. Codex counts one completed `FileChange` item. Grok counts one completed `write` or `search_replace`. |
| **Latest activity** | The newest saved session activity, including work that may not change a file. |
| **Shared** | More than one configured profile worked in the same project, including across assistants. |

**This is a record of supported agent activity, not a complete audit of file changes.** Shell commands, external editors, unsupported assistants, and unrecorded changes are not attributed. Failed tools and user-modified results are excluded. A project with no recorded edits may still have changed. File modification times, directory names, and process lists do not establish which assistant made a change.

Codex history is read from rollout JSONL files under `~/.codex/sessions` and `archived_sessions` (or the custom home set in `configDirectory`). The session `cwd` is where it was started. A later turn counts only when its working folder stays inside that session's declared roots. One completed `FileChange` is one edit even when it lists several files, and it counts for the project its files landed in (see below). A helper thread with no repository edits of its own joins its parent thread's project when both were started in the same folder. Compressed `.jsonl.zst` archives are left unread. Older rollouts that record only `apply_patch`, without a completed `FileChange`, are not counted.

Grok history uses `summary.json` under `~/.grok/sessions` (or the custom home set in `configDirectory`). The session was started in `info.cwd`. The encoded session-directory name is not decoded into a path. Completed `write` and `search_replace` calls in the sibling `updates.jsonl` count as one edit each, and a positive `SearchReplace.EditsApplied` result must identify the files, which count for the project they landed in (see below). The edit time is the update timestamp: an ISO-8601 string, Unix seconds, or Unix milliseconds. A session with no `updates.jsonl` still appears, with a notice that its edit history is unavailable. The active-session registry alone does not establish a live state.

These on-disk formats are private implementation details and can change without notice. Missing or unreadable data appears as a profile notice. This alpha has not been tested against every assistant version or installation layout.

## When a project moves, or an assistant starts elsewhere

Assistants are often started in one folder and work in another. Codex may start in its own output folder and write into a repository below it. A folder may be moved after an assistant has already worked in it. Agent Trail keeps one card for the repository in both cases.

- **Edits count where they landed.** Each confirmed edit counts for the Git checkout that contains its files, after following symbolic links. A session started in a parent folder belongs to that checkout when its edits landed in exactly one. Its card then shows **Launched from · <folder>**.
- **Files outside any checkout stay where they were written.** Notes or drafts an assistant saved next to a repository count on the folder it was started in, not on the repository.
- **Edits spanning several checkouts are not merged.** Each edit still counts for its own checkout, and the session stays with the folder it was started in. Repositories are never matched by name or remote.
- **A link left behind is remembered.** After `mv old new && ln -s new old`, edits recorded under `old` count for `new` right away. Agent Trail remembers the earlier path, so deleting the link later changes nothing. The card shows **Previously at · <old path>**.
- **A plain move is followed.** Agent Trail keeps a bookmark and folder identity for every repository it has attributed work to. If one is moved on the same disk, its history follows it on the next scan.
- **Otherwise, locate it once.** A repository moved to another disk shows **Folder not found**. A repository moved before Agent Trail ever saw it shows *N edits in a folder that no longer exists*. Choose **Locate…** and pick the folder where it lives now. The folder must contain the project's `.git` folder; for missing edits it must also contain the recorded subfolders. An existing folder is never claimed as another folder's earlier location.
- **A new folder at an old path is its own project.** If something else appears at an earlier location, only records made before it appeared still count for the moved project.

Search also matches earlier locations and launch folders. **Forget earlier locations…** in the project menu removes them. Only Git metadata (`HEAD`, `commondir`, `gitdir`) is read to recognize a repository, and a repository at your home folder or above it is never treated as a project.

## Check live status on a project

Live status is available for Claude Desktop, loaded Codex threads, and registered Grok sessions. Each adapter requires runtime presence and explicit status or turn events; recent edits and file timestamps do not establish a live state.

The **Projects** tab shows live session counts directly inside each project card, both in total and by profile. Projects with a reported input request sort first, followed by projects with working sessions. The header shows needs-input counts in amber and working counts in green. Use **Needs input** or **Working now** to filter those projects. Selecting both includes projects with either state; search and **Shared only** still apply.

Expand a card's live details with the chevron to see each session's recorded workspace, worktree context, and last-report age. Sessions are matched to your configured assistant homes. Claude requires a matching desktop session; Codex requires a thread-writer handle held open by a verified app-server; Grok requires a registered session with a matching process start. Unmatched sessions are omitted.

A session started outside a project joins the project its recorded edits landed in, so a Codex thread started in a parent folder appears on the repository's card. A Claude window still reporting a folder that has moved appears at the folder's current location.

A project can have a session needing input while another is working or idle, so the card keeps separate counts instead of hiding them behind one state. **No live sessions reported** does not mean idle. Projects found only through live reports still appear, without inventing saved sessions or edit history for them.

| Status | Meaning |
| --- | --- |
| **Needs input** | Claude reported `waiting`, or Grok reported an unresolved permission request. Codex input dialogs are not distinguished by the currently available state. |
| **Working** | Claude reported `busy`, Codex has an `inProgress` turn on a loaded thread, or Grok has an active turn/working phase. |
| **Idle** | Claude reported `idle`, or a loaded Codex/Grok session explicitly ended its turn. It does not establish that you need to reply. |
| **Unknown** | The status is unrecognized or cannot be verified under the applicable freshness checks. |

Claude writes these registry reports when status changes, rather than sending a regular heartbeat. A waiting, busy, or idle report can remain valid while the same verified process is alive, even when the report is old. Agent Trail shows that report's age. If the process start cannot be verified, the fallback accepts only reports from the last 90 seconds; older reports become Unknown. Unrecognized or implausibly future-dated reports are also Unknown. Dead processes and reused process IDs are omitted.

**Needs input requires an explicit request.** Claude uses its waiting signal for input requests, approvals, and other dialogs needing attention; Grok records permission requests. Inactivity and old activity dates do not turn Idle into Needs input. Request text is not retained. Check the corresponding assistant to respond.

Codex live status combines open thread-writer handles under `thread-writer-locks/` with the newest turn status in `thread_history_1.sqlite`, opened read-only. A leftover lock file or an old `inProgress` row without a verified app-server holding its writer handle is insufficient. Codex does not persist a distinct approval/input state in the inspected schema, so an in-progress turn can include time spent waiting for you. Its workspace is the recorded thread workspace; individual tool working directories are not separately tracked.

Grok live status joins `active_sessions.json` to the matching session summary, verifies the registered PID and microsecond process-start time, and reads explicit lifecycle events from `events.jsonl`. A registered session without a recognized event is Unknown. Completed and cancelled turns become Idle; permission requests become Needs input until resolved.

**Working describes a reported active turn.** It does not claim that a file is being written or that work has succeeded. Recent edits, file modification times, and CPU usage do not determine live status. Missing live reports do not establish that every assistant has stopped.

## Explore project activity

Choose the **Growth** tab in the floating panel. Select a project or **All projects**, then filter to **7D**, **30D**, **90D**, or **All**. The activity tree, daily edit chart, and session totals show how the available records accumulate across agent profiles. Explore a tree node to inspect its recorded day. Changing projects clears the previous graph's inspection so the labels and selected project stay aligned.

Project and period changes animate branches outward, bring in activity nodes, and grow chart bars from zero against the selected data's actual scale. Totals update with the same selection. Reduce Motion shows the result without the growth animation.

- **Recorded edits** count confirmed file edits, grouped by UTC calendar day and agent profile. Claude counts a successful `Edit` or `Write`. Codex counts one completed `FileChange`. Grok counts one completed `write` or `search_replace`. One tool operation counts as one edit, regardless of its size. Shell commands do not count.
- **Saved sessions** are counted on their creation day in UTC. They are not the number of sessions active on each day.
- Replayed tool results and repeated records across transcript files are deduplicated within each project's profile history.

The tree connects activity over time as a visual summary. It does not show Git ancestry, dependencies between agents, or lines of code. Edit/session counts do not measure code quality, project size, or productivity. Shell and external changes remain outside these statistics, and missing logs mean the history may be incomplete. Day boundaries use UTC even when your Mac uses another time zone.

## Export an activity portrait

From Growth, choose **Share**, then **Export PNG** in the save dialog to save the card to a location on your Mac. The card uses the selected projects and time period. The Share action hides project and profile names, using labels such as “My project” and “Agent 1.” Folder paths are never included in the card. Activity totals and dates remain visible.

<img src="docs/assets/share-card.png" width="700" alt="Sample exported Agent Trail activity portrait with anonymized agent names and synthetic activity counts">

*Sample portrait. Export saves a local PNG; it does not post or upload anything.*

Review a card before sharing it. Hiding names does not hide dates, counts, or patterns of activity.

## Privacy

Indexing happens on your Mac. Agent Trail reads Claude desktop session indexes and JSONL logs, Codex rollout JSONL files, and Grok `summary.json` plus `updates.jsonl`. It does not decompress Codex archives or read assistant databases for edits. Live status reads Claude process-registry records, Codex app-server writer-handle presence and read-only turn metadata, and Grok process-registry/lifecycle events. These checks do not write assistant data or infer status from recent edits. The app does not send those records anywhere, inject code, install hooks, or edit assistant data. There are no telemetry, cloud accounts, or automatic update checks.

Incremental caches live under `~/Library/Application Support/AgentTrail/`: `activity-cache.json` (Claude, version 2), `activity-cache-codex.json` (version 4), and `activity-cache-grok.json` (version 4). They store file positions, tool IDs, confirmed-edit dates, project/workspace paths, the parent folders of edited files, and related indexing metadata. Confirmed tool IDs retain their date and workspace so daily totals survive incremental scans and replayed results can be deduplicated. The caches do not store prompts, commands, patches, diffs, or conversation text. Paths and timestamps can still be sensitive; keep caches and diagnostic output private. An unreadable or unknown cache version is rebuilt. With Agent Trail closed, deleting a cache causes a fresh index of that assistant on the next launch.

`project-locations.json` (mode 0600) in the same folder remembers repositories Agent Trail attributed work to. It holds their current and earlier folder paths, which are learned from session evidence, plus a macOS bookmark and folder identity: device, inode, and creation date. It holds no prompts, commands, diffs, or conversation text, but the paths can still be sensitive; keep it private like the caches. An unreadable file is reported and never overwritten. With Agent Trail closed, deleting it forgets learned earlier locations; links still present are learned again.

External links in the app open in your browser only when selected. See [security and reporting](SECURITY.md) before sharing an issue or diagnostic output.

## Preview with sample projects

```sh
swift run AgentTrail --demo
```

Demo mode uses synthetic projects and live states. It does not read Claude histories, process-registry records, your profile configuration, or the activity cache. It is suitable for screenshots and walkthroughs. Quit the demo from its menu when finished.

Render sample images directly to files without reading your assistant history:

```sh
swift run AgentTrail --render-demo /tmp/agent-trail-projects.png
swift run AgentTrail --render-growth-demo /tmp/agent-trail-growth.png
swift run AgentTrail --render-share-demo /tmp/agent-trail-share.png
```

The older `--render-live-demo` flag remains an alias for the combined Projects preview.

## Development

There are no third-party package dependencies. The Swift package includes the native app, a reusable core, tests, and a diagnostic CLI.

```sh
# Build for a specific CPU, or create a universal binary.
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64 --output-dir dist/intel
./scripts/build-app.sh --arch universal2 --output-dir dist/universal

# Preview local metadata without storing a scan cache.
swift run AgentTrailInspect --metadata-only

# Read current runtime status without scanning edit history.
swift run AgentTrailInspect --live

# Show learned project locations and which sessions joined another project.
# Reads project-locations.json (or the --locations file) and never writes it.
swift run AgentTrailInspect --locations ~/Library/Application\ Support/AgentTrail/project-locations.json
```

Each build creates `Agent Trail.app`, `Agent-Trail-macOS-<architecture>.zip`, and a matching `.sha256` file in the selected output folder. Architecture-specific ZIPs run on that architecture; `universal2` contains both arm64 and x86_64. Cross-architecture compilation does not validate execution on the other architecture.

`ARCH` can set the build architecture and `AGENTTRAIL_BUILD_DIR` can select a separate Swift build cache. The build script does not install or launch apps. Inspection reads your real local data and can print project paths; review its output before sharing. The CLI uses saved profiles (or defaults if settings are absent). Pass `--profiles /path/to/profiles.json` to inspect a separate configuration.

CI runs tests and packages the app on Apple Silicon and Intel macOS runners. The manually triggered **Release artifacts** workflow produces ZIPs and checksums for review; it does not publish a release or upload code to another repository. Runner labels follow GitHub's [hosted runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance. New adapters should translate supported records into `ProjectActivity` through `ActivityProvider`, keeping recorded edits separate from general activity.

## What's next

- Codex input/approval state when a reliable local signal becomes available.
- Gemini CLI, OpenCode, and Cursor, once their local tool results can be confirmed. They are unsupported in this release.
- More coverage of changes made through agent shell commands.
- A global hotkey and optional launch at login.
- Signed, notarized downloads and a simpler installation path.

## Support the project

[Bug reports](https://github.com/NotYaz/agent-trail/issues), compatibility reports, and thoughtful contributions help the alpha mature.

## Donations

Agent Trail is free. A donation is optional, and every feature stays available either way.

- **GitHub Sponsors:** [NotYaz](https://github.com/sponsors/NotYaz), when sponsorship is available on the account.
- **Buy Me a Coffee:** [buymeacoffee.com/lltod](https://buymeacoffee.com/lltod)

The same links are listed in [Support](docs/SUPPORT.md). Agent Trail does not take payment inside the app.

Agent Trail is an independent project, not affiliated with Anthropic, OpenAI, xAI, or other assistant vendors. Licensed under [MIT](LICENSE).
