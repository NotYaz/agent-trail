# Changelog

## Unreleased

- **GitHub Copilot.** A Copilot profile reads Copilot Chat in VS Code and the Copilot CLI (with the Copilot app and VS Code's Copilot CLI sessions, which write the same files), and their projects share cards with Claude, Codex, and Grok.
  - **Copilot Chat in VS Code.** History only. An edit tool call counts once VS Code recorded applying it to a file in that request. Edits undone by restoring a checkpoint, rejected, or undone in the next request don't count. Chats in Remote-SSH windows, windows without a folder, and chats with no requests are skipped. VS Code writes these records about once a minute while idle, so the newest edits can show up to a minute late.
  - **Copilot CLI.** History and live status. A successful edit counts, with its files from `fileEdits` or the tool's `path`, and subagent edits count as delegated. An open session is Working during a turn or tool call and Needs input while a permission request or a question to you is unanswered. Jump brings its terminal forward.
  - One profile covers both: `configDirectory` is the Copilot CLI home (`~/.copilot`), and `userDataDirectory` is VS Code's user-data folder (VS Code's default when omitted for `~/.copilot`; set it for Insiders).
- **OpenCode.** An OpenCode profile reads `opencode.db`, the database the OpenCode terminal app, desktop app, and `opencode serve` share, opened read-only. Its projects share cards with the other assistants.
  - **History.** A completed `edit`, `write`, or `patch` call counts (`multiedit` and `apply_patch` in OpenCode 1.x), with its files resolved against the folder the session was in at that step, and subagent edits count as delegated. Calls that failed, were denied, or still wait for approval don't count, and neither do shell commands. `/undo` hides the edits it rolled back until `/redo`. OpenCode 2's import of 1.x sessions counts each session once and keeps sessions you deleted deleted.
  - **Live status.** OpenCode 2 only: a session executing in the registered background service is Working, and Needs input while it asks you a question. A session waiting for an approval shows as Working, since OpenCode keeps approvals in memory. While `opencode acp`, `--standalone`, or a hand-run `opencode serve` runs its own server on the same database, a turn that server could be running is Unknown. Jump shows the session's folder in your editor or Finder.
  - `configDirectory` is OpenCode's data folder (`~/.local/share/opencode`), or the database file set with `OPENCODE_DB`.
- **Found on this Mac.** When an assistant has sessions on this Mac but no profile reads them, the Projects panel offers **Add profile**. **Not now** hides the offer for good. Nothing is added without your click.
- A `profiles.json` that names an assistant this version doesn't know now says which one, instead of a generic JSON error. It still fails closed, so saving can't drop that profile.
- Under the hood, each assistant is now described once, and its readers are registered in one place, so a new assistant can't be left out of scans or cache flushes.

## 0.1.0-alpha.13 — 2026-11-07

- **The Map.** A third tab, Map (⌘3), draws one project's Git branches, the sessions that edited them, and the commits and merges Git recorded, on one timeline. Pick the project in its header and a range: Today, 7D (the default), 30D, or All. Days start at 05:00, and idle stretches fold into narrow seams, the longest labelled with their length.
  - **Four views.** Lanes gives each branch a lane off the trunk, with a bar for each session's run of edits on it, brighter where edits were denser and hatched where subagents made them. Tree draws branches as a tree off the trunk, each link as wide as the edits that came back through it, with related branches stacked into nodes that open on click. Orbit wraps the range around a ring, with branches leaving it at their fork and returning at their merge. Log is a vertical Git log, newest on top, with each session on its branch's column.
  - **Branches.** Only edits that landed in the project are drawn, as its card counts them. An edit belongs to the branch of the next commit in its working tree, within 12 hours: uncommitted changes travel through `checkout -b` to a new branch, pulls, and fast-forwards, while a checkout of an existing branch or a reset leaves them on the branch checked out when they were made. A run lasts until the session pauses on that branch for 20 minutes (Today), 30 minutes (7D), or an hour (30D and All), or its next edit in the same working tree lands on another branch. Codex threads a session spawned fold into it.
  - **Merges.** A branch lands at a merge commit, on the trunk or another branch, that has one of its commits as a later parent; else at a trunk commit that records its head's tree, as a squash does; else at a pull request GitHub squashed under the subject of one of its commits. The trunk is main, else master, else the branch checked out. A merged branch no session edited is a hollow ring on the trunk instead of a lane. Rebased-away and amended commits are left out, and a deleted branch's commits stay while the reflog keeps them.
  - **Worktrees.** Linked worktrees inside the checkout, and Claude's `.claude/worktrees` folders even after they are removed, take the branch Claude Desktop recorded the session writing there, the branch their reflog shows, or a branch named for the folder. One whose branch stays unknown is drawn under its folder name.
  - **Cloud sessions.** Claude Code sessions on claude.ai keep no record on this Mac. Their commits carry a `Claude-Session` trailer, so they show as pale runs on the branches they committed to, without edit counts, and **Open** goes to the session on claude.ai. Commits GitHub made are not counted as their work.
  - **Bundles.** Branches worked on side by side, such as a workflow's agents in worktrees, share one row in Lanes as thin strands: three or more, or two agents of one workflow run. The trunk and branches others merged into keep their own rows. Click a bundle to open its strands with their names, and again to fold them. Past 14 lanes, counting a bundle as one, related branches (merged into one integration branch, sharing a prefix such as `feature/`, or from one workflow run) fold into one row. **Show all** puts every branch on its own lane.
  - **Hover and click.** Hover a run, branch, commit, or idle stretch to describe it under the map, and click to pin it. A live session's run carries on to now with its status, and **Jump** opens it. **Copy** copies a commit's SHA. Click a profile in the legend to dim the others.
  - **The Map window.** A button in the panel's toolbar, shown on the Map tab, opens the Map in a resizable window that keeps its size and place. It shares the project, range, and view with the tab, and Lanes there grows wide enough for its labels and scrolls sideways, opening at now. At 980 pt or wider, a details panel sits beside the map. It describes what you hover; a click pins the item and lists its runs, commits, merges, or branches as rows you can click. ⌘[ goes back, Esc unpins, and the sidebar button hides the panel. With nothing pinned, it lists live sessions with Jump, the busiest branches, recent sessions, merges, profiles, the longest pauses, and the time of day edits land.
  - **Git, read-only and only while you look.** Reflogs, HEAD files, and worktree records are read as files. `git for-each-ref` and `git log` run with a Git from Xcode, the Command Line Tools, `/opt/homebrew`, or `/usr/local`, never the `/usr/bin/git` stub, with optional locks, hooks, the file-system monitor, network protocols, and lazy fetches turned off. They run only while the Map is on screen, in the open panel or in a Map window that is not covered or minimized: when it appears, on Refresh, when you change its project, range, view, or Show all, when the project's sessions or live status change, and at most once a minute otherwise. The history read is bounded by the range and the project's first local session or cloud commit, and takes at most 4,000 commits; finding that first cloud commit searches every commit's message for a `Claude-Session` trailer and gives up after 3 seconds. Only branch and tag names, reflog moves, and each commit's hash, parents, tree, date, subject, Co-Authored-By names, Claude-Session link, and whether GitHub committed it are kept, in memory; author and committer names and e-mail addresses never are. Without that Git, branches come from the reflogs and ref files and no commits are drawn. Nothing read from Git is written to disk, and demo mode has no Map.
- **A session switcher on a keyboard shortcut.** Press ⌃⌥J in any app to open a panel with every live session, needs input first, numbered 1–9.
  - Type to filter by project, title, branch, folder, or profile. Return or ⌘1–⌘9 jumps, and so does a digit before you type a filter. Esc gives focus back to the app you were in.
  - ⌃⌥⇧J jumps straight to the most urgent session without the list.
  - Pick ⌃⌥J, ⌃⌥A, ⌃⌥⌘J, or Off in ⋯ › Session switcher. The right-click menu has **Session Switcher…** with the shortcut beside it.
  - The shortcut needs no Accessibility or Input Monitoring permission. Its letter follows your keyboard layout, and if another app already registered the chord, the ⋯ menu says so.
- **`agenttrail://` links.** `agenttrail://jump` opens the most urgent live session. Add `?project=NAME` to pick from one project, or `?session=ID` for one session. `agenttrail://switcher` opens the switcher. Shortcuts, Raycast, a Stream Deck, or `open` in a shell can drive jumps this way. Links only pick among live sessions Agent Trail already shows; anything else is ignored.
- **Jump with two Claude instances no longer opens the wrong one's Code home.** macOS hands every `claude://` link to the Claude instance launched first, whichever is in front; Agent Trail assumed the one in front got it. So Jump on a session of the instance launched later (for example Main, when Second was opened first) sent the link to the other instance, which showed its own Code home. Jump now opens the first instance's sessions directly. For any other instance's session it brings that instance forward with a hint naming the session, and it never sends that instance's link. If the open reports a different instance than expected, it shows the same hint. Since alpha.8, the release notes and README said the session's own instance comes forward and receives the link; that was true only for the instance launched first.
- The menu bar app now has an Edit menu, so ⌘X, ⌘C, ⌘V, ⌘A, and undo work in its text fields, the project search included.
- **Less work while idle.** With the panel closed, Agent Trail used about 17–18% of a core, counting the system-wide `lsof` it ran every 3 seconds; it now uses about 4%. Routine refreshes no longer build partial results, which only the first index shows, and each scan resolves each folder path once, where it used to make about 200,000 file-system checks. The 3-second live check decodes Claude Desktop's session records again only when a file changes, and Codex's thread locks are read from the kernel's descriptor tables for `codex` processes instead of from `lsof`; nothing is opened, locked, or written, as before. The Claude, Codex, and Grok caches are written only after a scan changed them, at most every 5 minutes and once more at quit, instead of after every scan, which came to 7–11 GB of writes a day for a 4 MB cache.
  - After a crash, the next launch rereads whatever the logs gained since the last save, at most about 5 minutes of growth. Results are the same.
  - A process with a name other than `codex` that holds a Codex thread lock no longer triggers the "could not be verified" notice or hides that thread's real owner.
  - While a routine refresh runs, the tooltips that counted logs ("Indexing X of Y") show their general text; the first index still counts.
- `AgentTrail --render-switcher-demo OUTPUT.png` draws the switcher with sample sessions.
- `AgentTrailInspect --map PROJECT` prints one project's session trails, Git history, and live sessions as a JSON snapshot; `--map-summary SNAPSHOT.json [--range today|7d|30d|all]` prints the map built from it as text, and `AgentTrail --render-map SNAPSHOT.json OUTPUT.png` draws it, with `--mode lanes|tree|orbit|log`, `--range`, `--window WxH`, `--pin KIND`, `--open-bundles`, and `--all-branches`. A snapshot holds paths, branch names, and commit subjects, so keep it private.

## 0.1.0-alpha.12 — 2026-11-03

- **Claude Code in the terminal.** Sessions started with `claude` in a terminal now appear next to Claude Desktop's. Their edits count for the project they landed in, as Codex's do, so a session started above a repository joins it; subagent edits count as delegated. They get live status, Working in background, and a Jump that brings their terminal forward (Terminal, iTerm2, Ghostty, Warp, VS Code, or Cursor, when the process environment names it), never a Claude Desktop Code session. In Claude Desktop's own terminal pane, Jump brings forward the Claude instance holding the pane, for `claude` and Grok alike. Only logs whose first record naming an entrypoint and folder says `cli` count; SDK and `claude -p` runs do not, and a Desktop session's log is never counted twice. A Mac without Claude Desktop no longer gets Desktop notices. `AgentTrailInspect --live` marks these sessions `startedInTerminal`.
- **Claude's own background status counts.** Claude Code now reports a session whose turn ended while a command it started keeps running as `shell`. Agent Trail used to show that as Unknown; it now shows Working in background, with the start time of the command it can see, or the turn's end when the command is no longer one of the session's children.
- The README's first screen says what is supported and what is not, and what Agent Trail never does. "Why it exists" explains why it leaves each agent in its own app. New sections cover running two Claude accounts and the alternatives for setups Agent Trail does not serve.

## 0.1.0-alpha.11 — 2026-11-03

- **Color themes.** Pick Classic, Gentle, Vivid, or Aurora from the panel's ⋯ menu. Gentle brightens the canvas and the indigo wash, draws sparklines in indigo, gives the Trail calendar a blue-slate tint, and brightens dark mode's Working green and needs-input amber. Vivid adds brighter profile colors that keep their families (blue, pink, violet, teal) and, unlike Classic's, pass color-vision checks for every pair in light and dark. Aurora adds an indigo Trail calendar and a three-color wash. Classic stays the default. Renders take `--theme NAME`.
- The website has a matching theme picker under the hero screenshot; it recolors the page and swaps the screenshots.
- **A working count in the menu bar.** While sessions work and none needs input, a number inside the trail's triangle shows how many, including Claude sessions working in background; + means ten or more. It follows light and dark bars like the glyph, and the travelling dot passes behind it. The amber needs-input count still takes over while a session waits. **Show working count** in ⋯ › Menu bar turns it off.
- **A larger menu-bar icon.** The trail and its other states are 1.5 times their old size, about 18 pt tall with the usual margins in the bar, so the count reads at a glance. The item is about 9 pt wider. `--render-status-demo` now also draws the icons at real size.

## 0.1.0-alpha.10 — 2026-11-02

- **A website.** Agent Trail now has a home page at https://notyaz.github.io/agent-trail/, published from `site/` with GitHub Pages. It covers the panel, live status, Jump, Growth, keeping long jobs visible, privacy, and installation.
- The README explains how long-running jobs stay visible: what Agent Trail shows while a session's background command runs, how it recognizes that command from the process tree, how to keep a training run or other long job attached to its session, and the limits.
- **Smoother scrolling.** Project cards are much cheaper to bring into view, so the Projects list no longer stutters each time a card appears, and both tabs stop pausing every 3 seconds when live status refreshes. A live check that changes nothing redraws nothing, and history is no longer merged again on every check. Cards look and behave as before; the ⋯ menu now opens when the click is released, like the Jump control's menu.
- `AgentTrail --benchmark-scroll projects|growth` measures scrolling with sample data or your own history (see CONTRIBUTING).

## 0.1.0-alpha.9 — 2026-11-02

- **Background commands keep a Claude session working.** When a turn ends while a Bash command it started is still running, such as a background build or a wait on a training run, the session now shows Working ("Working in background") instead of Idle until the command exits. Agent Trail sees this from the session process's children: Claude runs each Bash command in its own process group, while MCP servers stay in Claude's. It reads only parent, group, and start time, never arguments. `AgentTrailInspect --live` reports `backgroundSince`.

## 0.1.0-alpha.8 — 2026-11-01

- **Jump to the work.** Each project card's main button now opens the most urgent live session (Answer, Open, or Resume) with its title and time in state, instead of one button per Claude instance. Claude Code sessions open through Claude's session link, also with several Claude instances: the session's own instance comes forward first and receives the link, with a hint as the fallback. Codex threads open through `codex://threads`, and Grok brings its terminal forward. A ⌄ menu lists every live session and opens the worktree in your editor, terminal, or Finder. Details rows get their own ↗.
- **A menu-bar icon that shows state.** A dot travels along the trail while agents work, the icon turns amber with a count when input is needed, and a checkmark appears briefly when work finishes. Right-click lists live sessions to jump to. Settings for animation, the count, and session titles are in the ⋯ menu. Animation runs in Core Animation and stops for Reduce Motion, Low Power Mode, and sleeping displays.
- Live sessions now carry their title, Claude's needs-action sentence, branch, and pull requests in memory only, plus the app that owns a Codex or Grok session. No new permissions and no cache changes.
- Published crypto donation addresses with QR codes on the support page: Bitcoin; ETH, USDC, and USDT on Ethereum, Base, or Arbitrum One (one shared address); and USDT on TRON (TRC-20).

## 0.1.0-alpha.7 — 2026-11-01

- Redesigned panel. A Pulse strip shows live sessions, edits in the last 7 days, active projects, and your day streak. Project cards gain a 30-day sparkline, the change from the previous 30 days, a profile mix bar, New and Dormant chips, a profile stack with live status rings, and an attention edge. A pinned toolbar adds filter chips and sorting by edits, trend, or name. Keyboard shortcuts: ⌘1, ⌘2, ⌘F, ⌘R.
- Growth is rebuilt and follows the system appearance: KPI tiles, a recorded-edits chart with a 7-day average, peak, per-profile breakdown, sessions and running-total views, a 26-week Trail calendar with weekday totals, a **When edits land** punch card with peak hour and chronotype, a profile mix with delegated edits, and **Where edits landed**. The in-app growth tree moved to the exported portrait.
- Statistics use local activity days that start at 05:00, so late-night work counts toward the evening it began. Changes are shown only when saved history covers the previous period. `AgentTrailInspect` adds `localDays` next to `dailyHistoryUTC`.
- The exported portrait has a headline built from your numbers, a mini calendar clipped to the selected period, a longest-streak total, a live preview, and an optional names toggle. Names stay hidden by default; paths and hour-of-day data are never exported.
- New profile palette with better separation from status colors: Claude · Second is magenta, Codex violet, and Grok teal. Errors and notices appear as toasts; long errors stay readable and selectable.
- Statistics are built off the main thread from records the app already keeps, with no cache format change.
- Fixed scans that could stall at launch. File metadata is now read without extended attributes, which made macOS ask for access to protected folders such as Documents and blocked indexing until someone answered. Cache entries and saved folder identities stay valid.

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
