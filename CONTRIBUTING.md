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

## Make a focused change

Describe the user-visible problem, the proposed behavior, and how you checked it. Keep changes small enough to review. Run `swift test` and a release build before opening a pull request. For interface changes, include a screenshot from demo mode and verify readability in light and dark appearances.

Tests should cover behavior and regressions using synthetic fixtures. Never commit real session logs, conversation content, project paths, profile settings, caches, tokens, or signing material. Diagnostic output can contain sensitive paths even when it contains no conversation text.

Do not add telemetry or network requests to the indexing path. Do not quit, restart, inject into, or modify a running assistant. Focusing an assistant must remain a deliberate user action that identifies a unique instance.

## Add an assistant adapter

`Sources/AgentTrailCore/Models.swift` defines `ActivityProvider`, `ProjectActivity`, and project aggregation. An adapter should:

- Use supported local evidence and identify the canonical project folder separately from its actual workspace or worktree.
- Keep general activity separate from confirmed file-edit evidence.
- Document unsupported operations and format assumptions.
- Surface missing or unreadable data without replacing it with guessed authorship.
- Use synthetic fixtures to cover partial writes, malformed records, failed tools, and incremental indexing where relevant.

An mtime alone cannot identify the assistant that made a change. Please open a feature request before a substantial provider or format change so we can agree on evidence and scope.

## Report an issue

Include macOS version, CPU architecture, Agent Trail version or commit, Claude version, and a short reproduction. Replace private paths with fictitious examples. If a screenshot is needed, use `--demo` or redact it carefully.

For a potential vulnerability, follow [SECURITY.md](SECURITY.md). Contributions are made under this repository's [MIT license](LICENSE).
