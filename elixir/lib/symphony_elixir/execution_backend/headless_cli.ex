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

  alias ClaudeCode.Content.{TextBlock, ToolUseBlock, ToolResultBlock}

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

  defp run_claude_session(workspace, prompt, config, on_event, opts) do
    resume_session_id = Keyword.get(opts, :resume_session_id)

    if resume_session_id do
      Logger.info("Resuming Claude Code session #{resume_session_id} in #{workspace}")
    else
      Logger.info("Starting new Claude Code session in #{workspace}")
    end

    on_event.(Event.system(:init, %{
      workspace: workspace,
      backend: "claude",
      resuming: resume_session_id
    }))

    # Session-level options
    sdk_opts = [
      max_turns: config.agent.max_turns,
      cwd: workspace,
      dangerously_skip_permissions: true
    ]

    # Add resume if we have a previous session ID
    sdk_opts = if resume_session_id do
      Keyword.put(sdk_opts, :resume, resume_session_id)
    else
      sdk_opts
    end

    {:ok, session} = ClaudeCode.start_link(sdk_opts)

    try do
      query_opts = [include_partial_messages: true]

      {_last, final_sid} =
        session
        |> ClaudeCode.stream(prompt, query_opts)
        |> Enum.reduce({nil, nil}, fn msg, {_last, sid} ->
          new_sid = sid || extract_session_id(msg)

          events = message_to_events(msg)
          for event <- events do
            on_event.(%{event | session_id: new_sid})
          end

          {msg, new_sid}
        end)

      # Save session ID to workspace for future resume
      save_session_id(workspace, final_sid)

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

  # -- Skip all partial/progress/summary messages --
  # These fire multiple times per tool call and duplicate what
  # AssistantMessage and UserMessage already provide cleanly.
  defp message_to_events(%PartialAssistantMessage{}), do: []
  defp message_to_events(%ToolProgressMessage{}), do: []
  defp message_to_events(%ToolUseSummaryMessage{}), do: []

  # -- Complete assistant message: THE primary source of events --
  # One per agent turn. Contains text reasoning + tool calls with full input.
  defp message_to_events(%AssistantMessage{message: %{content: content, usage: usage}}) when is_list(content) do
    events =
      content
      |> Enum.flat_map(fn
        %TextBlock{text: text} when is_binary(text) ->
          trimmed = String.trim(text)
          if trimmed != "", do: [Event.assistant(trimmed)], else: []

        %ToolUseBlock{name: name, input: input} ->
          [Event.tool_use(name, input || %{})]

        _ ->
          []
      end)

    # Attach usage to first event for token tracking
    case {events, usage} do
      {[first | rest], %{} = u} ->
        [%{first | content: Map.put(first.content, :usage, u)} | rest]
      _ ->
        events
    end
  end

  defp message_to_events(%AssistantMessage{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %TextBlock{text: text} when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed != "", do: [Event.assistant(trimmed)], else: []

      %ToolUseBlock{name: name, input: input} ->
        [Event.tool_use(name, input || %{})]

      _ ->
        []
    end)
  end

  # -- User message (tool results) --
  defp message_to_events(%UserMessage{message: %{content: content}}) when is_list(content) do
    Enum.flat_map(content, fn
      %ToolResultBlock{content: result_content, is_error: is_error} ->
        text = extract_result_text(result_content)
        [Event.tool_result("tool", String.slice(text, 0, 500), !is_error)]

      %{type: :tool_result, content: result_content} ->
        text = extract_result_text(result_content)
        [Event.tool_result("tool", String.slice(text, 0, 500), true)]

      _ ->
        []
    end)
  end

  # User message with tool_use_result (file read shortcut)
  defp message_to_events(%UserMessage{tool_use_result: result}) when is_map(result) do
    file = Map.get(result, "file") || Map.get(result, :file, %{})
    path = Map.get(file, "filePath") || Map.get(file, :filePath, "")
    num_lines = Map.get(file, "totalLines") || Map.get(file, :totalLines)

    if path != "" do
      summary = if num_lines, do: "#{path} (#{num_lines} lines)", else: path
      [Event.tool_result("Read", summary, true)]
    else
      content = Map.get(result, "content") || Map.get(result, :content, "")
      text = if is_binary(content), do: String.slice(content, 0, 500), else: inspect(content) |> String.slice(0, 200)
      [Event.tool_result("tool", text, true)]
    end
  end

  defp message_to_events(%UserMessage{}), do: []

  # -- Result message --
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

  # Catch-all
  defp message_to_events(_msg), do: []

  defp extract_result_text(content) when is_binary(content), do: content
  defp extract_result_text(content) when is_list(content) do
    Enum.map_join(content, " ", fn
      %TextBlock{text: text} -> text
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      other -> inspect(other) |> String.slice(0, 100)
    end)
  end
  defp extract_result_text(content), do: inspect(content) |> String.slice(0, 200)

  defp extract_session_id(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id(_msg), do: nil

  # -- Session persistence --

  @session_id_file ".symphony/last_session_id"

  defp save_session_id(workspace, session_id) when is_binary(session_id) do
    path = Path.join(workspace, @session_id_file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, session_id)
    Logger.info("Saved session ID #{session_id} to #{path}")
  end

  defp save_session_id(_workspace, _session_id), do: :ok

  @doc "Load the last session ID for a workspace, if one exists."
  @spec load_session_id(Path.t()) :: String.t() | nil
  def load_session_id(workspace) do
    path = Path.join(workspace, @session_id_file)

    case File.read(path) do
      {:ok, id} ->
        trimmed = String.trim(id)
        if trimmed != "", do: trimmed, else: nil

      {:error, _} ->
        nil
    end
  end

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
