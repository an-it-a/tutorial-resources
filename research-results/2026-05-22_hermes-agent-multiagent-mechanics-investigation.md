# Hermes Agent multi-agent mechanics investigation

## Scope

This report examines Hermes Agent's multi-agent mechanics in source code, with the specific goal of establishing two claims:

1. Hermes Agent's Kanban multi-agent mechanics support real parallel agent execution, where workers are separate processes rather than child/subagent calls inside one parent agent turn.
2. Hermes Agent also supports a distinct subagent-based multi-agent mechanism through `delegate_task`.

The analysis is based on source code under `/home/ubuntu/.hermes/hermes-agent`.

## Executive summary

The source code supports both claims.

First, Kanban is implemented as a durable board-plus-dispatcher system that claims tasks from SQLite, spawns workers as separate Hermes OS processes through `subprocess.Popen(...)`, records their `worker_pid`, and supervises them independently through heartbeat, stale-claim recovery, and crash detection. This is not the same execution model as a parent agent calling a child subagent and waiting inline for it to return. Kanban workers are independent processes with their own environment, task identity, profile, log file, and lifecycle state in the board database.

Second, Hermes also implements a separate subagent mechanism through `delegate_task`. That path constructs child `AIAgent` instances in-process, runs them through a `ThreadPoolExecutor` for concurrent batches, and blocks the parent turn until the children finish. Hermes therefore supports two different multi-agent mechanics:

- Kanban: durable, process-based, board-mediated parallel worker execution
- `delegate_task`: synchronous, in-process subagent delegation

The key conclusion is that Kanban should not be described as merely a parent agent with child subagents. The source shows a materially different architecture: a dispatcher claims work from a persistent queue and launches independent Hermes worker processes. At the same time, Hermes does still support subagent-style multi-agent execution through `delegate_task`.

## Findings

### 1. Kanban is explicitly designed as a multi-profile collaboration board, not as a subagent call tree

The Kanban implementation is framed in both code and docs as a shared coordination primitive across profiles.

Evidence:

- `website/docs/user-guide/features/kanban.md:11-12` states that every task is a row in `~/.hermes/kanban.db`, every handoff is a row, and every worker is a full OS process with its own identity.
- `website/docs/user-guide/features/kanban.md:36-47` contrasts Kanban with `delegate_task`: Kanban is a durable message queue plus state machine, while `delegate_task` is an RPC-like fork/join call.
- `hermes_cli/kanban_db.py:1-9` describes Kanban as a SQLite-backed board for multi-profile collaboration and explicitly says that a worker spawned with `hermes -p <profile>` joins the same shared board as the dispatcher.
- `toolsets.py:242-257` defines a dedicated `kanban` toolset for Kanban coordination rather than reusing the `delegate_task` tool surface.

Conclusion:

At the architectural level, Kanban is presented and implemented as a shared work queue and lifecycle system for multiple profiles. That is already a different model from in-turn parent/subagent delegation.

### 2. Kanban workers are spawned as separate Hermes OS processes

The strongest evidence that Kanban is not just subagents of a main agent is the worker spawn path.

Evidence:

- `hermes_cli/kanban_db.py:5152-5169` defines `_default_spawn(...)` as a fire-and-forget worker launcher for Kanban tasks.
- `hermes_cli/kanban_db.py:5201-5238` injects task-specific worker environment variables such as `HERMES_KANBAN_TASK`, `HERMES_KANBAN_RUN_ID`, `HERMES_KANBAN_DB`, `HERMES_KANBAN_WORKSPACES_ROOT`, `HERMES_KANBAN_BOARD`, and `HERMES_PROFILE` before launch.
- `hermes_cli/kanban_db.py:5240-5281` builds a full Hermes CLI command line, including `hermes -p <profile> ... chat -q ...`.
- `hermes_cli/kanban_db.py:5295-5304` launches the worker with `subprocess.Popen(...)` and `start_new_session=True`.
- `hermes_cli/kanban_db.py:5316` returns `proc.pid`, which the dispatcher stores and later supervises.

Conclusion:

Kanban workers are not child `AIAgent` objects running inside the parent turn. They are separate Hermes processes started by the dispatcher at the OS level.

### 3. Kanban dispatch is queue-driven and can launch multiple workers in parallel

Kanban's dispatch loop claims ready tasks and spawns workers up to configured concurrency limits. That is a real parallel dispatch model, not a single parent call stack with nested subagents.

Evidence:

- `gateway/run.py:4994-5005` defines `_kanban_dispatcher_watcher()` as an embedded dispatcher loop running in the gateway.
- `gateway/run.py:5169-5176` calls `kanban_db.dispatch_once(...)` for each board.
- `gateway/run.py:5354-5371` executes dispatcher ticks repeatedly and logs how many workers were spawned on a tick.
- `hermes_cli/kanban_db.py:4587-4625` documents `dispatch_once(...)` as the dispatcher tick that reclaims stale/crashed tasks, promotes ready tasks, atomically claims them, and calls `spawn_fn(task, workspace_path, board)`.
- `hermes_cli/kanban_db.py:4615-4621` explicitly defines `max_spawn` as a live concurrency cap over currently running tasks plus this tick's spawns.
- `hermes_cli/kanban_db.py:4692-4714` iterates over all ready tasks and spawns workers until the concurrency cap is reached.
- `hermes_cli/kanban_swarm.py:3-14` states that Kanban Swarm does not introduce a second scheduler; it writes a task graph into the existing Kanban kernel.
- `hermes_cli/kanban_swarm.py:6-9` shows the topology including parallel specialist workers.

Conclusion:

Kanban dispatch is designed to have multiple runnable tasks claimed and launched concurrently, subject to explicit concurrency caps. That is real parallel worker orchestration.

### 4. Kanban task claiming is durable and independent of any parent agent turn

Kanban task ownership is coordinated in SQLite, not in an in-memory parent/child stack.

Evidence:

- `hermes_cli/kanban_db.py:61-68` describes the concurrency strategy: WAL mode, `BEGIN IMMEDIATE`, and compare-and-swap updates on task status and claim fields.
- `hermes_cli/kanban_db.py:2041-2152` implements `claim_task(...)`, which atomically moves a task from `ready` to `running`, sets `claim_lock`, `claim_expires`, creates a `task_runs` record, and appends a `claimed` event.
- `hermes_cli/kanban_db.py:2230-2258` implements `heartbeat_claim(...)` so a running worker can extend its claim.
- `hermes_cli/kanban_db.py:2261-2371` implements `release_stale_claims(...)`, which reclaims expired tasks and can terminate reclaimed workers.
- `hermes_cli/kanban_db.py:1997-2034` implements `recompute_ready(...)`, promoting dependent tasks when parent tasks are done.

Conclusion:

Kanban work ownership is persisted in the board database and survives beyond a single agent turn. That is incompatible with describing the system as merely a main agent and its subagents within one in-memory execution.

### 5. Kanban workers are supervised as independent processes via PID tracking and crash detection

The source does more than spawn workers: it supervises them as OS processes.

Evidence:

- `hermes_cli/kanban_db.py:4418-4436` stores each spawned worker PID via `_set_worker_pid(...)` and appends a `spawned` event containing the PID.
- `hermes_cli/kanban_db.py:4108-4125` defines `detect_crashed_workers(...)` and explains that it reclaims running tasks whose worker PID is no longer alive.
- `hermes_cli/kanban_db.py:4135-4203` checks `worker_pid`, tests liveness, records crash/protocol-violation events, and resets tasks back to `ready` when appropriate.
- `hermes_cli/kanban_db.py:4587-4647` documents that `dispatch_once(...)` also reaps zombie children and records exit status for spawned workers.
- `website/docs/user-guide/features/kanban.md:69` states that the dispatcher reclaims stale claims, reclaims crashed workers, promotes ready tasks, atomically claims tasks, and spawns assigned profiles.

Conclusion:

Kanban workers are managed as independent long-lived worker processes, not as ephemeral child reasoning calls hidden inside a parent agent loop.

### 6. Kanban workers operate through a dedicated board tool surface, not through parent-context subagent returns

Workers do not report by returning a value to a parent agent call. They interact with the board through dedicated Kanban lifecycle tools.

Evidence:

- `tools/kanban_tools.py:1-27` describes Kanban tools as the structured tool-call surface for worker and orchestrator agents.
- `tools/kanban_tools.py:62-77` gates worker lifecycle tools on `HERMES_KANBAN_TASK` or explicit Kanban orchestrator configuration.
- `tools/kanban_tools.py:132-161` enforces that a dispatcher-spawned worker may only mutate its own assigned task through tools like `kanban_complete`, `kanban_block`, and `kanban_heartbeat`.
- `website/docs/user-guide/features/kanban.md:232-246` explains that workers do not shell out to `hermes kanban`; they use `kanban_show`, `kanban_complete`, `kanban_block`, `kanban_heartbeat`, `kanban_comment`, `kanban_create`, `kanban_link`, and `kanban_unblock`.
- `website/docs/user-guide/features/kanban.md:248-260` shows a typical worker lifecycle as board tool calls rather than a return to a parent caller.

Conclusion:

Kanban workers communicate through durable board state transitions and comments, not by returning ephemeral subagent summaries into a parent agent's context.

### 7. `delegate_task` is a separate multi-agent mechanism built from in-process child `AIAgent` instances

Hermes does also support subagent-based multi-agent execution, but through a different subsystem.

Evidence:

- `tools/delegate_tool.py:3-17` describes `delegate_task` as spawning child `AIAgent` instances with isolated context, their own terminal sessions, and parent-visible summary-only results.
- `tools/delegate_tool.py:1106-1137` constructs each child directly as an `AIAgent(...)` instance.
- `tools/delegate_tool.py:1918-1942` defines `delegate_task(...)` as the public tool entry point for spawning one or more child agents.
- `website/docs/user-guide/features/delegation.md:9-10` states that `delegate_task` spawns child `AIAgent` instances with isolated context and that only their final summary enters the parent's context.
- `toolsets.py:227-230` defines a separate `delegation` toolset containing `delegate_task`.

Conclusion:

Hermes clearly supports a subagent implementation for multi-agent work, but that implementation is `delegate_task`, not Kanban.

### 8. `delegate_task` supports concurrent subagents, but they remain children of the parent turn

The source confirms that `delegate_task` can run multiple subagents concurrently, while still remaining an in-process parent/child mechanism.

Evidence:

- `tools/delegate_tool.py:329-364` reads `delegation.max_concurrent_children`, establishing an explicit concurrency limit for delegated children.
- `tools/delegate_tool.py:2051-2089` builds all child agents on the main thread before execution.
- `tools/delegate_tool.py:2097-2112` uses `ThreadPoolExecutor(max_workers=max_children)` and submits `_run_single_child(...)` for batch tasks.
- `tools/delegate_tool.py:2163-2213` waits for child futures to complete and sorts results back into task order.
- `website/docs/user-guide/features/delegation.md:122-129` documents that batch mode runs subagents in parallel using a thread pool.
- `website/docs/user-guide/features/delegation.md:224-235` explicitly states that `delegate_task` is synchronous, runs inside the parent's current turn, blocks the parent until children finish, and is not durable.

Conclusion:

`delegate_task` is genuinely multi-agent in the sense that it can run multiple child agents concurrently, but it is still an in-process subagent system tied to the parent turn.

### 9. Hermes explicitly documents Kanban and `delegate_task` as coexisting but different mechanisms

The documentation directly supports the interpretation shown by the code.

Evidence:

- `website/docs/user-guide/features/kanban.md:22-29` says Kanban covers workloads `delegate_task` cannot.
- `website/docs/user-guide/features/kanban.md:36-47` presents a direct comparison table between the two systems.
- `website/docs/user-guide/features/kanban.md:53` states that they coexist and that a Kanban worker may call `delegate_task` internally during its run.
- `website/docs/user-guide/features/delegation.md:224-235` states that durable long-running work should use other mechanisms rather than `delegate_task`.

Conclusion:

Hermes itself treats these as two separate orchestration primitives, not as two descriptions of the same internal mechanic.

## Mechanism comparison

### A. Kanban multi-agent mechanics

- Execution unit: separate Hermes worker process
- Spawn path: dispatcher claims task from SQLite, launches worker via `subprocess.Popen(...)`
- Parallelism: yes, across multiple ready/review tasks up to configured concurrency caps
- Durability: yes, task state persists in SQLite across turns and restarts
- Coordination medium: shared board rows, task comments, task events, task runs
- Worker identity: named profile plus OS PID plus task/run identity
- Parent-child relationship: no single parent turn waiting for all workers to return

### B. `delegate_task` multi-agent mechanics

- Execution unit: child `AIAgent` instance
- Spawn path: parent tool call constructs child agents in-process
- Parallelism: yes, through `ThreadPoolExecutor` in batch mode
- Durability: no, tied to the parent turn
- Coordination medium: parent passes goal/context; child returns summary
- Worker identity: subagent under the parent session
- Parent-child relationship: yes, parent blocks until children finish

## Overall conclusion

The source code supports the two requested conclusions.

1. Hermes Agent's Kanban multi-agent mechanics support real parallel process-based execution. The dispatcher claims tasks from a durable SQLite board, spawns workers as separate Hermes OS processes with `subprocess.Popen(...)`, records and supervises their PIDs, and coordinates them through persistent task state rather than through a parent agent's in-memory child list. This is not merely a main agent with child/subagent calls.

2. Hermes Agent also supports a second multi-agent mechanism through `delegate_task`. That path creates child `AIAgent` instances in-process, can run them concurrently via a thread pool, and returns their summaries to the parent. This is the subagent-based implementation of multi-agent behavior.

The most accurate research framing is therefore: Hermes has two distinct multi-agent mechanics. Kanban is the durable process-based coordination system for real cross-agent parallel work, while `delegate_task` is the synchronous in-process subagent mechanism.

## Sources

- `/home/ubuntu/.hermes/hermes-agent/gateway/run.py`
- `/home/ubuntu/.hermes/hermes-agent/hermes_cli/kanban.py`
- `/home/ubuntu/.hermes/hermes-agent/hermes_cli/kanban_db.py`
- `/home/ubuntu/.hermes/hermes-agent/hermes_cli/kanban_swarm.py`
- `/home/ubuntu/.hermes/hermes-agent/tools/kanban_tools.py`
- `/home/ubuntu/.hermes/hermes-agent/tools/delegate_tool.py`
- `/home/ubuntu/.hermes/hermes-agent/toolsets.py`
- `/home/ubuntu/.hermes/hermes-agent/website/docs/user-guide/features/kanban.md`
- `/home/ubuntu/.hermes/hermes-agent/website/docs/user-guide/features/delegation.md`
