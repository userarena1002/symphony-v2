defmodule SymphonyElixir.ExecutionBackend.AgentAdapter do
  @moduledoc """
  Behaviour contract for coding agent CLI adapters.

  Each supported agent backend (Claude Code, Codex, etc.) implements this
  behaviour to handle the differences in CLI invocation, output parsing, and
  session management. The rest of the system works exclusively with the
  normalized `SymphonyElixir.Event` struct and never touches raw agent output.

  ## Adding a new agent

  1. Create a module implementing this behaviour under
     `SymphonyElixir.ExecutionBackend.Adapters.*`
  2. Map the agent's CLI flags in `build_command/3` and `build_resume_command/4`
  3. Normalize the agent's JSON output in `parse_event/1`
  4. Register the adapter name in `SymphonyElixir.ExecutionBackend.HeadlessCLI.resolve_adapter/1`
  """

  alias SymphonyElixir.Event

  @doc """
  Build the shell command string to start a new agent session.

  The command should:
  - Run the agent in headless/non-interactive mode
  - Output structured JSON events to stdout (one per line)
  - Auto-approve tool calls (no interactive prompts)
  - Set the working directory to the workspace

  Returns a complete shell command string suitable for `bash -lc`.
  """
  @callback build_command(workspace :: Path.t(), prompt :: String.t(), opts :: keyword()) ::
              String.t()

  @doc """
  Build the shell command string to resume an existing session.

  Used when an issue moves to the "Edit" column and we want to continue
  working in the same session context as before.
  """
  @callback build_resume_command(
              workspace :: Path.t(),
              session_id :: String.t(),
              prompt :: String.t(),
              opts :: keyword()
            ) :: String.t()

  @doc """
  Parse a raw JSON map (decoded from a single stdout line) into a normalized event.

  Returns:
  - `{:ok, event}` — successfully parsed
  - `{:skip, reason}` — recognized but not worth emitting (e.g., heartbeat)
  - `{:error, reason}` — malformed or unexpected
  """
  @callback parse_event(raw_json :: map()) ::
              {:ok, Event.t()} | {:skip, atom()} | {:error, term()}

  @doc """
  Extract the session ID from agent output during initialization.

  Called on each event until a session ID is found. Returns `:not_found`
  for events that don't contain session identification.
  """
  @callback extract_session_id(raw_json :: map()) ::
              {:ok, String.t()} | :not_found

  @doc """
  Check whether a raw event signals session/turn completion.

  Returns:
  - `:running` — session still active
  - `:completed` — session finished successfully
  - `:failed` — session ended with an error
  """
  @callback completion_signal?(raw_json :: map()) ::
              :running | :completed | :failed

  @doc "Human-readable name of the agent backend for logging and display."
  @callback agent_name() :: String.t()
end
