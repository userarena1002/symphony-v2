# Symphony Reimplementation Plan

## Document Purpose

This is the comprehensive architecture and implementation plan for rebuilding Symphony from the OpenAI upstream fork into a custom dev workflow orchestrator optimized for context reuse, live observability, human-in-the-loop editing, and lean agent execution.

---

## Table of Contents

1. [What Symphony Is Today](#1-what-symphony-is-today)
2. [Problems With the Current Architecture](#2-problems-with-the-current-architecture)
3. [What We Want Symphony to Be](#3-what-we-want-symphony-to-be)
4. [Architecture Overview](#4-architecture-overview)
5. [Component Design](#5-component-design)
6. [Linear Workflow States](#6-linear-workflow-states)
7. [Data Models](#7-data-models)
8. [Implementation Phases](#8-implementation-phases)
9. [Phase 1: Headless CLI Execution Backend](#phase-1-headless-cli-execution-backend)
10. [Phase 2: Event Streaming & Live Dashboard](#phase-2-event-streaming--live-dashboard)
11. [Phase 3: Session Persistence & Edit Column](#phase-3-session-persistence--edit-column)
12. [Phase 4: Memory Registry & Context Injection](#phase-4-memory-registry--context-injection)
13. [Phase 5: LLM Router](#phase-5-llm-router)
14. [Phase 6: Dashboard Polish & UI Rendering](#phase-6-dashboard-polish--ui-rendering)
15. [Technical Decisions](#10-technical-decisions)
16. [Open Questions](#11-open-questions)
17. [File Structure](#12-file-structure)

---

## 1. What Symphony Is Today

Symphony (upstream from OpenAI) is a long-running Elixir/OTP daemon that:

- **Polls Linear** via GraphQL for issues in active states (e.g., "Todo", "In Progress")
- **Dispatches coding agents** (Codex) to work on each issue in isolated per-issue workspaces
- **Uses the Codex app-server protocol** — a JSON-RPC 2.0 stream over stdio where every tool call (file read, file write, shell command) is a round-trip through the orchestrator
- **Manages concurrency** — configurable limits (global and per-state), priority-based dispatch
- **Retries on failure** — exponential backoff with stall detection
- **Provides basic observability** — terminal ANSI dashboard, optional Phoenix LiveView dashboard, JSON API

### Key Upstream Modules

| Module | Purpose |
|--------|---------|
| `Orchestrator` (GenServer) | Main poll loop, dispatch, retry, reconciliation |
| `AgentRunner` (Task) | Spawns per-issue, manages Codex turn loop |
| `Codex.AppServer` | JSON-RPC client for Codex app-server protocol |
| `Workspace` | Per-issue directory creation, lifecycle hooks |
| `Linear.Client` | GraphQL queries to Linear API |
| `WorkflowStore` | Watches WORKFLOW.md, hot-reloads config |
| `Config.Schema` | Typed config parsing from WORKFLOW.md YAML |
| `PromptBuilder` | Solid/Liquid template rendering for issue prompts |
| `StatusDashboard` | Terminal ANSI UI |
| `HttpServer` | Phoenix LiveView web dashboard |
| `LogFile` | Structured JSON logging per issue |

### How It Works (Current Flow)

```
Linear poll → fetch active issues → sort by priority → dispatch eligible
    ↓
Create workspace → run hooks → start Codex app-server subprocess
    ↓
JSON-RPC handshake: initialize → initialized → thread/start → turn/start
    ↓
Stream tool calls back and forth between Symphony and Codex
    ↓
Turn completes → check if issue still active → continue or exit
    ↓
On exit: normal → 1s continuation retry; error → exponential backoff
```

### What Does NOT Exist in Upstream

- No session registry or memory of past sessions
- No session reuse or routing
- No thread resumption
- No human-in-the-loop message injection
- No "Edit" column or rework-without-fresh-context flow
- No per-feature preview ports
- No real-time tool call streaming to dashboard (only last event summary)
- Dashboard shows one-line status per agent, not expandable live streams

---

## 2. Problems With the Current Architecture

### 2.1 Context Waste

Every issue dispatch creates a brand new Codex thread. The agent spends its first several turns exploring the codebase — reading project structure, understanding conventions, finding relevant files. This happens every single time, even if the previous issue touched the exact same code.

**Cost**: Wasted tokens, wasted time, slower issue throughput.

### 2.2 App-Server Protocol Overhead

The JSON-RPC app-server approach means every tool call (read file, edit file, run command) is:
1. Codex emits a tool call request → serialized as JSON-RPC message
2. Symphony receives it, processes it, sends back a result
3. Each round-trip is logged into the thread history

For a simple "change button color" task, the agent might do 5+ tool call round trips, each adding JSON payload to the conversation history. This bloats the context window for what should be trivial work.

**Cost**: Inflated context, slower execution, more tokens burned on protocol overhead.

### 2.3 No Human-in-the-Loop

When an agent completes work and the issue moves to "Human Review":
- The Codex subprocess is dead (port closed)
- The thread is gone (no persistence)
- If the user finds a small issue, the only option is "Rework" which starts completely fresh

There's no way to say "just change this one thing" without burning a full fresh context.

**Cost**: Massive inefficiency for small corrections, frustrating developer experience.

### 2.4 Blind Orchestration

The dashboard shows `last_codex_event` — a single line per agent. You can't see what the agent is actually doing, what files it's reading, what code it's writing, or what it's thinking. The `summarize_codex_update` function in the orchestrator discards everything except the latest event.

**Cost**: No visibility, can't catch problems early, can't learn from agent behavior.

### 2.5 No Edit-Without-Rework Path

The Linear state machine is: Todo → In Progress → Human Review → Done (or Rework → back to Todo). There's no intermediate state for "make a small tweak to what you already did." Rework means full restart.

**Cost**: Disproportionate cost for small changes.

---

## 3. What We Want Symphony to Be

### Core Principles

1. **Lean execution** — Tool calls happen inside the agent process, not marshalled through an orchestrator protocol. Minimal context overhead.
2. **Session memory** — Every completed session is recorded with what it learned and what it touched. Future sessions can build on prior knowledge.
3. **Human-in-the-loop** — Users can watch agents work in real time, jump into any session to provide guidance, and trigger small edits without full rework.
4. **Smart routing** — An LLM-backed router decides whether a new issue should start fresh or resume/build on an existing session.
5. **Full observability** — Expandable per-agent live streams showing every tool call, file edit, and thought in real time.
6. **Edit column workflow** — A dedicated Linear state for "apply these small changes to existing work" that reuses the prior session.

### Target Developer Workflow

```
1. Developer creates issues on Linear board
2. Symphony polls, picks up issues, spawns headless CLI agents
3. Developer opens dashboard, sees all agents working in real time
4. Developer clicks into any agent → sees live tool calls, file diffs, reasoning
5. Agent completes → moves issue to "Human Review"
6. Developer tests via preview port exposed per feature
7. Small tweak needed → developer adds comments to Linear ticket
8. Developer drags issue to "Edit" column
9. Symphony picks it up, resumes the SAME session, agent reads comments and makes changes
10. Agent moves issue back to "Human Review"
11. Developer approves → merges → issue moves to "Done"
12. Session data saved to memory registry for future context reuse
```

---

## 4. Architecture Overview

```
                         ┌──────────────────┐
                         │   Linear Board    │
                         │                   │
                         │ Todo | In Progress│
                         │ Human Review      │
                         │ Edit | Done       │
                         └────────┬──────────┘
                                  │ GraphQL poll
                                  ▼
                         ┌──────────────────┐
                         │   Orchestrator    │
                         │   (GenServer)     │
                         │                   │
                         │ • Poll & dispatch │
                         │ • Concurrency mgmt│
                         │ • Retry/backoff   │
                         │ • Reconciliation  │
                         │ • Route decisions │
                         └────────┬──────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
              ┌───────────┐┌───────────┐┌───────────┐
              │ CLI Worker ││ CLI Worker ││ CLI Worker │
              │ (Task)     ││ (Task)     ││ (Task)     │
              │            ││            ││            │
              │ headless   ││ headless   ││ headless   │
              │ --stream   ││ --stream   ││ --stream   │
              └─────┬──────┘└─────┬──────┘└─────┬──────┘
                    │             │             │
                    ▼             ▼             ▼
              [workspace]   [workspace]   [workspace]
              + preview     + preview     + preview
                    │             │             │
                    └─────────────┼─────────────┘
                                  │ stream-json events
                                  ▼
                         ┌──────────────────┐
                         │    Event Bus     │
                         │  (Phoenix PubSub) │
                         │                   │
                         │ topic per issue:  │
                         │ "agent:ABC-123"   │
                         └────────┬──────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
              ┌───────────┐┌───────────┐┌───────────┐
              │ Dashboard  ││  Memory   ││  Log      │
              │ (LiveView) ││ Registry  ││  Files    │
              │            ││ (SQLite)  ││           │
              │ • Agent    ││           ││           │
              │   list     ││ • Session ││ • Per-    │
              │ • Expand   ││   records ││   issue   │
              │   streams  ││ • File    ││   JSON    │
              │ • Chat     ││   touch   ││   logs    │
              │   input    ││ • Summary ││           │
              │ • Preview  ││ • Scores  ││           │
              │   links    ││           ││           │
              └────────────┘└───────────┘└───────────┘
```

---

## 5. Component Design

### 5.1 Headless CLI Execution Backend (Multi-Agent)

**Replaces**: `Codex.AppServer` (JSON-RPC client)

**What it does**: Spawns a coding agent CLI in headless/non-interactive mode with streaming JSON output. All tool calls happen internally within the agent process — no round-trip marshalling. Supports multiple agent backends (Claude Code, Codex, or others) via a pluggable adapter layer.

**Design principle**: The system is **agent-agnostic**. All agents follow the same fundamental pattern: accept a prompt, do work autonomously, output structured events, exit when done. The differences (CLI flags, output JSON schema, resume mechanism) are isolated in thin adapters. Everything downstream — orchestrator, event bus, dashboard, memory, router — works with normalized events only.

#### Architecture

```
WORKFLOW.md:  agent.backend: "claude" | "codex"
                        │
                        ▼
              ┌──────────────────┐
              │  HeadlessCLI     │  ← backend-agnostic process manager
              │  (start/resume/  │
              │   stop/stream)   │
              └────────┬─────────┘
                       │ delegates to
                       ▼
              ┌──────────────────┐
              │  AgentAdapter    │  ← behaviour (interface contract)
              │  (behaviour)     │
              └────────┬─────────┘
                       │
            ┌──────────┼──────────┐
            ▼                     ▼
   ┌─────────────────┐  ┌─────────────────┐
   │ ClaudeAdapter   │  │ CodexAdapter    │
   │                 │  │                 │
   │ • build_command │  │ • build_command │
   │ • parse_event   │  │ • parse_event   │
   │ • resume_args   │  │ • resume_args   │
   │ • session_id    │  │ • session_id    │
   └─────────────────┘  └─────────────────┘
            │                     │
            ▼                     ▼
   Normalized Event struct ← everything downstream uses this
```

#### Agent Adapter Behaviour

```elixir
defmodule Symphony.ExecutionBackend.AgentAdapter do
  @doc "Build the shell command to start a new session"
  @callback build_command(workspace :: Path.t(), prompt :: String.t(), opts :: keyword()) ::
    String.t()

  @doc "Build the shell command to resume an existing session"
  @callback build_resume_command(workspace :: Path.t(), session_id :: String.t(), prompt :: String.t(), opts :: keyword()) ::
    String.t()

  @doc "Parse a raw JSON line from agent stdout into a normalized event"
  @callback parse_event(raw_json :: map()) ::
    {:ok, Symphony.Event.t()} | {:skip, reason :: atom()} | {:error, term()}

  @doc "Extract session ID from the agent's initialization output"
  @callback extract_session_id(raw_json :: map()) ::
    {:ok, String.t()} | :not_found

  @doc "Determine if a raw event signals turn/session completion"
  @callback completion_signal?(raw_json :: map()) ::
    :running | :completed | :failed | {:error, term()}

  @doc "Return the agent name for logging and display"
  @callback agent_name() :: String.t()
end
```

#### Claude Code Adapter

```elixir
defmodule Symphony.ExecutionBackend.Adapters.Claude do
  @behaviour Symphony.ExecutionBackend.AgentAdapter

  @impl true
  def build_command(workspace, prompt, opts) do
    allowed_tools = Keyword.get(opts, :allowed_tools, "Read,Write,Edit,Bash,Glob,Grep")
    max_turns = Keyword.get(opts, :max_turns, 20)

    ~s(claude -p #{shell_escape(prompt)} ) <>
    ~s(--output-format stream-json ) <>
    ~s(--allowedTools "#{allowed_tools}" ) <>
    ~s(--max-turns #{max_turns} ) <>
    ~s(--cwd #{shell_escape(workspace)} ) <>
    ~s(2>/dev/null)
  end

  @impl true
  def build_resume_command(workspace, session_id, prompt, opts) do
    ~s(claude --resume #{shell_escape(session_id)} ) <>
    ~s(-p #{shell_escape(prompt)} ) <>
    ~s(--output-format stream-json ) <>
    ~s(--cwd #{shell_escape(workspace)} ) <>
    ~s(2>/dev/null)
  end

  @impl true
  def parse_event(%{"type" => "assistant", "message" => msg} = raw) do
    {:ok, %Symphony.Event{
      type: :assistant,
      content: %{message: msg},
      raw: raw,
      timestamp: Map.get(raw, "timestamp")
    }}
  end
  def parse_event(%{"type" => "tool_use", "tool" => tool, "input" => input} = raw) do
    {:ok, %Symphony.Event{
      type: :tool_use,
      content: %{tool: tool, input: input},
      raw: raw,
      timestamp: Map.get(raw, "timestamp")
    }}
  end
  def parse_event(%{"type" => "tool_result"} = raw) do
    {:ok, %Symphony.Event{
      type: :tool_result,
      content: %{tool: Map.get(raw, "tool"), output: Map.get(raw, "output"),
                 success: Map.get(raw, "is_error") != true},
      raw: raw,
      timestamp: Map.get(raw, "timestamp")
    }}
  end
  def parse_event(%{"type" => "system", "subtype" => subtype} = raw) do
    {:ok, %Symphony.Event{
      type: :system,
      content: %{subtype: String.to_atom(subtype), result: Map.get(raw, "result")},
      raw: raw,
      timestamp: Map.get(raw, "timestamp")
    }}
  end
  def parse_event(_raw), do: {:skip, :unrecognized}

  @impl true
  def extract_session_id(%{"type" => "system", "subtype" => "init", "session_id" => id}),
    do: {:ok, id}
  def extract_session_id(_), do: :not_found

  @impl true
  def completion_signal?(%{"type" => "system", "subtype" => "done", "result" => "success"}), do: :completed
  def completion_signal?(%{"type" => "system", "subtype" => "done"}), do: :failed
  def completion_signal?(_), do: :running

  @impl true
  def agent_name, do: "Claude Code"
end
```

#### Codex Adapter

```elixir
defmodule Symphony.ExecutionBackend.Adapters.Codex do
  @behaviour Symphony.ExecutionBackend.AgentAdapter

  @impl true
  def build_command(workspace, prompt, opts) do
    # Codex headless mode (flags TBD based on Codex CLI docs)
    ~s(codex -q --json ) <>
    ~s(-p #{shell_escape(prompt)} ) <>
    ~s(--cwd #{shell_escape(workspace)} ) <>
    ~s(--approval-mode full-auto ) <>
    ~s(2>/dev/null)
  end

  @impl true
  def build_resume_command(workspace, session_id, prompt, _opts) do
    ~s(codex --resume #{shell_escape(session_id)} ) <>
    ~s(-q --json ) <>
    ~s(-p #{shell_escape(prompt)} ) <>
    ~s(--cwd #{shell_escape(workspace)} ) <>
    ~s(2>/dev/null)
  end

  @impl true
  def parse_event(raw) do
    # Normalize Codex's event schema to Symphony.Event
    # Codex may use different field names — map them here
    # This adapter will be refined once we test against actual Codex headless output
    normalize_codex_event(raw)
  end

  @impl true
  def extract_session_id(%{"session" => %{"id" => id}}), do: {:ok, id}
  def extract_session_id(_), do: :not_found

  @impl true
  def completion_signal?(%{"type" => "turn_completed"}), do: :completed
  def completion_signal?(%{"type" => "turn_failed"}), do: :failed
  def completion_signal?(_), do: :running

  @impl true
  def agent_name, do: "Codex"
end
```

#### HeadlessCLI (Backend-Agnostic Process Manager)

```elixir
defmodule Symphony.ExecutionBackend.HeadlessCLI do
  @spec start(workspace :: Path.t(), prompt :: String.t(), opts :: keyword()) ::
    {:ok, %{port: port(), session_ref: reference(), adapter: module()}}

  @spec resume(workspace :: Path.t(), session_id :: String.t(), prompt :: String.t(), opts :: keyword()) ::
    {:ok, %{port: port(), session_ref: reference(), adapter: module()}}

  @spec stop(port :: port()) :: :ok

  def start(workspace, prompt, opts \\ []) do
    adapter = resolve_adapter(opts)
    command = adapter.build_command(workspace, prompt, opts)
    port = spawn_port(workspace, command)
    {:ok, %{port: port, session_ref: make_ref(), adapter: adapter}}
  end

  def resume(workspace, session_id, prompt, opts \\ []) do
    adapter = resolve_adapter(opts)
    command = adapter.build_resume_command(workspace, session_id, prompt, opts)
    port = spawn_port(workspace, command)
    {:ok, %{port: port, session_ref: make_ref(), adapter: adapter}}
  end

  defp resolve_adapter(opts) do
    case Keyword.get(opts, :backend, Config.settings!().agent.backend) do
      "claude" -> Symphony.ExecutionBackend.Adapters.Claude
      "codex"  -> Symphony.ExecutionBackend.Adapters.Codex
      other    -> raise "Unknown agent backend: #{other}"
    end
  end

  defp spawn_port(workspace, command) do
    Port.open(
      {:spawn_executable, System.find_executable("bash") |> to_charlist()},
      [:binary, :exit_status, :stderr_to_stdout,
       args: [~c"-lc", to_charlist(command)],
       cd: to_charlist(workspace),
       line: 1_048_576]
    )
  end
end
```

#### WORKFLOW.md Config

```yaml
agent:
  backend: claude                    # "claude" | "codex" — which CLI agent to use
  command_override: null             # optional: override the auto-built command entirely
  allowed_tools:                     # tools the agent can use (Claude Code format)
    - Read
    - Write
    - Edit
    - Bash
    - Glob
    - Grep
  mode: headless                     # headless (only mode for now; interactive reserved for future)
  session_timeout_ms: 3600000        # max time per session
  max_turns: 20                      # max continuation turns per dispatch
  auto_approve: true                 # skip permission prompts
```

#### Normalized Event Struct (What Everything Downstream Uses)

```elixir
defmodule Symphony.Event do
  @type event_type :: :assistant | :tool_use | :tool_result | :system | :user | :error

  @type t :: %__MODULE__{
    type: event_type(),
    content: map(),              # type-specific fields
    raw: map(),                  # original JSON from agent (preserved for debugging)
    timestamp: DateTime.t(),
    issue_id: String.t() | nil,  # set by AgentRunner when broadcasting
    session_id: String.t() | nil
  }

  defstruct [:type, :content, :raw, :timestamp, :issue_id, :session_id]
end
```

#### Adding a New Agent Backend

To add support for a new coding agent (e.g., Cursor, Aider, etc.):

1. Create `Symphony.ExecutionBackend.Adapters.NewAgent` implementing the `AgentAdapter` behaviour
2. Map the agent's CLI flags in `build_command/3` and `build_resume_command/4`
3. Normalize the agent's output JSON in `parse_event/1`
4. Add `"new_agent"` to the `resolve_adapter/1` match
5. No changes needed to orchestrator, dashboard, memory, or router

**Estimated effort per new adapter**: 50-100 lines of Elixir.

### 5.2 Event Bus

**New component** — broadcasts raw agent events to subscribers.

**What it does**: Each CLI worker pushes stream-json events into a PubSub topic keyed by issue ID. The dashboard, memory registry, and log writer all subscribe.

**Topics**:
- `"agent:events:<issue_id>"` — raw stream events from CLI worker
- `"agent:lifecycle:<issue_id>"` — high-level state changes (started, completed, failed, stalled)
- `"orchestrator:state"` — overall system state updates (for dashboard overview)

**Implementation**: Thin wrapper around existing `Phoenix.PubSub`. The CLI worker's event reader broadcasts each parsed JSON line.

### 5.3 Dashboard (LiveView Web App)

**Replaces**: Terminal ANSI `StatusDashboard` + existing barebones LiveView

**What it does**: Full web dashboard showing all agents, expandable live streams, chat input for human-in-the-loop, and preview links.

**Views**:

#### Overview (default)
```
┌─────────────────────────────────────────────────────────────────┐
│  Symphony Dashboard                              ⟳ 5s ago      │
├─────────────────────────────────────────────────────────────────┤
│  Running: 3/10    │  Retry Queue: 1    │  Tokens: 125.4K      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ▶ ABC-123  In Progress  "Add token refresh"     2m 12s  3.2K │
│  ▶ ABC-125  In Progress  "Fix nav alignment"       45s  1.1K  │
│  ▶ ABC-126  Edit         "Update button color"      8s  0.2K  │
│                                                                 │
│  ⏳ ABC-124  Retry in 18s  "Add search filter"                  │
│                                                                 │
│  ✓ ABC-120  Done  "Auth middleware rewrite"  12m  45.2K tokens │
│  ✓ ABC-121  Done  "API rate limiting"         8m  32.1K tokens │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### Expanded Agent View (click any row)
```
┌─────────────────────────────────────────────────────────────────┐
│  ABC-123: Add token refresh endpoint             ▾ Collapse    │
│  Session: sess_abc123  │  Turn: 2/20  │  Tokens: 3.2K         │
│  Preview: http://localhost:4123                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  14:23:01  Reading src/auth/token.ex                           │
│  14:23:02  "I can see the token module uses RS256 signing.     │
│            I'll add the refresh endpoint after the verify       │
│            function..."                                         │
│  14:23:05  Editing src/auth/token.ex (lines 45-67)             │
│            + def refresh(token, opts \\ []) do                  │
│            +   with {:ok, claims} <- verify(token) do           │
│            +     issue(%{claims | exp: new_expiry()}, opts)     │
│            +   end                                              │
│            + end                                                │
│  14:23:08  Running: mix test test/auth/token_test.exs          │
│  14:23:12  ✓ 14 tests, 0 failures                              │
│  14:23:13  "All tests pass. I'll now update the router..."     │
│                                                                 │
│  ▌ (streaming...)                                               │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  💬 Type a message to this agent...                    [Send]  │
└─────────────────────────────────────────────────────────────────┘
```

**Chat input**: When the user types a message and hits Send:
1. If the agent is currently running → queue the message, inject at next turn boundary
2. If the agent has finished (Human Review) → trigger a session resume with the message as prompt
3. Message appears in the live stream as a user message

### 5.4 Memory Registry (SQLite)

**New component** — persistent store of all session metadata for routing and context reuse.

**What it does**: Records what each session worked on, what files it touched, whether it succeeded, and a semantic summary of what it learned.

**Tables**:

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,            -- session_id from CLI
  issue_id TEXT NOT NULL,
  issue_identifier TEXT NOT NULL, -- e.g., "ABC-123"
  thread_id TEXT,                 -- for potential thread resumption
  workspace_path TEXT,
  status TEXT NOT NULL,           -- running, succeeded, failed, stalled
  started_at TEXT NOT NULL,       -- ISO-8601
  completed_at TEXT,
  total_tokens INTEGER DEFAULT 0,
  turn_count INTEGER DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE session_files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  file_path TEXT NOT NULL,
  action TEXT NOT NULL,           -- read, write, edit, create, delete
  timestamp TEXT NOT NULL
);

CREATE TABLE session_summaries (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id),
  summary TEXT NOT NULL,          -- semantic summary of what was done
  codebase_areas TEXT,            -- JSON array of module/directory areas
  key_learnings TEXT,             -- what the agent discovered about the codebase
  reusability_score REAL,         -- 0.0 to 1.0, how reusable this session is
  generated_at TEXT NOT NULL
);

CREATE INDEX idx_sessions_issue ON sessions(issue_id);
CREATE INDEX idx_sessions_status ON sessions(status);
CREATE INDEX idx_session_files_path ON session_files(file_path);
CREATE INDEX idx_session_files_session ON session_files(session_id);
```

**Data collection**: The event bus subscriber extracts file paths from tool_use events and records them in `session_files`. On session completion, a summary is generated (either extracted heuristically or via LLM call).

### 5.5 LLM Router

**New component** — decides whether a new issue should start a fresh session or build on an existing one.

**When it runs**: After the orchestrator selects an issue for dispatch, before spawning the CLI worker.

**Decision flow**:

```
1. Extract signals from new issue:
   - Title, description, labels
   - File paths mentioned in description
   - Module/area keywords

2. Query memory registry:
   - Recent successful sessions (last 7 days)
   - Sessions that touched similar files
   - Sessions in the same codebase area

3. Score candidates:
   - file_overlap_score (0-1): % of mentioned files touched by candidate
   - area_overlap_score (0-1): shared codebase areas
   - recency_score (0-1): exponential decay, recent = higher
   - health_score (0-1): succeeded = 1.0, failed = 0.3
   - size_penalty (0-1): very large sessions = lower (context may be degraded)

4. Composite score:
   score = (file_overlap * 0.35) + (area_overlap * 0.25) +
           (recency * 0.20) + (health * 0.10) + (size_penalty * 0.10)

5. Decision:
   - If top candidate score > 0.7 → reuse (inject context summary)
   - If top candidate score > 0.5 AND < 0.7 → ask LLM to decide
   - If top candidate score < 0.5 → new session

6. For LLM decision (ambiguous cases only):
   - Send issue context + top 3 candidate summaries to a fast model
   - Ask: "Should this issue start fresh or build on one of these prior sessions?"
   - Model returns: {decision: "reuse" | "new", session_id?: "...", reasoning: "..."}
```

**Context injection** (when reusing):
Instead of actual thread resumption (which requires the subprocess to still be alive), prepend the new issue prompt with prior session knowledge:

```
## Prior Context (from session on ABC-120)

A previous session working on related code established the following context:

### Codebase Knowledge
- Auth module: src/auth/token.ex (JWT with RS256, refresh via rotating keys)
- API routes: src/api/routes.ex (RESTful, Phoenix router, versioned under /api/v1)
- Test runner: mix test, CI requires 80% coverage
- Database: PostgreSQL via Ecto, migrations in priv/repo/migrations/

### Files Modified
- src/auth/token.ex — Added token refresh endpoint
- src/auth/middleware.ex — Updated auth pipeline for refresh flow
- test/auth/token_test.exs — Added 6 new test cases

### Summary
Implemented JWT token refresh with rate limiting. Discovered that the existing
verify/1 function already handles key rotation, so refresh can delegate to it.

---

## Your Current Task

Issue ABC-124: {{ issue.title }}
{{ issue.description }}

Build on the above context where relevant. Do not re-explore files and patterns
already documented above unless you need to verify they haven't changed.
```

This gives the new agent a running start without any protocol-level thread resumption. The agent skips the "what is this codebase?" phase and goes straight to working.

### 5.6 Preview Manager

**Adapted from existing work** — assigns an ephemeral port per workspace and starts a dev server.

**How it works**:
1. In `hooks.after_create` or `hooks.before_run`: check if workspace has a dev server script
2. Start dev server on an assigned port (port range: 4100-4199)
3. Register port → issue mapping in orchestrator state
4. Dashboard shows preview link per agent
5. On workspace cleanup: kill the preview server, release the port

---

## 6. Linear Workflow States

### State Configuration

```yaml
tracker:
  active_states:
    - Todo
    - In Progress
    - Edit          # NEW: reuse existing session
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
  review_states:     # NEW: informational, not dispatched
    - Human Review
```

### State Machine

```
                    ┌──────────┐
                    │   Todo   │
                    └────┬─────┘
                         │ Symphony dispatches (new session)
                         ▼
                    ┌──────────┐
                    │   In     │
                    │ Progress │
                    └────┬─────┘
                         │ Agent completes work
                         ▼
                    ┌──────────┐
         ┌─────────│  Human   │──────────┐
         │         │  Review  │          │
         │         └──────────┘          │
         │ User approves                 │ User wants tweaks
         ▼                               ▼
    ┌──────────┐                    ┌──────────┐
    │   Done   │                    │   Edit   │
    └──────────┘                    └────┬─────┘
                                         │ Symphony dispatches
                                         │ (REUSE session)
                                         ▼
                                    ┌──────────┐
                                    │   In     │ (agent reads comments,
                                    │ Progress │  makes tweaks)
                                    └────┬─────┘
                                         │ Agent completes
                                         ▼
                                    ┌──────────┐
                                    │  Human   │
                                    │  Review  │
                                    └──────────┘
```

### Edit Column Logic

When the orchestrator encounters an issue in "Edit" state:

1. Query memory registry for the most recent successful session on this `issue_id`
2. If found:
   - Fetch latest comments from Linear (via GraphQL)
   - Build a continuation prompt: "Read the following feedback comments and make the requested changes: [comments]"
   - Resume the prior session (via `--resume <session_id>` or context injection)
3. If not found (edge case):
   - Treat as new dispatch with full prompt
   - Log a warning (shouldn't happen in normal flow)
4. After completion:
   - Agent (or hook) moves issue back to "Human Review"
   - Session record updated in registry

---

## 7. Data Models

### Orchestrator Running Entry (Enhanced)

```elixir
%{
  # Existing fields
  pid: pid(),
  ref: reference(),
  identifier: String.t(),
  issue: Issue.t(),
  worker_host: String.t() | nil,
  workspace_path: String.t() | nil,
  started_at: DateTime.t(),
  retry_attempt: integer() | nil,

  # Enhanced fields
  session_id: String.t() | nil,          # CLI session ID
  resumed_from: String.t() | nil,        # Previous session ID if resumed
  preview_port: integer() | nil,         # Assigned preview port
  preview_url: String.t() | nil,         # Full preview URL

  # Removed: last_codex_message, last_codex_event, last_codex_timestamp
  # (replaced by event bus — dashboard subscribes directly)

  # Token tracking (extracted from stream events)
  total_tokens: integer(),
  turn_count: integer()
}
```

### Stream Event (Normalized)

```elixir
%{
  issue_id: String.t(),
  session_id: String.t(),
  timestamp: DateTime.t(),
  type: :assistant | :tool_use | :tool_result | :system | :user | :error,
  content: %{
    # For :assistant
    message: String.t(),

    # For :tool_use
    tool: String.t(),
    input: map(),

    # For :tool_result
    tool: String.t(),
    output: String.t(),
    success: boolean(),

    # For :system
    subtype: :init | :done | :error,
    result: String.t(),

    # For :user (injected message)
    message: String.t(),
    source: :dashboard | :linear_comment
  }
}
```

### Router Decision

```elixir
%{
  issue_id: String.t(),
  decision: :new_session | :reuse_session,
  reuse_session_id: String.t() | nil,
  confidence: float(),           # 0.0 to 1.0
  reasoning: String.t(),
  candidates_evaluated: integer(),
  top_candidate_score: float() | nil,
  decided_by: :heuristic | :llm  # Was LLM consulted or was score clear?
}
```

---

## 8. Implementation Phases

### Phase Overview

| Phase | What | Depends On | Estimated Complexity |
|-------|------|------------|---------------------|
| 1 | Headless CLI execution backend | Nothing (replaces AppServer) | Medium |
| 2 | Event streaming & live dashboard | Phase 1 | Medium-High |
| 3 | Session persistence & Edit column | Phase 1, Phase 2 | Medium |
| 4 | Memory registry & context injection | Phase 3 | Medium |
| 5 | LLM router | Phase 4 | Medium |
| 6 | Dashboard polish & rich UI rendering | Phase 2 | Low-Medium |

Each phase is independently testable and delivers value on its own.

---

## Phase 1: Headless CLI Execution Backend

### Goal
Replace the Codex app-server JSON-RPC backend with a headless CLI backend that spawns coding agents as simple processes with streaming JSON output.

### What Changes

**New modules**:
- `Symphony.ExecutionBackend.HeadlessCLI` — Spawns CLI process, reads stream-json stdout
- `Symphony.ExecutionBackend.CommandBuilder` — Constructs CLI command from config

**Modified modules**:
- `AgentRunner` — Replace `AppServer.start_session/run_turn/stop_session` with `HeadlessCLI.start/stream_events/stop`
- `Config.Schema` — Replace `codex.*` config keys with `agent.*` CLI config keys
- `WORKFLOW.md` — Update agent section for CLI backend

**Removed modules**:
- `Codex.AppServer` — Entire JSON-RPC client (replaced)
- `Codex.DynamicTool` — No longer needed (agent handles tools internally)

### WORKFLOW.md Config Changes

```yaml
# Before (app-server)
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_timeout_ms: 3600000

# After (headless CLI)
agent:
  command: claude                    # or codex, cursor, etc.
  args:                              # additional CLI arguments
    - "--output-format"
    - "stream-json"
    - "--allowedTools"
    - "Read,Write,Edit,Bash,Glob,Grep"
  mode: headless                     # headless | interactive (future)
  session_timeout_ms: 3600000        # max time per session
  max_turns: 20                      # continuation turns
  auto_approve: true                 # skip permission prompts
```

### AgentRunner Changes

```elixir
# Current: complex turn loop with JSON-RPC
defp run_codex_turns(workspace, issue, ...) do
  with {:ok, session} <- AppServer.start_session(workspace, ...) do
    do_run_codex_turns(session, ..., 1, max_turns)
  end
end

# New: simple spawn + monitor
defp run_agent(workspace, issue, prompt, ...) do
  command = CommandBuilder.build(workspace, prompt, opts)
  port = Port.open({:spawn_executable, "bash"}, [
    :binary, :exit_status, :stderr_to_stdout,
    args: ["-lc", command],
    cd: workspace,
    line: 1_048_576
  ])

  stream_and_monitor(port, issue, on_event)
end
```

### Testing Phase 1

- [ ] HeadlessCLI can spawn a CLI process and capture stream-json output
- [ ] Process exit codes correctly signal success/failure
- [ ] Orchestrator dispatches issues using new backend
- [ ] Retry logic works (process exit → orchestrator handles)
- [ ] WorkflowStore loads new `agent.*` config section
- [ ] Continuation turns work (spawn new process with `--continue` or `--resume`)

---

## Phase 2: Event Streaming & Live Dashboard

### Goal
Replace the one-line-summary dashboard with a real-time web dashboard that shows expandable live streams per agent.

### What Changes

**New modules**:
- `Symphony.EventBus` — Thin PubSub wrapper with topic management
- `Symphony.EventParser` — Parses stream-json lines into normalized events
- `Symphony.Dashboard.AgentStreamLive` — LiveView component for single agent stream

**Modified modules**:
- `Orchestrator` — Remove `integrate_codex_update` / `summarize_codex_update`, replace with EventBus broadcasts
- `StatusDashboard` — Optional: keep terminal dashboard as fallback, or remove entirely
- `DashboardLive` — Rewrite with expandable agent rows
- `HttpServer` — Ensure LiveView socket configured properly

### Event Flow

```
CLI Worker stdout
    │
    ├── line of JSON
    │
    ▼
AgentRunner (reads port output)
    │
    ├── EventParser.parse(line)  →  normalized event struct
    │
    ├── EventBus.broadcast("agent:events:#{issue_id}", event)
    │
    ├── EventBus.broadcast("agent:lifecycle:#{issue_id}", event)  (if lifecycle event)
    │
    └── LogFile.write(issue_id, event)  (structured log)


Dashboard LiveView
    │
    ├── handle_info({:agent_event, event})  →  append to stream
    │
    └── re-render expanded agent view
```

### LiveView Structure

```
DashboardLive (main layout)
├── OverviewComponent (summary bar: running/retry/tokens)
├── AgentListComponent (list of all agents)
│   ├── AgentRowComponent (collapsed: one-line status)
│   │   └── on click → expand
│   └── AgentStreamComponent (expanded: live event stream)
│       ├── EventComponent (renders individual events)
│       │   ├── AssistantMessageEvent
│       │   ├── ToolCallEvent (with file diff rendering)
│       │   ├── ToolResultEvent
│       │   └── SystemEvent
│       └── ChatInputComponent (text input + send button)
└── RetryQueueComponent (list of retrying issues)
```

### Testing Phase 2

- [ ] EventBus broadcasts events from CLI worker to subscribers
- [ ] Dashboard shows real-time agent list with status
- [ ] Clicking agent row expands to show live event stream
- [ ] Events render correctly (assistant messages, tool calls, results)
- [ ] Dashboard updates in real-time as new events arrive
- [ ] Multiple concurrent agents stream independently

---

## Phase 3: Session Persistence & Edit Column

### Goal
Store session metadata in SQLite and implement the "Edit" column workflow for session reuse without full rework.

### What Changes

**New modules**:
- `Symphony.SessionRegistry` — GenServer wrapping Ecto/SQLite for session CRUD
- `Symphony.SessionRegistry.Repo` — Ecto repo for SQLite
- `Symphony.SessionRegistry.Session` — Ecto schema for sessions table
- `Symphony.SessionRegistry.FileTouch` — Ecto schema for session_files table

**Modified modules**:
- `Orchestrator` — On dispatch, check if "Edit" state → query registry for prior session
- `AgentRunner` — Support session resumption (different command construction)
- `Linear.Client` — Add `fetch_issue_comments(issue_id)` GraphQL query
- `Config.Schema` — Add `review_states` to tracker config

### Session Recording Flow

```
Agent starts → SessionRegistry.create_session(session_id, issue_id, ...)

During run:
  EventBus subscriber → on tool_use with file path:
    SessionRegistry.record_file_touch(session_id, file_path, action)

Agent completes:
  SessionRegistry.complete_session(session_id, status, total_tokens, ...)
```

### Edit Column Dispatch Flow

```elixir
defp dispatch_issue(state, issue, attempt, worker_host) do
  case issue.state do
    "Edit" ->
      # Look up prior session for this issue
      case SessionRegistry.latest_successful_session(issue.id) do
        {:ok, prior_session} ->
          # Fetch comments since last session
          {:ok, comments} = Linear.Client.fetch_issue_comments(issue.id, since: prior_session.completed_at)

          # Build continuation prompt
          prompt = build_edit_prompt(issue, comments, prior_session)

          # Dispatch with session resumption
          spawn_agent(state, issue, prompt, resume_session: prior_session.session_id, ...)

        nil ->
          # No prior session, dispatch normally
          spawn_agent(state, issue, build_prompt(issue), ...)
      end

    _ ->
      # Normal dispatch
      spawn_agent(state, issue, build_prompt(issue), ...)
  end
end
```

### Edit Prompt Template

```
You are resuming work on issue {{ issue.identifier }}: {{ issue.title }}

You previously completed work on this issue that is now in review. The reviewer
has requested the following changes:

{% for comment in comments %}
### Comment by {{ comment.author }} ({{ comment.created_at }}):
{{ comment.body }}

{% endfor %}

Please make the requested changes. The workspace already contains your previous work.
Focus only on the feedback above — do not redo work that wasn't mentioned.

When done, update the Linear issue state back to "Human Review".
```

### Testing Phase 3

- [ ] SessionRegistry creates and queries sessions in SQLite
- [ ] File touches are recorded from stream events
- [ ] "Edit" state issues dispatch with session resumption
- [ ] Linear comments are fetched and included in continuation prompt
- [ ] Agent resumes in existing workspace (not a fresh clone)
- [ ] After edit completion, issue moves back to "Human Review"
- [ ] Session registry correctly links edit sessions to original sessions

---

## Phase 4: Memory Registry & Context Injection

### Goal
Generate semantic summaries of completed sessions and inject relevant prior context into new issue prompts to avoid redundant codebase exploration.

### What Changes

**New modules**:
- `Symphony.SessionRegistry.Summarizer` — Generates session summaries (heuristic + optional LLM)
- `Symphony.ContextInjector` — Queries registry and builds context preamble for prompts

**Modified modules**:
- `PromptBuilder` — Accept optional `prior_context` parameter
- `Orchestrator` — Before dispatch, call ContextInjector to check for relevant prior sessions

### Summary Generation

**Heuristic summary** (always, zero cost):
```elixir
def generate_heuristic_summary(session_id) do
  files = SessionRegistry.get_file_touches(session_id)

  %{
    files_read: files |> Enum.filter(&(&1.action == "read")) |> Enum.map(& &1.file_path) |> Enum.uniq(),
    files_modified: files |> Enum.filter(&(&1.action in ["write", "edit", "create"])) |> Enum.map(& &1.file_path) |> Enum.uniq(),
    codebase_areas: extract_areas(files),  # e.g., ["src/auth", "src/api", "test/auth"]
    total_tokens: session.total_tokens,
    duration_seconds: DateTime.diff(session.completed_at, session.started_at)
  }
end
```

**LLM-enhanced summary** (optional, runs after session completion):
- Collect the assistant messages from the session event log
- Send to a fast/cheap model: "Summarize what this coding session accomplished and what codebase knowledge it accumulated"
- Store the result in `session_summaries` table

### Context Injection Flow

```elixir
def build_context_preamble(issue) do
  # Find relevant prior sessions
  candidates = SessionRegistry.find_relevant_sessions(
    file_hints: extract_file_hints(issue),
    area_hints: extract_area_hints(issue),
    max_age_days: 7,
    status: :succeeded,
    limit: 3
  )

  case candidates do
    [] -> nil
    sessions ->
      """
      ## Prior Context

      Previous sessions have established the following knowledge about areas
      relevant to your task:

      #{Enum.map_join(sessions, "\n---\n", &format_session_context/1)}

      Build on this context where relevant. Skip re-exploration of documented
      patterns and files unless you need to verify they haven't changed.
      """
  end
end
```

### Testing Phase 4

- [ ] Heuristic summaries generated for all completed sessions
- [ ] LLM summaries generated (when configured)
- [ ] ContextInjector finds relevant sessions for new issues
- [ ] Context preamble is prepended to new issue prompts
- [ ] Agents demonstrably skip codebase exploration when context is provided
- [ ] Token usage is measurably lower for context-injected sessions vs fresh starts

---

## Phase 5: LLM Router

### Goal
For ambiguous routing decisions, use an LLM to decide whether a new issue should start fresh or build on an existing session.

### What Changes

**New modules**:
- `Symphony.Router` — Top-level routing logic
- `Symphony.Router.Scorer` — Composite scoring of candidate sessions
- `Symphony.Router.LLMDecider` — LLM-backed decision for ambiguous cases
- `Symphony.Router.PromptTemplates` — System/user prompts for routing decisions

**Modified modules**:
- `Orchestrator` — Call Router.route(issue) before dispatch

### Router Flow

```elixir
def route(issue) do
  candidates = SessionRegistry.find_relevant_sessions(issue)
  scored = Scorer.score_all(candidates, issue)

  case scored do
    [] ->
      %Decision{decision: :new_session, decided_by: :heuristic}

    [%{score: score} = top | _] when score > 0.7 ->
      %Decision{
        decision: :reuse_session,
        reuse_session_id: top.session_id,
        confidence: score,
        decided_by: :heuristic
      }

    top_candidates ->
      # Ambiguous — ask LLM
      LLMDecider.decide(issue, Enum.take(top_candidates, 3))
  end
end
```

### Testing Phase 5

- [ ] Scorer produces reasonable scores for test cases
- [ ] High-confidence matches route directly without LLM call
- [ ] Ambiguous cases trigger LLM decision
- [ ] LLM returns structured decision with reasoning
- [ ] Router integrates cleanly with orchestrator dispatch flow
- [ ] Routing decisions are logged for analysis

---

## Phase 6: Dashboard Polish & UI Rendering

### Goal
Transform raw JSON events into rich, readable UI components in the dashboard.

### What Changes

- **File diff rendering** — Tool calls that edit files show syntax-highlighted diffs
- **Collapsible tool calls** — Long file reads collapse to "Read src/auth/token.ex (245 lines)" with expand
- **Status indicators** — Color-coded badges for agent states
- **Token sparklines** — Real-time token usage graphs
- **Preview integration** — Iframe or link to per-feature preview ports
- **Search/filter** — Filter agents by state, search event streams
- **Dark mode** — Because of course

### Future Expansion Ideas

- **Session replay** — Scrub through a completed session's events like a video
- **Comparative view** — Side-by-side view of two agents working on related issues
- **Cost dashboard** — Token costs in dollars, trending over time
- **Agent performance** — Which types of issues succeed/fail, average token usage by area
- **Mobile view** — Responsive dashboard for checking agent status from phone

---

## 10. Technical Decisions

### Why Headless CLI Over App Server?

| Factor | App Server (JSON-RPC) | Headless CLI |
|--------|----------------------|--------------|
| Context overhead | Every tool call round-trips through orchestrator | Tool calls are internal to agent |
| Implementation complexity | JSON-RPC handshake, message framing, protocol handling | Spawn process, read stdout |
| Agent flexibility | Locked to Codex app-server protocol | Any CLI agent with stream output |
| Human-in-the-loop | Would need to inject into JSON-RPC stream | Spawn continuation process |
| Debugging | Must parse JSON-RPC to understand state | Read structured events directly |
| Session resumption | Depends on Codex thread persistence | CLI --resume flag |

### Why SQLite for Session Registry?

- No external dependencies (no Postgres, no Redis)
- Persistent across restarts
- Fast enough for this query pattern (hundreds of sessions, not millions)
- Queryable with SQL (complex queries for routing)
- Elixir has excellent SQLite support via Ecto + ecto_sqlite3
- Already a proven pattern (upstream spec mentions it)

### Why Phoenix LiveView for Dashboard?

- Already in the project (upstream uses it)
- Real-time updates via WebSocket (no polling)
- Server-rendered (no separate frontend build)
- PubSub integration is native
- Component model fits the expandable agent stream pattern

### Why Elixir/OTP as the Foundation?

- Upstream Symphony is already Elixir — minimize rewrite scope
- OTP supervision trees are perfect for managing concurrent agent processes
- GenServer + PubSub is the natural fit for orchestration + event streaming
- Port management for CLI processes is a first-class Elixir feature
- Phoenix LiveView for the dashboard is already set up

---

## 11. Open Questions

### Q1: Which CLI Agent? — RESOLVED

**Decision**: Both. The system is configurable via `agent.backend` in WORKFLOW.md. Claude Code and Codex are supported as first-class backends via the adapter layer (Section 5.1). Adding future agents requires only a new adapter module (~50-100 lines).

- **Claude Code** (`claude`) — Supports `--output-format stream-json`, `--resume`, non-interactive mode
- **Codex CLI** (`codex`) — Has similar headless capabilities
- Default backend: `claude` (configurable per-deployment)

### Q2: Thread Resumption vs Context Injection?

For the Edit column workflow:
- **Option A**: True session resumption (`--resume <session_id>`) — preserves full conversation history
- **Option B**: Context injection — new session with prior summary prepended
- **Option C**: Both — try resume first, fall back to context injection

**Decision needed**: Does the target CLI agent support `--resume` reliably?

### Q3: LLM for Summaries and Routing?

- Which model for session summaries? (fast/cheap like Haiku, or capable like Sonnet?)
- Which model for routing decisions? (same or different?)
- Should summary generation be synchronous (block after session) or async (background)?

**Decision needed**: Model selection and sync/async strategy.

### Q4: Preview Server Strategy

- How to handle different project types? (Next.js, Phoenix, Rails, etc.)
- Should preview be automatic or opt-in via workflow config?
- Port allocation strategy (static range? dynamic?)

**Decision needed**: Generic preview approach or project-type-specific hooks.

### Q5: Linear State Transitions

- Should the agent move issues between states, or should Symphony do it?
- If the agent does it: needs Linear API access (GraphQL tool or CLI)
- If Symphony does it: cleaner separation but less flexible

**Decision needed**: Who owns state transitions?

---

## 12. File Structure

### Proposed Module Layout

```
lib/
├── symphony/
│   ├── application.ex                    # OTP application supervisor
│   ├── cli.ex                            # Escript entry point
│   │
│   ├── orchestrator.ex                   # Main polling loop (modified)
│   ├── agent_runner.ex                   # Agent task spawner (modified)
│   │
│   ├── execution_backend/
│   │   ├── headless_cli.ex              # NEW: Backend-agnostic process manager
│   │   ├── agent_adapter.ex             # NEW: Behaviour definition
│   │   └── adapters/
│   │       ├── claude.ex                # NEW: Claude Code adapter
│   │       └── codex.ex                 # NEW: Codex adapter
│   │
│   ├── event_bus.ex                     # NEW: PubSub wrapper
│   ├── event_parser.ex                  # NEW: Stream-json parser
│   │
│   ├── session_registry/
│   │   ├── registry.ex                  # NEW: GenServer for session CRUD
│   │   ├── repo.ex                      # NEW: Ecto SQLite repo
│   │   ├── session.ex                   # NEW: Session schema
│   │   ├── file_touch.ex               # NEW: File touch schema
│   │   ├── summary.ex                   # NEW: Summary schema
│   │   └── summarizer.ex              # NEW: Summary generation
│   │
│   ├── router/
│   │   ├── router.ex                    # NEW: Top-level routing
│   │   ├── scorer.ex                    # NEW: Candidate scoring
│   │   ├── llm_decider.ex             # NEW: LLM routing decision
│   │   └── prompt_templates.ex         # NEW: Router prompts
│   │
│   ├── context_injector.ex             # NEW: Prior context builder
│   │
│   ├── config.ex                        # Config layer (modified)
│   ├── config/
│   │   └── schema.ex                    # Config schema (modified)
│   │
│   ├── workflow.ex                      # WORKFLOW.md loader (unchanged)
│   ├── workflow_store.ex                # Workflow watcher (unchanged)
│   ├── prompt_builder.ex                # Template rendering (modified)
│   │
│   ├── linear/
│   │   ├── client.ex                    # GraphQL client (modified: add comments)
│   │   ├── adapter.ex                   # Tracker adapter (unchanged)
│   │   └── issue.ex                     # Issue struct (unchanged)
│   │
│   ├── tracker.ex                       # Tracker behavior (unchanged)
│   ├── workspace.ex                     # Workspace lifecycle (unchanged)
│   ├── path_safety.ex                   # Path validation (unchanged)
│   ├── ssh.ex                           # SSH support (unchanged)
│   │
│   ├── preview_manager.ex              # NEW: Per-workspace preview servers
│   ├── log_file.ex                      # Structured logging (unchanged)
│   └── http_server.ex                   # Phoenix HTTP server (unchanged)
│
├── symphony_web/
│   ├── endpoint.ex                      # Phoenix endpoint (unchanged)
│   ├── router.ex                        # Phoenix router (modified)
│   │
│   ├── live/
│   │   ├── dashboard_live.ex           # Main dashboard (rewritten)
│   │   └── components/
│   │       ├── overview.ex             # NEW: Summary stats bar
│   │       ├── agent_list.ex           # NEW: Agent list with expand
│   │       ├── agent_stream.ex         # NEW: Live event stream
│   │       ├── event_renderer.ex       # NEW: Rich event rendering
│   │       ├── chat_input.ex           # NEW: Message injection UI
│   │       └── retry_queue.ex          # NEW: Retry queue display
│   │
│   ├── controllers/
│   │   └── api_controller.ex           # JSON API (modified)
│   │
│   └── pubsub.ex                        # PubSub helpers (modified)

config/
├── config.exs
├── dev.exs
├── prod.exs
└── test.exs

priv/
├── repo/
│   └── migrations/
│       ├── 001_create_sessions.exs     # NEW
│       ├── 002_create_session_files.exs # NEW
│       └── 003_create_session_summaries.exs # NEW
└── static/
    └── assets/                          # Dashboard CSS/JS

WORKFLOW.md                              # Updated config format
```

---

## Summary

This plan takes upstream Symphony from a simple poll-dispatch-execute loop into a context-aware, observable, human-in-the-loop dev workflow orchestrator. The six phases build incrementally — each delivers standalone value:

1. **Phase 1** (CLI backend) — Leaner execution, simpler code, agent-agnostic
2. **Phase 2** (Event streaming) — "Look over the shoulder" dashboard
3. **Phase 3** (Sessions + Edit) — Small tweaks without full rework
4. **Phase 4** (Memory + context) — Agents build on prior knowledge
5. **Phase 5** (LLM router) — Smart dispatch decisions
6. **Phase 6** (UI polish) — Rich rendering of agent activity

The result is a system where the developer manages work at the Linear board level, watches agents work when curious, jumps in for quick fixes, and benefits from accumulated codebase knowledge across sessions.
