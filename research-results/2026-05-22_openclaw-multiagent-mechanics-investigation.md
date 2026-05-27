# OpenClaw Multiagent Mechanics Investigation

## Scope

This report investigates how OpenClaw's multiagent system works in runtime code, with focus on:

- how child agents are created
- whether child agents run as isolated sessions or as long-lived workers that receive commands
- how agent-specific context is applied
- how persistent follow-up to spawned agents works

All findings below are derived from source code under `~/.npm-global/lib/node_modules/openclaw/dist`.

## Executive Summary

OpenClaw's native multiagent implementation is session-based. A parent agent uses `sessions_spawn` to create a fresh child session identified by a new `sessionKey`, then starts that child by invoking the internal `agent` runtime against that session. The child session is associated with a target `agentId` and runs with that agent's workspace-derived bootstrap context, including files such as `AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md`, and `MEMORY.md`.

The native `runtime="subagent"` path is not implemented as a separate OS process per child. Instead, it runs as an embedded agent session inside the OpenClaw runtime. However, OpenClaw also supports persistent child sessions and follow-up messaging into existing sessions, so the overall system is not limited to one-shot spawn-and-discard behavior.

## Findings

### 1. Native multiagent work is built around session spawning

OpenClaw exposes a dedicated `sessions_spawn` tool for child-agent creation.

- `dist/tool-policy-dLQuqjVi.js:21-27`
  - The tool description states: `Spawn an isolated session with runtime="subagent" or runtime="acp".`
  - It also distinguishes `mode="run"` from `mode="session"`.

- `dist/pi-embedded-CNTNdlGw.js:14322-14461`
  - `createSessionsSpawnTool()` routes `runtime="subagent"` requests to `spawnSubagentDirect(...)`.

- `dist/pi-embedded-CNTNdlGw.js:13901`
  - `spawnSubagentDirect(...)` creates a new child session key:

```js
const childSessionKey = `agent:${targetAgentId}:subagent:${crypto.randomUUID()}`;
```

This shows the primary unit of native multiagent execution is a newly created child session.

### 2. Child tasks are started by running the internal agent on the new child session

The spawned session is not merely registered; it is immediately started by invoking the internal `agent` method against the new child session.

- `dist/pi-embedded-CNTNdlGw.js:14102-14126`
  - `spawnSubagentDirect(...)` calls:

```js
callSubagentGateway({
  method: "agent",
  params: {
    message: childTaskMessage,
    sessionKey: childSessionKey,
    ...
  }
})
```

This means the parent does not send a task to a pre-existing generic worker pool by default. It creates a new child session and starts an agent run inside that session.

### 3. Target agent identity and per-agent configuration are applied at spawn time

The spawned child is tied to a target `agentId`, not just a generic child runtime.

- `dist/pi-embedded-CNTNdlGw.js:13885-13899`
  - The code resolves `requesterAgentId` and `targetAgentId`.
  - Cross-agent spawning is checked against `allowAgents` policy.

- `dist/agent-scope-CYaif3uh.js:101-124`
  - `resolveAgentConfig(cfg, agentId)` returns per-agent settings including:
    - `workspace`
    - `systemPromptOverride`
    - `model`
    - `skills`
    - `memorySearch`
    - `subagents`
    - `sandbox`
    - `tools`

- `dist/pi-embedded-CNTNdlGw.js:13926-13937`
  - `resolveSubagentModelAndThinkingPlan(...)` is called with the target agent config.

This shows spawned child sessions are parameterized by the selected agent profile rather than using a single generic child persona.

### 4. Per-agent workspace selection is explicit in runtime code

OpenClaw resolves workspace per agent, and spawned sessions inherit the appropriate workspace path.

- `dist/agent-scope-CYaif3uh.js:168-180`
  - `resolveAgentWorkspaceDir(cfg, agentId)` resolves the workspace directory for a given agent.

- `dist/captured-registration-Cdk430eW.js:336-340`
  - `resolveSpawnedWorkspaceInheritance(...)` returns the target agent's workspace directory unless an explicit workspace override is used.

- `dist/pi-embedded-CNTNdlGw.js:14073-14085`
  - Spawn metadata is recorded with:
    - `spawnedBy`
    - `spawnedWorkspaceDir`

This means workspace inheritance is a deliberate runtime mechanism, not an incidental side effect.

### 5. Workspace bootstrap files provide the child agent's persona and memory context

The runtime reads specific workspace files and injects them into the run context.

- `dist/workspace-Q6iYWMyk.js:362-415`
  - `loadWorkspaceBootstrapFiles(dir)` loads these files from the workspace:
    - `AGENTS.md`
    - `SOUL.md`
    - `TOOLS.md`
    - `IDENTITY.md`
    - `USER.md`
    - `HEARTBEAT.md`
    - `BOOTSTRAP.md`
    - `MEMORY.md`

- `dist/pi-embedded-CNTNdlGw.js:31278-31289`
  - `resolveBootstrapContextForRun(...)` is called with the run's `workspaceDir`.

- `dist/pi-embedded-CNTNdlGw.js:31551-31583`
  - The embedded system prompt is built using `buildEmbeddedSystemPrompt(...)`, with `contextFiles` and other workspace-derived inputs.

This is the code-level basis for agent-specific persona, memory, and bootstrap instructions being applied to the spawned child session.

### 6. Native subagents are embedded sessions, not separate OS processes

The native `runtime="subagent"` path does not spawn a new operating system process for each child agent.

- `dist/agent-command-Dpv6jqqa.js:319-367`
  - Agent execution routes into `runEmbeddedPiAgent(...)`.

- `dist/pi-embedded-CNTNdlGw.js:31722-31734`
  - The embedded runtime creates the agent session with:

```js
({session} = await createAgentSession({
  cwd: resolvedWorkspace,
  agentDir,
  ...
}))
```

This indicates native subagents run as embedded agent sessions inside the OpenClaw runtime.

There is a `child_process.spawn` import in `dist/pi-embedded-CNTNdlGw.js:234`, but the inspected use at `dist/pi-embedded-CNTNdlGw.js:664-727` is for bundled LSP server processes, not for subagent spawning.

### 7. OpenClaw also supports persistent sessions and message-based follow-up

Although spawning is the main subagent creation mechanism, OpenClaw also supports sending messages into existing sessions.

- `dist/tool-policy-dLQuqjVi.js:18-20`
  - `sessions_send` is described as sending a message into another visible session.

- `dist/pi-embedded-CNTNdlGw.js:11251-11481`
  - `createSessionsSendTool()` resolves a visible session and starts another agent run for that existing session via `method: "agent"`.

This shows OpenClaw supports both:

- spawning fresh isolated child sessions
- sending follow-up work to already-existing sessions

### 8. Spawned subagent sessions can be one-shot or persistent

The spawn mechanism supports both ephemeral and persistent child-session behavior.

- `dist/tool-policy-dLQuqjVi.js:23-26`
  - `mode="run"` is documented as one-shot.
  - `mode="session"` is documented as persistent or thread-bound.

- `dist/pi-embedded-CNTNdlGw.js:13837-13845`
  - `spawnMode` is resolved explicitly.

- `dist/pi-embedded-CNTNdlGw.js:14063-14064`
  - The child receives a system note when `spawnMode === "session"`:
    - `This subagent session is persistent and remains available for thread follow-up messages.`

- `dist/pi-embedded-CNTNdlGw.js:14248-14253`
  - Accepted spawn result returns the resolved mode.

This means persistent follow-up is an intentional feature of the subagent system, not a workaround.

### 9. Child completion is push-based back to the requester session

The runtime automatically propagates child completion back to the requester rather than requiring the parent to poll continuously.

- `dist/pi-embedded-CNTNdlGw.js:11775-11830`
  - `buildSubagentSystemPrompt(...)` instructs child sessions that results auto-announce to the requester.

- `dist/pi-embedded-CNTNdlGw.js:11814-11821`
  - The injected subagent instructions explicitly say descendants auto-announce results back and discourage polling.

- `dist/pi-embedded-CNTNdlGw.js:12067-12115`
  - `runSubagentAnnounceFlow(...)` delivers completion back to the requester session.

This makes the orchestration model session-driven and event-driven rather than mailbox polling.

## Architecture Characterization

Based on the inspected source, OpenClaw's native multiagent system is best characterized as:

- session-oriented orchestration
- fresh child-session spawning for new delegated work
- per-agent workspace/profile binding
- embedded in-process agent execution for native subagents
- optional persistence for follow-up in thread-bound child sessions
- event-based result return to the parent/requester session

It is therefore not just a flat fleet of always-running worker processes waiting for commands. At the same time, it is also not limited to one-shot throwaway children, because persistent spawned sessions and `sessions_send` follow-up are both present in the runtime.

## Conclusion

The inspected runtime shows that OpenClaw's native multiagent implementation centers on spawning isolated child sessions targeted at specific agent identities, then running those sessions with the target agent's workspace-derived bootstrap context. That bootstrap context includes persona and memory sources such as `SOUL.md`, `AGENTS.md`, and `MEMORY.md`.

For native subagents, execution is embedded within the OpenClaw runtime rather than launched as a separate OS process per child. However, the system also supports persistent child sessions and later follow-up messaging into existing sessions. In practice, OpenClaw combines spawn-based delegation, per-agent workspace scoping, and session-level continuation within a single session-oriented runtime model.
