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

    # Emit init event
    on_event.(Event.system(:init, %{workspace: workspace, backend: "claude"}))

    sdk_opts = [
      max_turns: config.agent.max_turns,
      cwd: workspace,
      allowed_tools: config.agent.allowed_tools,
      permissions: %{allow: ["*"], deny: []},
      system_prompt: "",
      output_format: :stream_json
    ]

    session_id = nil

    case ClaudeCode.run(prompt, sdk_opts) do
      {:ok, messages} when is_list(messages) ->
        # Process all messages and emit events
        session_id = extract_session_id_from_messages(messages)

        for msg <- messages do
          events = message_to_events(msg)
          for event <- events do
            event = %{event | session_id: session_id}
            on_event.(event)
          end
        end

        on_event.(Event.system(:done, %{status: :success, session_id: session_id}))

        {:ok, %{session_id: session_id, status: :completed}}

      {:error, reason} ->
        Logger.error("Claude Code session failed: #{inspect(reason)}")
        on_event.(Event.error(reason))
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Claude Code session crashed: #{Exception.message(e)}")
      on_event.(Event.error(Exception.message(e)))
      {:error, {:crash, Exception.message(e)}}
  end

  # -- Message to Event conversion --

  defp message_to_events(%{role: :assistant, content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :text, text: text} ->
        [%Event{type: :assistant, content: %{message: text}, raw: nil, timestamp: DateTime.utc_now()}]

      %{type: :tool_use, name: name, input: input} ->
        [%Event{type: :tool_use, content: %{tool: name, input: input || %{}}, raw: nil, timestamp: DateTime.utc_now()}]

      %{type: :tool_result, content: result_content} ->
        output = extract_tool_result_text(result_content)
        [%Event{type: :tool_result, content: %{tool: "tool", output: output, success: true}, raw: nil, timestamp: DateTime.utc_now()}]

      _ ->
        []
    end)
  end

  defp message_to_events(%{role: :user, content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :tool_result, content: result_content} ->
        output = extract_tool_result_text(result_content)
        [%Event{type: :tool_result, content: %{tool: "tool", output: String.slice(output, 0, 500), success: true}, raw: nil, timestamp: DateTime.utc_now()}]

      _ ->
        []
    end)
  end

  # Handle raw map format (the SDK may return different shapes)
  defp message_to_events(%{"type" => "assistant", "message" => %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} ->
        [%Event{type: :assistant, content: %{message: text}, raw: nil, timestamp: DateTime.utc_now()}]

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        [%Event{type: :tool_use, content: %{tool: name, input: input || %{}}, raw: nil, timestamp: DateTime.utc_now()}]

      _ ->
        []
    end)
  end

  defp message_to_events(%{"type" => "result"} = msg) do
    [%Event{
      type: :system,
      content: %{
        subtype: :result,
        result: Map.get(msg, "result"),
        cost_usd: Map.get(msg, "total_cost_usd"),
        duration_ms: Map.get(msg, "duration_ms"),
        total_turns: Map.get(msg, "num_turns")
      },
      raw: msg,
      timestamp: DateTime.utc_now()
    }]
  end

  defp message_to_events(_msg), do: []

  defp extract_tool_result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} -> text
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp extract_tool_result_text(content) when is_binary(content), do: content
  defp extract_tool_result_text(content), do: inspect(content)

  defp extract_session_id_from_messages(messages) do
    Enum.find_value(messages, fn
      %{session_id: id} when is_binary(id) -> id
      %{"session_id" => id} when is_binary(id) -> id
      _ -> nil
    end)
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
