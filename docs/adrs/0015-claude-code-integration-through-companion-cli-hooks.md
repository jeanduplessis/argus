# ADR 0015: Claude Code integration through Companion CLI hooks

- Status: Accepted
- Date: 2026-10-21

## Context

Kilo and Pi integrations are Argus-owned JavaScript files that run inside the
agent process, keep lifecycle state in memory, and send agent methods over the
app-owned socket. Claude Code has no in-process plugin surface for this. Its
public extension point is `hooks` in user `settings.json`, where each event runs
a new command with the event JSON on stdin. Hooks therefore cannot keep state
between events, and Claude Code installed natively does not guarantee that
`node` is available.

The Companion CLI is already bundled with Argus, placed first on `PATH` in every
Argus-spawned shell, and compiled against the shared `ArgusIPC` wire contract.

## Decision

The Claude Code integration installs Argus-owned hook entries into the effective
`CLAUDE_CONFIG_DIR/settings.json` (or `~/.claude/settings.json`) from Settings.
Every entry runs the same command:

```sh
[ -n "$ARGUS_SURFACE_ID" ] && command -v argus >/dev/null 2>&1 && exec argus agent claude-code-hook >/dev/null 2>&1; exit 0
```

The exact command string identifies Argus ownership, so there is no plugin file.
The settings editor keeps unrelated keys in order, keeps user hook groups and
handlers, writes Claude Code's own two-space layout, follows a symlinked
settings file, and refuses settings that are not strict JSON objects.

A hidden `argus agent claude-code-hook` subcommand translates one hook event
into `agent.statusChanged`, `agent.statusCleared`, or `agent.turnCompleted`
using the shared `ArgusIPC` parameter types. It prints nothing and always exits
0. Because the command `exec`s the CLI, the parent process is Claude Code, and
its PID and start time form the reporting session ID. A monotonic clock reading
supplies the sequence. This orders one Claude Code process's updates without any
on-disk state and survives `/clear` and `/resume`, which change Claude Code's own
session ID inside one process.

Status-only hooks run with `async: true` so they never delay Claude Code.
`SessionStart`, `Stop`, `StopFailure`, and `SessionEnd` run synchronously so
delivery completes before `claude -p` exits; the CLI bounds each delivery to one
second.

This extends the Companion CLI beyond Workspace Commands. It remains
transport-only: it owns no domain state and Argus still validates every
Workspace and Terminal Surface.

## Consequences

- Claude Code support needs no Node.js runtime and is covered by Swift tests.
- The integration works only where the bundled CLI is on `PATH`. A shell
  configuration that rebuilds `PATH` from scratch disables it silently, as it
  does Workspace Commands.
- Hooks fire in every Claude Code session, including outside Argus; there the
  command exits after one shell test.
- Claude Code does not run `Stop` after a user interrupt. Status stays running
  until the next prompt, permission, or Claude Code's idle notification.
- Another blocking `Stop` hook can make Claude Code continue after Argus has
  already reported completion.
- If Claude Code runs hooks through a wrapper process, each event becomes its
  own reporting session: updates still apply, but ordering protection and
  cleanup on exit are lost.

## References

- `docs/SPEC.md`
- `docs/adrs/0003-live-agent-status-through-app-owned-ipc.md`
- `docs/adrs/0012-companion-cli-workspace-commands-over-app-owned-ipc.md`
- `Argus/Services/ClaudeCodeIntegrationService.swift`
- `Argus/Services/ClaudeCodeSettingsEditor.swift`
- `ArgusCLICore/ClaudeCodeHook.swift`
- `ArgusIPC/AgentSocketPayloads.swift`
