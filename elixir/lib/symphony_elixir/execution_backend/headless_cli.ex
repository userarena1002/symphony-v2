defmodule SymphonyElixir.ExecutionBackend.HeadlessCLI do
  @moduledoc """
  Backend-agnostic process manager for headless CLI coding agents.

  Spawns an agent CLI as an Erlang Port, reads streaming JSON events from
  stdout, parses them through the configured adapter, and emits normalized
  `SymphonyElixir.Event` structs via a callback function.

  This module replaces the Codex AppServer JSON-RPC client. Instead of
  marshalling every tool call through the orchestrator, agents run
  autonomously and emit events that we observe.

  ## Usage

      {:ok, handle} = HeadlessCLI.start(workspace, prompt,
        backend: "claude",
        on_event: fn event -> IO.inspect(event) end
      )

      # Process runs autonomously until completion or timeout
      # Events are emitted via the on_event callback

      HeadlessCLI.stop(handle)
  """

  require Logger

  alias SymphonyElixir.{Config, Event}
  alias SymphonyElixir.ExecutionBackend.Adapters

  @port_line_bytes 1_048_576
  @default_timeout_ms 3_600_000

  @type handle :: %{
          port: port(),
          adapter: module(),
          session_id: String.t() | nil,
          session_ref: reference(),
          workspace: Path.t(),
          started_at: DateTime.t()
        }

  @doc """
  Start a new agent session in the given workspace.

  ## Options

  - `:backend` — `"claude"` or `"codex"` (defaults to config `agent.backend`)
  - `:on_event` — callback `(Event.t() -> :ok)` called for each normalized event
  - `:allowed_tools` — list of tool names the agent can use
  - `:max_turns` — max agentic turns
  - `:extra_args` — additional CLI arguments
  - `:timeout_ms` — max session duration in milliseconds
  """
  @spec start(Path.t(), String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def start(workspace, prompt, opts \\ []) do
    adapter = resolve_adapter(opts)
    command = adapter.build_command(workspace, prompt, opts)

    Logger.info("Starting #{adapter.agent_name()} session in #{workspace}")
    Logger.debug("Command: #{command}")

    case spawn_port(workspace, command) do
      {:ok, port} ->
        handle = %{
          port: port,
          adapter: adapter,
          session_id: nil,
          session_ref: make_ref(),
          workspace: workspace,
          started_at: DateTime.utc_now()
        }

        {:ok, handle}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume an existing agent session.

  Used for the Edit column workflow — continues a prior session with a new
  prompt (typically containing reviewer feedback).
  """
  @spec resume(Path.t(), String.t(), String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def resume(workspace, session_id, prompt, opts \\ []) do
    adapter = resolve_adapter(opts)
    command = adapter.build_resume_command(workspace, session_id, prompt, opts)

    Logger.info("Resuming #{adapter.agent_name()} session #{session_id} in #{workspace}")
    Logger.debug("Command: #{command}")

    case spawn_port(workspace, command) do
      {:ok, port} ->
        handle = %{
          port: port,
          adapter: adapter,
          session_id: session_id,
          session_ref: make_ref(),
          workspace: workspace,
          started_at: DateTime.utc_now()
        }

        {:ok, handle}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run an agent session to completion, emitting events via callback.

  This is the main execution function. It reads from the port until the
  agent process exits, parsing and emitting events along the way.

  Returns `{:ok, result}` on successful completion or `{:error, reason}` on failure.
  """
  @spec run(handle(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(handle, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    receive_loop(handle, on_event, timeout_ms, "")
  end

  @doc "Stop an agent session by closing the port."
  @spec stop(handle()) :: :ok
  def stop(%{port: port}) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  def stop(_handle), do: :ok

  # -- Port management --

  defp spawn_port(workspace, command) do
    bash = System.find_executable("bash")

    if is_nil(bash) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(bash)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  # -- Event stream processing --

  defp receive_loop(handle, on_event, timeout_ms, pending_line) do
    %{port: port, adapter: adapter} = handle

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle = process_line(handle, complete_line, on_event)
        receive_loop(handle, on_event, timeout_ms, "")

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(handle, on_event, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        emit(on_event, Event.system(:exit, %{code: 0, status: :success}), handle)
        {:ok, %{session_id: handle.session_id, status: :completed, exit_code: 0}}

      {^port, {:exit_status, code}} ->
        emit(on_event, Event.system(:exit, %{code: code, status: :failed}), handle)
        {:error, {:exit_code, code}}
    after
      timeout_ms ->
        Logger.warning("#{adapter.agent_name()} session timed out after #{timeout_ms}ms")
        stop(handle)
        emit(on_event, Event.system(:timeout, %{timeout_ms: timeout_ms}), handle)
        {:error, :session_timeout}
    end
  end

  defp process_line(handle, line, on_event) do
    %{adapter: adapter} = handle

    case Jason.decode(line) do
      {:ok, raw} when is_map(raw) ->
        handle = maybe_capture_session_id(handle, adapter, raw)
        maybe_emit_event(handle, adapter, raw, on_event)
        handle

      {:error, _reason} ->
        log_non_json_line(line, adapter)
        handle
    end
  end

  defp maybe_capture_session_id(%{session_id: nil} = handle, adapter, raw) do
    case adapter.extract_session_id(raw) do
      {:ok, session_id} ->
        Logger.info("#{adapter.agent_name()} session ID: #{session_id}")
        %{handle | session_id: session_id}

      :not_found ->
        handle
    end
  end

  defp maybe_capture_session_id(handle, _adapter, _raw), do: handle

  defp maybe_emit_event(handle, adapter, raw, on_event) do
    case adapter.parse_event(raw) do
      {:ok, event} ->
        emit(on_event, event, handle)

      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        Logger.debug("#{adapter.agent_name()} event parse error: #{inspect(reason)}")
    end
  end

  defp emit(on_event, event, handle) do
    event = %{event | session_id: handle.session_id}
    on_event.(event)
  end

  defp log_non_json_line(line, adapter) do
    text = line |> to_string() |> String.trim() |> String.slice(0, 500)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("#{adapter.agent_name()} stderr: #{text}")
      else
        Logger.debug("#{adapter.agent_name()} output: #{text}")
      end
    end
  end

  # -- Adapter resolution --

  defp resolve_adapter(opts) do
    backend = Keyword.get_lazy(opts, :backend, fn -> default_backend() end)

    case backend do
      b when b in ["claude", :claude] -> Adapters.Claude
      b when b in ["codex", :codex] -> Adapters.Codex
      module when is_atom(module) -> module
      other -> raise ArgumentError, "Unknown agent backend: #{inspect(other)}"
    end
  end

  defp default_backend do
    try do
      Config.settings!().agent.backend
    rescue
      _ -> "claude"
    end
  end

  defp default_on_event(event) do
    Logger.debug("Agent event: #{inspect(event.type)} #{inspect(event.content)}")
    :ok
  end
end
