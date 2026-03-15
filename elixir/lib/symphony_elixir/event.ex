defmodule SymphonyElixir.Event do
  @moduledoc """
  Normalized event struct emitted by all agent backends.

  Every agent adapter (Claude, Codex, etc.) parses its raw stdout JSON into this
  struct. All downstream consumers — dashboard, event bus, memory registry, log
  writer — work exclusively with this normalized form and never inspect raw
  agent output.
  """

  @type event_type ::
          :assistant
          | :tool_use
          | :tool_result
          | :system
          | :user
          | :error
          | :unknown

  @type t :: %__MODULE__{
          type: event_type(),
          content: map(),
          raw: map() | nil,
          timestamp: DateTime.t() | nil,
          issue_id: String.t() | nil,
          session_id: String.t() | nil
        }

  @enforce_keys [:type, :content]
  defstruct [:type, :content, :raw, :timestamp, :issue_id, :session_id]

  @spec assistant(String.t(), map() | nil) :: t()
  def assistant(message, raw \\ nil) do
    %__MODULE__{
      type: :assistant,
      content: %{message: message},
      raw: raw,
      timestamp: DateTime.utc_now()
    }
  end

  @spec tool_use(String.t(), map(), map() | nil) :: t()
  def tool_use(tool, input, raw \\ nil) do
    %__MODULE__{
      type: :tool_use,
      content: %{tool: tool, input: input},
      raw: raw,
      timestamp: DateTime.utc_now()
    }
  end

  @spec tool_result(String.t(), String.t(), boolean(), map() | nil) :: t()
  def tool_result(tool, output, success, raw \\ nil) do
    %__MODULE__{
      type: :tool_result,
      content: %{tool: tool, output: output, success: success},
      raw: raw,
      timestamp: DateTime.utc_now()
    }
  end

  @spec system(atom(), map(), map() | nil) :: t()
  def system(subtype, data \\ %{}, raw \\ nil) do
    %__MODULE__{
      type: :system,
      content: Map.put(data, :subtype, subtype),
      raw: raw,
      timestamp: DateTime.utc_now()
    }
  end

  @spec user(String.t(), atom()) :: t()
  def user(message, source \\ :dashboard) do
    %__MODULE__{
      type: :user,
      content: %{message: message, source: source},
      raw: nil,
      timestamp: DateTime.utc_now()
    }
  end

  @spec error(term(), map() | nil) :: t()
  def error(reason, raw \\ nil) do
    %__MODULE__{
      type: :error,
      content: %{reason: reason},
      raw: raw,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Attach issue and session context to an event."
  @spec with_context(t(), String.t(), String.t() | nil) :: t()
  def with_context(%__MODULE__{} = event, issue_id, session_id \\ nil) do
    %{event | issue_id: issue_id, session_id: session_id}
  end

  @doc "Extract file path from a tool_use or tool_result event, if present."
  @spec file_path(t()) :: String.t() | nil
  def file_path(%__MODULE__{type: type, content: content})
      when type in [:tool_use, :tool_result] do
    case content do
      %{input: %{"file_path" => path}} when is_binary(path) -> path
      %{input: %{file_path: path}} when is_binary(path) -> path
      %{input: %{"path" => path}} when is_binary(path) -> path
      _ -> nil
    end
  end

  def file_path(_event), do: nil

  @doc "Returns the tool action type for memory registry recording."
  @spec tool_action(t()) :: String.t() | nil
  def tool_action(%__MODULE__{type: :tool_use, content: %{tool: tool}}) do
    case tool do
      t when t in ["Read", "read", "read_file"] -> "read"
      t when t in ["Write", "write", "write_file"] -> "write"
      t when t in ["Edit", "edit", "edit_file"] -> "edit"
      t when t in ["Bash", "bash", "shell"] -> "exec"
      t when t in ["Glob", "glob"] -> "search"
      t when t in ["Grep", "grep"] -> "search"
      _ -> "other"
    end
  end

  def tool_action(_event), do: nil
end
