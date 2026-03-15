defmodule SymphonyElixir.ExecutionBackend.Adapters.Codex do
  @moduledoc """
  Agent adapter for Codex CLI.

  Translates between Symphony's execution interface and Codex's headless mode.
  Normalizes Codex's streaming output into `SymphonyElixir.Event` structs.

  ## Notes

  Codex's headless CLI output format may vary between versions. This adapter
  covers the known output shapes and will be refined as we test against
  actual Codex headless output. The event parsing is intentionally lenient
  to handle schema variations gracefully.
  """

  @behaviour SymphonyElixir.ExecutionBackend.AgentAdapter

  alias SymphonyElixir.Event

  @impl true
  def build_command(workspace, prompt, opts \\ []) do
    approval_mode = Keyword.get(opts, :approval_mode, "full-auto")
    extra_args = Keyword.get(opts, :extra_args, [])

    args =
      [
        "codex",
        "-q",
        "--json",
        "--approval-mode", approval_mode,
        "-p", shell_escape(prompt),
        "--cwd", shell_escape(workspace)
      ] ++ extra_args

    Enum.join(args, " ") <> " 2>/dev/null"
  end

  @impl true
  def build_resume_command(workspace, session_id, prompt, opts \\ []) do
    extra_args = Keyword.get(opts, :extra_args, [])

    args =
      [
        "codex",
        "--resume", shell_escape(session_id),
        "-q",
        "--json",
        "-p", shell_escape(prompt),
        "--cwd", shell_escape(workspace)
      ] ++ extra_args

    Enum.join(args, " ") <> " 2>/dev/null"
  end

  @impl true
  def parse_event(%{"type" => "message", "role" => "assistant", "content" => content} = raw)
      when is_list(content) do
    text =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "" do
      {:skip, :empty_message}
    else
      {:ok, %Event{
        type: :assistant,
        content: %{message: text},
        raw: raw,
        timestamp: parse_timestamp(raw)
      }}
    end
  end

  # Codex tool call events
  def parse_event(%{"type" => "function_call", "name" => tool, "arguments" => args} = raw) do
    input = parse_arguments(args)

    {:ok, %Event{
      type: :tool_use,
      content: %{tool: tool, input: input},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Alternative: Codex may emit tool calls as item events
  def parse_event(%{"type" => "item", "item" => %{"type" => "function_call"} = item} = raw) do
    {:ok, %Event{
      type: :tool_use,
      content: %{
        tool: Map.get(item, "name", "unknown"),
        input: parse_arguments(Map.get(item, "arguments", "{}"))
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "function_call_output", "output" => output} = raw) do
    {:ok, %Event{
      type: :tool_result,
      content: %{
        tool: Map.get(raw, "name", "unknown"),
        output: output_to_string(output),
        success: Map.get(raw, "is_error") != true
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Turn completion events
  def parse_event(%{"type" => "turn_completed"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{subtype: :done, result: "success"},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "turn_failed"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: :done,
        result: "error",
        error: Map.get(raw, "error") || Map.get(raw, "params")
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "turn_cancelled"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{subtype: :done, result: "cancelled"},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Session/thread events
  def parse_event(%{"type" => "session_started"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: :init,
        session_id: Map.get(raw, "session_id"),
        thread_id: Map.get(raw, "thread_id")
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Generic notification
  def parse_event(%{"type" => type} = raw) when is_binary(type) do
    {:ok, %Event{
      type: :unknown,
      content: %{original_type: type},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(_raw), do: {:skip, :unrecognized}

  @impl true
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: {:ok, id}
  def extract_session_id(%{"type" => "session_started", "session_id" => id}) when is_binary(id), do: {:ok, id}
  def extract_session_id(%{"session" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  def extract_session_id(_raw), do: :not_found

  @impl true
  def completion_signal?(%{"type" => "turn_completed"}), do: :completed
  def completion_signal?(%{"type" => "turn_failed"}), do: :failed
  def completion_signal?(%{"type" => "turn_cancelled"}), do: :failed
  def completion_signal?(_), do: :running

  @impl true
  def agent_name, do: "Codex"

  # -- Private helpers --

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp parse_timestamp(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{"raw" => args}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp output_to_string(output) when is_binary(output), do: output

  defp output_to_string(output) when is_map(output) or is_list(output) do
    Jason.encode!(output, pretty: false)
  end

  defp output_to_string(output), do: inspect(output)
end
