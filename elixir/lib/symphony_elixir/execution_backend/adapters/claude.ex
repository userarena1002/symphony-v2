defmodule SymphonyElixir.ExecutionBackend.Adapters.Claude do
  @moduledoc """
  Agent adapter for Claude Code CLI.

  Translates between Symphony's execution interface and Claude Code's
  headless mode (`--output-format stream-json`). Normalizes Claude's
  streaming JSON events into `SymphonyElixir.Event` structs.

  ## Claude Code stream-json event format

  Events are line-delimited JSON. The key types are:

  - `{"type":"system","subtype":"init","session_id":"..."}` — session start
  - `{"type":"assistant","message":{"content":[...]}}` — assistant turn (text + tool_use blocks nested inside)
  - `{"type":"user","tool_use_result":{...}}` — tool result
  - `{"type":"result","subtype":"success"}` — session complete
  - `{"type":"rate_limit_event",...}` — rate limit info
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

  # ── Event parsing ──
  # Claude Code stream-json nests tool calls and text inside
  # {"type":"assistant","message":{"content":[...]}}
  # We flatten these into individual Event structs.

  @impl true
  def parse_event(%{"type" => "system", "subtype" => subtype} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: safe_to_atom(subtype),
        session_id: Map.get(raw, "session_id"),
        result: Map.get(raw, "result"),
        model: Map.get(raw, "model")
      },
      raw: raw,
      timestamp: DateTime.utc_now()
    }}
  end

  # Assistant message — contains text and/or tool_use blocks inside message.content[]
  def parse_event(%{"type" => "assistant", "message" => %{"content" => content}} = raw)
      when is_list(content) do
    session_id = Map.get(raw, "session_id")

    # Extract text blocks
    text_parts =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
      |> Enum.map(& &1["text"])

    # Extract tool_use blocks
    tool_uses =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "tool_use"))

    # Build events for each content block
    events =
      Enum.map(text_parts, fn text ->
        %Event{
          type: :assistant,
          content: %{message: text},
          raw: nil,
          timestamp: DateTime.utc_now(),
          session_id: session_id
        }
      end) ++
      Enum.map(tool_uses, fn tool ->
        %Event{
          type: :tool_use,
          content: %{
            tool: Map.get(tool, "name", "unknown"),
            input: Map.get(tool, "input", %{}),
            tool_use_id: Map.get(tool, "id")
          },
          raw: nil,
          timestamp: DateTime.utc_now(),
          session_id: session_id
        }
      end)

    case events do
      [] -> {:skip, :empty_assistant}
      [single] -> {:ok, single}
      multiple -> {:ok_multi, multiple}
    end
  end

  # User message with tool result
  def parse_event(%{"type" => "user", "tool_use_result" => result} = raw)
      when is_map(result) do
    file_info = Map.get(result, "file", %{})
    output = Map.get(result, "content", "")

    {:ok, %Event{
      type: :tool_result,
      content: %{
        tool: "file_read",
        output: truncate(output, 500),
        success: true,
        file_path: Map.get(file_info, "filePath")
      },
      raw: nil,
      timestamp: DateTime.utc_now(),
      session_id: Map.get(raw, "session_id")
    }}
  end

  # User message with tool_result in content array
  def parse_event(%{"type" => "user", "message" => %{"content" => content}} = raw)
      when is_list(content) do
    tool_results =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "tool_result"))

    case tool_results do
      [] -> {:skip, :empty_user}
      [result | _] ->
        {:ok, %Event{
          type: :tool_result,
          content: %{
            tool: "tool",
            output: truncate(Map.get(result, "content", ""), 500),
            success: true
          },
          raw: nil,
          timestamp: DateTime.utc_now(),
          session_id: Map.get(raw, "session_id")
        }}
    end
  end

  # Result event (session completion)
  def parse_event(%{"type" => "result"} = raw) do
    {:ok, %Event{
      type: :system,
      content: %{
        subtype: :result,
        session_id: Map.get(raw, "session_id"),
        result: Map.get(raw, "result"),
        is_error: Map.get(raw, "is_error", false),
        cost_usd: Map.get(raw, "total_cost_usd"),
        duration_ms: Map.get(raw, "duration_ms"),
        total_turns: Map.get(raw, "num_turns"),
        usage: Map.get(raw, "usage")
      },
      raw: raw,
      timestamp: DateTime.utc_now()
    }}
  end

  # Rate limit event
  def parse_event(%{"type" => "rate_limit_event"} = _raw) do
    {:skip, :rate_limit}
  end

  # Catch-all
  def parse_event(%{"type" => type} = raw) when is_binary(type) do
    {:ok, %Event{
      type: :unknown,
      content: %{original_type: type},
      raw: raw,
      timestamp: DateTime.utc_now()
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
  def completion_signal?(_), do: :running

  @impl true
  def agent_name, do: "Claude Code"

  # -- Private helpers --

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> String.to_atom(str)
  end

  defp truncate(text, max_len) when is_binary(text) and byte_size(text) > max_len do
    String.slice(text, 0, max_len) <> "..."
  end

  defp truncate(text, _max_len) when is_binary(text), do: text
  defp truncate(other, _max_len), do: inspect(other) |> String.slice(0, 200)
end
