defmodule SymphonyElixir.ExecutionBackend.HeadlessCLI do
  @moduledoc """
  Backend-agnostic process manager for headless CLI coding agents.

  Uses the `claude_code` Elixir SDK for Claude Code execution, which handles
  all the Port spawning, stdout buffering, JSON-RPC protocol, and session
  management correctly.

  For other backends (Codex), falls back to direct Port spawning.
  """

  require Logger

  alias SymphonyElixir.{Config, Event}

  @default_timeout_ms 3_600_000

  @type handle :: %{
          session_pid: pid() | nil,
          adapter: module(),
          session_id: String.t() | nil,
          session_ref: reference(),
          workspace: Path.t(),
          started_at: DateTime.t()
        }

  @doc """
  Start a new agent session and run it to completion.

  Uses the claude_code SDK for Claude backend, which handles all Port
  management and protocol details internally.

  Returns {:ok, result} on success or {:error, reason} on failure.
  """
  @spec run_session(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_session(workspace, prompt, opts \\ []) do
    backend = Keyword.get_lazy(opts, :backend, fn -> default_backend() end)
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    config = Config.settings!()

    case backend do
      b when b in ["claude", :claude] ->
        run_claude_session(workspace, prompt, config, on_event, opts)

      _ ->
        {:error, {:unsupported_backend, backend}}
    end
  end

  # -- Claude Code SDK execution --

  defp run_claude_session(workspace, prompt, config, on_event, _opts) do
    Logger.info("Starting Claude Code session in #{workspace}")

    on_event.(Event.system(:init, %{workspace: workspace, backend: "claude"}))

    sdk_opts = [
      max_turns: config.agent.max_turns,
      cwd: workspace,
      dangerously_skip_permissions: true
    ]

    # Start a session, stream messages in real-time, emit events as they arrive
    {:ok, session} = ClaudeCode.start_link(sdk_opts)

    try do
      session_id = nil

      result =
        session
        |> ClaudeCode.stream(prompt)
        |> Enum.reduce({nil, nil}, fn msg, {_last_result, sid} ->
          # Extract session_id if available
          new_sid = sid || extract_session_id_from_message(msg)

          # Convert SDK message to Symphony events and emit
          events = message_to_events(msg)
          for event <- events do
            event = %{event | session_id: new_sid}
            on_event.(event)
          end

          {msg, new_sid}
        end)

      {last_msg, final_sid} = result

      on_event.(Event.system(:done, %{status: :success, session_id: final_sid}))
      {:ok, %{session_id: final_sid, status: :completed}}
    after
      ClaudeCode.stop(session)
    end
  rescue
    e ->
      Logger.error("Claude Code session crashed: #{Exception.message(e)}")
      on_event.(Event.error(Exception.message(e)))
      {:error, {:crash, Exception.message(e)}}
  end

  # -- SDK Message to Symphony Event conversion --

  alias ClaudeCode.Message.{AssistantMessage, UserMessage, ResultMessage}

  defp message_to_events(%AssistantMessage{message: %{"content" => content}} = msg) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} ->
        [Event.assistant(text)]

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        [Event.tool_use(name, input || %{})]

      _ ->
        []
    end)
  end

  defp message_to_events(%UserMessage{tool_use_result: %{"file" => file}} = _msg) when is_map(file) do
    path = Map.get(file, "filePath", "")
    [Event.tool_result("Read", "#{path}", true)]
  end

  defp message_to_events(%UserMessage{message: %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_result", "content" => result_text} when is_binary(result_text) ->
        [Event.tool_result("tool", String.slice(result_text, 0, 500), true)]

      _ ->
        []
    end)
  end

  defp message_to_events(%ResultMessage{} = msg) do
    [%Event{
      type: :system,
      content: %{
        subtype: :result,
        is_error: msg.is_error,
        result: msg.result,
        cost_usd: msg.total_cost_usd,
        duration_ms: msg.duration_ms,
        total_turns: msg.num_turns
      },
      raw: nil,
      timestamp: DateTime.utc_now()
    }]
  end

  defp message_to_events(_msg), do: []

  defp extract_session_id_from_message(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id_from_message(_msg), do: nil

  # -- Helpers --

  defp default_backend do
    try do
      Config.settings!().agent.backend
    rescue
      _ -> "claude"
    end
  end

  defp default_on_event(event) do
    Logger.debug("Agent event: #{inspect(event.type)}")
    :ok
  end
end
