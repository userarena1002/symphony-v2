defmodule SymphonyElixir.ExecutionBackend.HeadlessCLI do
  @moduledoc """
  Backend-agnostic process manager for headless CLI coding agents.

  Uses the `claude_code` Elixir SDK for Claude Code execution, which handles
  all the Port spawning, stdout buffering, JSON-RPC protocol, and session
  management correctly.

  Key: uses `include_partial_messages: true` to get real-time streaming
  events (tool progress, content deltas) for the live dashboard.
  """

  require Logger

  alias SymphonyElixir.{Config, Event}
  alias ClaudeCode.Message.{
    AssistantMessage,
    PartialAssistantMessage,
    ToolProgressMessage,
    ToolUseSummaryMessage,
    UserMessage,
    ResultMessage
  }

  @doc """
  Start a new agent session and run it to completion, emitting events in real-time.

  Uses the claude_code SDK for Claude backend. Events are emitted via `on_event`
  callback as they arrive from the streaming session, giving the dashboard
  real-time visibility into what the agent is doing.
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

    {:ok, session} = ClaudeCode.start_link(sdk_opts)

    try do
      # Pass include_partial_messages at query level for real-time streaming
      query_opts = [include_partial_messages: true]

      {_last, final_sid} =
        session
        |> ClaudeCode.stream(prompt, query_opts)
        |> Enum.reduce({nil, nil}, fn msg, {_last, sid} ->
          new_sid = sid || extract_session_id(msg)

          # Convert SDK message to Symphony events and emit in real-time
          for event <- message_to_events(msg) do
            on_event.(%{event | session_id: new_sid})
          end

          {msg, new_sid}
        end)

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

  # -- SDK Message → Symphony Event conversion --
  #
  # With include_partial_messages: true, the stream emits:
  #   PartialAssistantMessage — streaming content deltas (text chunks, tool_use starts)
  #   ToolProgressMessage — tool execution progress (tool name, elapsed time)
  #   ToolUseSummaryMessage — summary of what a tool did
  #   AssistantMessage — complete assistant turn
  #   UserMessage — tool results
  #   ResultMessage — session complete

  # Partial messages: real-time streaming content
  defp message_to_events(%PartialAssistantMessage{event: event} = msg) do
    case event do
      %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use", "name" => name}} ->
        [Event.tool_use(name, %{}, nil)]

      %{"type" => "content_block_start", "content_block" => %{"type" => "text", "text" => text}} when text != "" ->
        [Event.assistant(text)]

      %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} when is_binary(text) and text != "" ->
        [Event.assistant(text)]

      %{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta", "partial_json" => _json}} ->
        # Tool input streaming — skip to avoid noise, the full input comes with AssistantMessage
        []

      _ ->
        []
    end
  end

  # Tool progress: shows which tool is running and how long
  defp message_to_events(%ToolProgressMessage{tool_name: name, tool_use_id: id} = _msg) do
    [%Event{
      type: :tool_use,
      content: %{tool: name || "tool", input: %{}, tool_use_id: id, progress: true},
      raw: nil,
      timestamp: DateTime.utc_now()
    }]
  end

  # Tool summary: what the tool accomplished
  defp message_to_events(%ToolUseSummaryMessage{summary: summary} = _msg) when is_binary(summary) do
    [Event.tool_result("tool", String.slice(summary, 0, 500), true)]
  end

  # Complete assistant message: full turn with all content blocks
  defp message_to_events(%AssistantMessage{message: %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
        [Event.assistant(text)]

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        [Event.tool_use(name, input || %{})]

      _ ->
        []
    end)
  end

  # User message with file result
  defp message_to_events(%UserMessage{tool_use_result: %{"file" => file}}) when is_map(file) do
    path = Map.get(file, "filePath", "")
    [Event.tool_result("Read", path, true)]
  end

  # User message with tool results
  defp message_to_events(%UserMessage{message: %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_result", "content" => text} when is_binary(text) ->
        [Event.tool_result("tool", String.slice(text, 0, 500), true)]

      _ ->
        []
    end)
  end

  # Result message: session complete
  defp message_to_events(%ResultMessage{} = msg) do
    [%Event{
      type: :system,
      content: %{
        subtype: :result,
        is_error: msg.is_error,
        result: if(is_binary(msg.result), do: String.slice(msg.result, 0, 500), else: nil),
        cost_usd: msg.total_cost_usd,
        duration_ms: msg.duration_ms,
        total_turns: msg.num_turns
      },
      raw: nil,
      timestamp: DateTime.utc_now()
    }]
  end

  # Catch-all for unhandled message types (system messages, rate limit events, etc.)
  defp message_to_events(_msg), do: []

  defp extract_session_id(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id(_msg), do: nil

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
