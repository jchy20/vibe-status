# Privacy and remote access

[Back to the README](../README.md)

Vibe Status uses the system `/usr/bin/ssh` client and your existing SSH configuration. It does not store passwords, private keys, or SSH-agent credentials.

The app reads metadata needed to display loaded task names, prompt previews, working directories, states, and timestamps. It does not send prompts, approve requests, or cache transcripts. Codex task metadata and diagnostics remain in memory and are discarded when the app exits. Host configuration and preferences are stored locally in `UserDefaults`.

To find Codex tasks started independently with commands such as `codex resume`, Vibe Status also checks which canonical task IDs have an active writer lock. The remote check is read-only and returns task IDs only. Names and latest turn states then come from Codex's metadata APIs; Vibe Status does not read the Codex state database or rollout files.

For tasks owned by an independent Codex process, the available cross-process metadata reports working versus ready but does not expose whether an active turn is specifically waiting for approval or user input. Those tasks therefore appear as working until their turn finishes; managed app-server tasks retain all three status states.

To avoid repeating account-wide Codex quota information for multiple hosts, the app reads the current ChatGPT account email and uses it only as an in-memory deduplication key. The email is not displayed, logged, or persisted.

The optional Claude Code helpers store only a session identifier, the first line of the latest submitted prompt, working directory, display state, quota percentages and reset times, and update timestamps under `~/.local/state/vibe-status/` on the remote host. They do not read or store Claude credentials. Session records are removed on a normal Claude Code session exit, and the app ignores stale records.

There is no analytics or telemetry.
