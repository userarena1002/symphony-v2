defmodule SymphonyElixir.Router do
  @moduledoc """
  Routes new issues to either a fresh session or an existing idle session.

  Emits routing events through PubSub so the dashboard can visualize
  the routing decision process in real-time.
  """

  require Logger

  alias SymphonyElixir.{Config, EventBus, SessionRegistry}
  alias SymphonyElixir.Linear.Issue

  @type decision :: %{
          action: :new_session | :reuse_session,
          session_id: String.t() | nil,
          workspace_path: String.t() | nil,
          reasoning: String.t()
        }

  @doc "Route an issue. Emits events through PubSub for dashboard visualization."
  @spec route(Issue.t()) :: decision()
  def route(%Issue{} = issue) do
    broadcast_routing(:started, issue, %{})

    idle_sessions = SessionRegistry.get_idle_sessions(max_age_days: 14, limit: 10)

    if idle_sessions == [] do
      decision = %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: "No prior sessions available"}
      broadcast_routing(:decided, issue, %{decision: decision, candidates: 0})
      decision
    else
      broadcast_routing(:evaluating, issue, %{
        candidates: length(idle_sessions),
        sessions: Enum.map(idle_sessions, fn s ->
          %{issue_identifier: s.issue_identifier, session_id: s.session_id,
            files_modified: s.files_modified || [], codebase_areas: s.codebase_areas || []}
        end)
      })

      decision = ask_llm(issue, idle_sessions)
      broadcast_routing(:decided, issue, %{decision: decision, candidates: length(idle_sessions)})
      decision
    end
  end

  # -- PubSub events for dashboard --

  @routing_topic "router:events"

  defp broadcast_routing(phase, issue, data) do
    event = %{
      phase: phase,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      timestamp: DateTime.utc_now(),
      data: data
    }

    Phoenix.PubSub.broadcast(
      SymphonyElixir.PubSub,
      @routing_topic,
      {:routing_event, event}
    )
  rescue
    _ -> :ok
  end

  @spec subscribe_routing() :: :ok
  def subscribe_routing do
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, @routing_topic)
  end

  # -- LLM decision --

  defp ask_llm(issue, idle_sessions) do
    prompt = build_router_prompt(issue, idle_sessions)

    Logger.info("Router: asking LLM to route #{issue.identifier} with #{length(idle_sessions)} candidates")

    case ClaudeCode.query(prompt, max_turns: 1, dangerously_skip_permissions: true) do
      {:ok, result} ->
        parse_decision(result, idle_sessions)

      {:error, reason} ->
        Logger.warning("Router: LLM decision failed (#{inspect(reason)}), starting fresh")
        %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: "LLM decision failed: #{inspect(reason)}"}
    end
  end

  defp build_router_prompt(issue, idle_sessions) do
    sessions_text =
      idle_sessions
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {s, i} ->
        """
        ### Session #{i}: #{s.issue_identifier}
        - Session ID: #{s.session_id}
        - Workspace: #{s.workspace_path}
        - Completed: #{s.completed_at}
        - Tokens used: #{s.total_tokens}
        - Files modified: #{Enum.join(s.files_modified || [], ", ")}
        - Codebase areas: #{Enum.join(s.codebase_areas || [], ", ")}
        #{if s.workpad, do: "- Workpad:\n#{String.slice(s.workpad, 0, 1500)}", else: "- No workpad available"}
        """
      end)

    """
    You are a routing assistant for a coding agent orchestrator. You need to decide
    whether a new issue should start in a fresh workspace or be assigned to an
    existing idle agent session that already has relevant context.

    ## New Issue
    - Identifier: #{issue.identifier}
    - Title: #{issue.title}
    - Description: #{issue.description || "No description"}

    ## Available Idle Sessions
    #{sessions_text}

    ## Decision

    If one of the idle sessions worked on code that is relevant to the new issue
    (same files, same area of the codebase, related functionality), respond with:

    REUSE: <session number>
    REASON: <one sentence explaining why this session's context is relevant>

    If none of the sessions are relevant (different area of the codebase,
    unrelated functionality), respond with:

    NEW
    REASON: <one sentence explaining why a fresh start is better>

    Respond with ONLY the decision format above, nothing else.
    """
  end

  defp parse_decision(result, idle_sessions) do
    text = extract_result_text(result)

    cond do
      String.contains?(text, "REUSE:") ->
        case Regex.run(~r/REUSE:\s*(\d+)/, text) do
          [_, num_str] ->
            idx = String.to_integer(num_str) - 1
            session = Enum.at(idle_sessions, idx)

            if session do
              reason = extract_reason(text)
              Logger.info("Router: reusing session #{session.session_id} for #{session.issue_identifier} - #{reason}")

              %{
                action: :reuse_session,
                session_id: session.session_id,
                workspace_path: session.workspace_path,
                reasoning: reason
              }
            else
              %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: "Invalid session reference"}
            end

          _ ->
            %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: "Could not parse REUSE decision"}
        end

      String.contains?(text, "NEW") ->
        reason = extract_reason(text)
        Logger.info("Router: starting fresh - #{reason}")
        %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: reason}

      true ->
        Logger.warning("Router: unexpected LLM response, starting fresh: #{String.slice(text, 0, 200)}")
        %{action: :new_session, session_id: nil, workspace_path: nil, reasoning: "Unparseable response"}
    end
  end

  defp extract_reason(text) do
    case Regex.run(~r/REASON:\s*(.+)/s, text) do
      [_, reason] -> String.trim(reason) |> String.slice(0, 200)
      _ -> "No reason provided"
    end
  end

  defp extract_result_text(%{result: text}) when is_binary(text), do: text
  defp extract_result_text(%{"result" => text}) when is_binary(text), do: text
  defp extract_result_text(other), do: inspect(other) |> String.slice(0, 500)
end
