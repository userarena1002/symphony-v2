defmodule SymphonyElixir.SessionRegistry do
  @moduledoc """
  Persistent session registry backed by SQLite.

  Records completed agent sessions with metadata about what they worked on,
  which files they touched, and summaries of what they accomplished. This data
  is used by the Router to decide whether new issues should be assigned to
  existing idle sessions or start fresh.
  """

  require Logger

  alias SymphonyElixir.SessionRegistry.{Repo, Session, SessionFile, SessionSummary}
  alias SymphonyElixir.Event
  import Ecto.Query

  # -- Session lifecycle --

  @doc "Record a new session starting."
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
  end

  @doc "Mark a session as completed with final stats."
  @spec complete_session(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def complete_session(session_id, attrs) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        # Session wasn't recorded at start — create it now
        create_session(Map.put(attrs, :id, session_id))

      session ->
        session
        |> Session.changeset(Map.put(attrs, :status, "succeeded"))
        |> Repo.update()
    end
  end

  # -- File touch tracking --

  @doc "Record a file that was touched during a session."
  @spec record_file_touch(String.t(), String.t(), String.t()) :: {:ok, SessionFile.t()} | {:error, term()}
  def record_file_touch(session_id, file_path, action) do
    %SessionFile{}
    |> SessionFile.changeset(%{
      session_id: session_id,
      file_path: file_path,
      action: action,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc "Record file touches from a Symphony Event."
  @spec record_event(String.t(), Event.t()) :: :ok
  def record_event(session_id, %Event{} = event) when is_binary(session_id) do
    file_path = Event.file_path(event)
    action = Event.tool_action(event)

    if file_path && action do
      record_file_touch(session_id, file_path, action)
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Session summaries --

  @doc "Store a summary for a session."
  @spec save_summary(String.t(), map()) :: {:ok, SessionSummary.t()} | {:error, term()}
  def save_summary(session_id, attrs) do
    %SessionSummary{}
    |> SessionSummary.changeset(Map.put(attrs, :session_id, session_id))
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :session_id)
  end

  @doc "Generate and save a heuristic summary from file touches and workpad."
  @spec generate_heuristic_summary(String.t(), String.t() | nil) :: {:ok, SessionSummary.t()} | {:error, term()}
  def generate_heuristic_summary(session_id, workspace_path \\ nil) do
    files = get_file_touches(session_id)

    files_modified =
      files
      |> Enum.filter(&(&1.action in ["write", "edit"]))
      |> Enum.map(& &1.file_path)
      |> Enum.uniq()

    files_read =
      files
      |> Enum.filter(&(&1.action == "read"))
      |> Enum.map(& &1.file_path)
      |> Enum.uniq()

    codebase_areas =
      (files_modified ++ files_read)
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "."))
      |> Enum.sort()

    # Read workpad if available
    workpad = if workspace_path do
      case File.read(Path.join(workspace_path, ".symphony/workpad.md")) do
        {:ok, content} -> String.slice(content, 0, 3000)
        _ -> nil
      end
    end

    summary_text = """
    Files modified: #{Enum.join(files_modified, ", ")}
    Files read: #{Enum.join(Enum.take(files_read, 20), ", ")}
    Codebase areas: #{Enum.join(codebase_areas, ", ")}
    """

    save_summary(session_id, %{
      summary: String.trim(summary_text),
      codebase_areas: Jason.encode!(codebase_areas),
      files_modified: Jason.encode!(files_modified),
      workpad_content: workpad,
      generated_at: DateTime.utc_now()
    })
  end

  # -- Queries --

  @doc "Get all file touches for a session."
  @spec get_file_touches(String.t()) :: [SessionFile.t()]
  def get_file_touches(session_id) do
    SessionFile
    |> where([f], f.session_id == ^session_id)
    |> Repo.all()
  end

  @doc "Get the most recent successful session for an issue."
  @spec latest_session_for_issue(String.t()) :: Session.t() | nil
  def latest_session_for_issue(issue_id) do
    Session
    |> where([s], s.issue_id == ^issue_id and s.status == "succeeded")
    |> order_by([s], desc: s.completed_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get all recent successful sessions with summaries for the router.
  Returns sessions from the last N days with their summaries.
  """
  @spec get_idle_sessions(keyword()) :: [map()]
  def get_idle_sessions(opts \\ []) do
    max_age_days = Keyword.get(opts, :max_age_days, 7)
    limit_count = Keyword.get(opts, :limit, 10)
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 86400, :second)

    sessions =
      Session
      |> where([s], s.status == "succeeded" and s.completed_at > ^cutoff)
      |> order_by([s], desc: s.completed_at)
      |> limit(^limit_count)
      |> Repo.all()

    # Attach summaries
    Enum.map(sessions, fn session ->
      summary = Repo.get(SessionSummary, session.id)
      files = get_file_touches(session.id)

      %{
        session_id: session.id,
        issue_id: session.issue_id,
        issue_identifier: session.issue_identifier,
        workspace_path: session.workspace_path,
        status: session.status,
        total_tokens: session.total_tokens,
        completed_at: session.completed_at,
        summary: summary && summary.summary,
        workpad: summary && summary.workpad_content,
        codebase_areas: (summary && summary.codebase_areas) |> decode_json_or_nil(),
        files_modified: (summary && summary.files_modified) |> decode_json_or_nil(),
        files_touched_count: length(files)
      }
    end)
  end

  defp decode_json_or_nil(nil), do: []
  defp decode_json_or_nil(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} -> list
      _ -> []
    end
  end
end
