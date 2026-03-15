defmodule SymphonyElixir.ExecutionBackend.Adapters.Claude do
  @moduledoc """
  Agent adapter for Claude Code CLI.

  Translates between Symphony's execution interface and Claude Code's
  headless mode (`--output-format stream-json`). Normalizes Claude's
  streaming JSON events into `SymphonyElixir.Event` structs.

  ## Claude Code CLI flags used

  - `-p <prompt>` — non-interactive (print) mode
  - `--output-format stream-json` — streaming JSON events on stdout
  - `--allowedTools <tools>` — restrict which tools the agent can use
  - `--max-turns <n>` — limit the number of agentic turns
  - `--resume <session_id>` — resume a previous session
  - `--continue` — continue the most recent session
  """

  @behaviour SymphonyElixir.ExecutionBackend.AgentAdapter

  alias SymphonyElixir.Event

  @default_allowed_tools ~w(Read Write Edit Bash Glob Grep)

  @impl true
  def build_command(workspace, prompt, opts \\ []) do
    allowed_tools = Keyword.get(opts, :allowed_tools, @default_allowed_tools)
    max_turns = Keyword.get(opts, :max_turns, 20)
    extra_args = Keyword.get(opts, :extra_args, [])
    prompt_file = Keyword.get(opts, :prompt_file)

    prompt_arg = if prompt_file do
      ["-p", "\"$(cat #{shell_escape(prompt_file)})\""]
    else
      ["-p", shell_escape(prompt)]
    end

    args =
      ["claude"] ++
      prompt_arg ++
      [
        "--output-format", "stream-json",
        "--verbose",
        "--allowedTools", Enum.join(allowed_tools, ","),
        "--max-turns", to_string(max_turns),
      ] ++ extra_args

    Enum.join(args, " ")
  end

  @impl true
  def build_resume_command(workspace, session_id, prompt, opts \\ []) do
    extra_args = Keyword.get(opts, :extra_args, [])
    prompt_file = Keyword.get(opts, :prompt_file)

    prompt_arg = if prompt_file do
      ["-p", "\"$(cat #{shell_escape(prompt_file)})\""]
    else
      ["-p", shell_escape(prompt)]
    end

    args =
      ["claude",
       "--resume", shell_escape(session_id)] ++
      prompt_arg ++
      [
        "--output-format", "stream-json",
        "--verbose",
      ] ++ extra_args

    Enum.join(args, " ")
  end

  @impl true
  def parse_event(%{"type" => "assistant", "message" => message} = raw)
      when is_binary(message) do
    {:ok, %Event{
      type: :assistant,
      content: %{message: message},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Claude Code uses "content_block_delta" for streaming text chunks
  def parse_event(%{"type" => "content_block_delta", "delta" => %{"text" => text}} = raw)
      when is_binary(text) do
    {:ok, %Event{
      type: :assistant,
      content: %{message: text, streaming: true},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "tool_use", "name" => tool, "input" => input} = raw) do
    {:ok, %Event{
      type: :tool_use,
      content: %{tool: tool, input: input || %{}},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Alternative tool_use shape
  def parse_event(%{"type" => "tool_use", "tool" => tool, "input" => input} = raw) do
    {:ok, %Event{
      type: :tool_use,
      content: %{tool: tool, input: input || %{}},
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "tool_result", "name" => tool} = raw) do
    {:ok, %Event{
      type: :tool_result,
      content: %{
        tool: tool,
        output: Map.get(raw, "output", ""),
        success: Map.get(raw, "is_error") != true
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Alternative tool_result shape
  def parse_event(%{"type" => "tool_result", "tool" => tool} = raw) do
    {:ok, %Event{
      type: :tool_result,
      content: %{
        tool: tool,
        output: Map.get(raw, "output", ""),
        success: Map.get(raw, "is_error") != true
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  def parse_event(%{"type" => "system", "subtype" => subtype} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: safe_to_atom(subtype),
        session_id: Map.get(raw, "session_id"),
        result: Map.get(raw, "result"),
        message: Map.get(raw, "message")
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Message events (intermediate status)
  def parse_event(%{"type" => "message"} = raw) do
    role = Map.get(raw, "role", "assistant")
    content = Map.get(raw, "content", [])

    text =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "" do
      {:skip, :empty_message}
    else
      {:ok, %Event{
        type: if(role == "user", do: :user, else: :assistant),
        content: %{message: text},
        raw: raw,
        timestamp: parse_timestamp(raw)
      }}
    end
  end

  # Result event (final output)
  def parse_event(%{"type" => "result"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: :result,
        session_id: Map.get(raw, "session_id"),
        result: Map.get(raw, "result"),
        cost_usd: get_in(raw, ["cost_usd"]),
        duration_ms: get_in(raw, ["duration_ms"]),
        total_turns: get_in(raw, ["num_turns"])
      },
      raw: raw,
      timestamp: parse_timestamp(raw)
    }}
  end

  # Catch-all for unrecognized events
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
  def extract_session_id(%{"type" => "system", "session_id" => id}) when is_binary(id),
    do: {:ok, id}

  def extract_session_id(%{"session_id" => id}) when is_binary(id),
    do: {:ok, id}

  def extract_session_id(_raw), do: :not_found

  @impl true
  def completion_signal?(%{"type" => "result", "is_error" => true}), do: :failed
  def completion_signal?(%{"type" => "result"}), do: :completed
  def completion_signal?(%{"type" => "system", "subtype" => "done", "result" => "error"}), do: :failed
  def completion_signal?(%{"type" => "system", "subtype" => "done"}), do: :completed
  def completion_signal?(_), do: :running

  @impl true
  def agent_name, do: "Claude Code"

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

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> String.to_atom(str)
  end
end
