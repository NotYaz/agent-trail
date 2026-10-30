# Security and privacy

Agent Trail is an alpha. Security fixes focus on the latest source revision; no older release line has a separate support commitment.

## Data boundaries

The app reads configured Claude desktop session indexes and JSONL histories on the local Mac. It writes its own settings and incremental activity cache under `~/Library/Application Support/AgentTrail/`. It does not change Claude records, install hooks, send telemetry, or upload histories. Assistant focus requests target an identified running instance after a user click; the app does not launch, quit, kill, or restart assistants.

Local paths, profile names, tool IDs, and timestamps can reveal private information. An indexing cache or diagnostic report is not automatically safe to publish. Session logs can contain prompts, source code, commands, credentials, and other secrets. Never attach complete real logs to a public issue.

The alpha uses private on-disk formats. Treat records and process information as untrusted input. Unknown data must not result in guessed authorship or arbitrary application activation. Distributed alpha bundles are ad-hoc signed, without Developer ID signing or Apple notarization.

## Report a vulnerability

On GitHub, use **Security → Advisories → Report a vulnerability** when private reporting is enabled. Include the affected revision, a minimal reproduction with synthetic records, and the impact. Do not include live tokens, private conversations, or complete histories.

If private reporting is unavailable, open an issue that only requests a private contact channel. Keep the vulnerability details and sensitive data out of that public request. There is no published response-time guarantee during the alpha.

For an ordinary parsing or compatibility bug, use the issue template with redacted examples. See [CONTRIBUTING.md](CONTRIBUTING.md) for fixture guidance.
