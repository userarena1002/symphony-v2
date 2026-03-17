defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace using a headless CLI agent.

  Replaces the previous Codex AppServer JSON-RPC approach. The agent runs
  autonomously as a subprocess — all tool calls happen internally. Events
  are streamed via stdout and broadcast through the EventBus for dashboard
  and memory registry consumption.
  """

  require Logger

  alias SymphonyElixir.{Config, EventBus, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.ExecutionBackend.HeadlessCLI

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, orchestrator_pid \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, orchestrator_pid, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, orchestrator_pid, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, orchestrator_pid, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, orchestrator_pid, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _orchestrator_pid, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, orchestrator_pid, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(orchestrator_pid, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_session(workspace, issue, orchestrator_pid, opts)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Agent session execution --

  defp run_agent_session(workspace, issue, orchestrator_pid, opts) do
    config = Config.settings!()

    # Build prompt based on issue state — Edit state gets a special prompt
    # that includes reviewer comments and focuses on tweaks, not full implementation
    prompt = build_session_prompt(issue, opts)

    # Debug: write the actual prompt to a file so we can inspect it
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, ".symphony/last_prompt.txt"), prompt)

    on_event = build_event_handler(issue, orchestrator_pid)

    # For Edit state, resume the previous Claude session to preserve context
    resume_id = if issue.state == "Edit" do
      HeadlessCLI.load_session_id(workspace)
    else
      nil
    end

    if resume_id do
      Logger.info("Resuming session #{resume_id} for #{issue_context(issue)} (Edit mode)")
    end

    cli_opts = [
      backend: config.agent.backend,
      on_event: on_event,
      resume_session_id: resume_id
    ]

    case HeadlessCLI.run_session(workspace, prompt, cli_opts) do
      {:ok, result} ->
        Logger.info("Agent session completed for #{issue_context(issue)} session_id=#{result[:session_id]}")

        # Move issue to Human Review so the orchestrator stops redispatching
        case Tracker.update_issue_state(issue.id, "Human Review") do
          :ok ->
            Logger.info("Moved #{issue_context(issue)} to Human Review")

          {:error, reason} ->
            Logger.warning("Failed to move #{issue_context(issue)} to Human Review: #{inspect(reason)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("Agent session ended with error for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Prompt building --

  defp build_session_prompt(%Issue{state: state} = issue, opts) when state in ["Edit", "edit"] do
    # Edit state: fetch reviewer comments and build a focused edit prompt
    Logger.info("BUILD EDIT PROMPT for #{issue.identifier} (state=#{state})")
    base_prompt = PromptBuilder.build_prompt(issue, opts)
    comments = fetch_reviewer_comments(issue)
    Logger.info("Fetched #{length(comments)} reviewer comments for #{issue.identifier}")

    if comments == [] do
      Logger.warning("No reviewer comments found for #{issue.identifier} in Edit state, using base prompt")
      base_prompt
    else
      Logger.info("Building edit prompt with #{length(comments)} comments")
      edit_prompt(issue, comments, base_prompt)
    end
  end

  defp build_session_prompt(issue, opts) do
    PromptBuilder.build_prompt(issue, opts)
  end

  defp fetch_reviewer_comments(%Issue{id: issue_id}) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} -> comments
      {:error, _reason} -> []
    end
  end

  defp edit_prompt(issue, comments, _base_prompt) do
    comment_text =
      comments
      |> Enum.map(fn c ->
        author = get_in(c, ["user", "name"]) || "Reviewer"
        body = c["body"] || ""
        "**#{author}** (#{c["createdAt"]}):\n#{body}"
      end)
      |> Enum.join("\n\n---\n\n")

    # Gather workspace context so the agent knows what's already been done
    workspace_context = gather_workspace_context(issue)

    """
    You are resuming work on issue #{issue.identifier}: #{issue.title}

    This issue was previously implemented and is now in the Edit state because
    the reviewer has requested changes. The workspace already contains your
    previous work on branch #{issue.identifier}.

    ## What was already done

    #{workspace_context}

    ## Reviewer feedback

    The following comments were left on the ticket. Read them carefully and
    make the requested changes:

    #{comment_text}

    ## Instructions

    1. You are in the SAME workspace as before. Your previous code changes
       are already committed on branch `#{issue.identifier}`.
    2. Start by reading the specific files mentioned in the feedback.
       Do NOT re-explore the whole codebase - you already did that.
    3. Make ONLY the requested changes. Do not redo or refactor anything
       that wasn't mentioned in the feedback.
    4. After making changes:
       - Run `npm run typecheck` to validate
       - Commit the changes with a clear message referencing the feedback
       - Push the branch (it already exists on the remote)
       - The PR will update automatically
    5. Post a Linear comment summarizing what you changed.
       Use curl with the LINEAR_API_KEY environment variable:
       ```
       [Agent] Edit complete - applied reviewer feedback
       - Changes: <what you changed>
       - Validation: npm run typecheck passed
       ```

    Keep this focused and fast. The reviewer is waiting.
    """
  end

  defp gather_workspace_context(issue) do
    workspace = Path.join(
      Path.expand(Config.settings!().workspace.root),
      SymphonyElixir.PathSafety.safe_identifier(issue.identifier)
    )

    parts = []

    # Read the workpad if it exists
    workpad_path = Path.join(workspace, ".symphony/workpad.md")
    parts = case File.read(workpad_path) do
      {:ok, content} when content != "" ->
        parts ++ ["### Previous workpad\n#{String.slice(content, 0, 2000)}"]
      _ ->
        parts
    end

    # Get git log to show what was committed
    parts = case System.cmd("git", ["log", "--oneline", "-10", "--no-decorate"],
                  cd: workspace, stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        parts ++ ["### Git history\n```\n#{String.trim(output)}\n```"]
      _ ->
        parts
    end

    # Get list of changed files vs main
    parts = case System.cmd("git", ["diff", "--name-only", "main...HEAD"],
                  cd: workspace, stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        parts ++ ["### Files changed vs main\n```\n#{String.trim(output)}\n```"]
      _ ->
        parts
    end

    case parts do
      [] -> "No workspace context available. Read the git log and changed files to understand what was previously done."
      _ -> Enum.join(parts, "\n\n")
    end
  end

  # -- Event handling --

  defp build_event_handler(%Issue{id: issue_id} = issue, orchestrator_pid) do
    fn event ->
      # Attach issue context to the event
      event = %{event | issue_id: issue_id}

      Logger.info("Agent event for #{issue_id}: type=#{event.type} content=#{inspect(Map.keys(event.content))}")

      # Broadcast through EventBus for dashboard/memory/logs
      EventBus.broadcast_event(issue_id, event)

      # Also send to orchestrator for state tracking (session_id, timestamps)
      send_orchestrator_update(orchestrator_pid, issue, event)

      :ok
    end
  end

  defp send_orchestrator_update(pid, %Issue{id: issue_id}, event)
       when is_pid(pid) and is_binary(issue_id) do
    send(pid, {:agent_event, issue_id, event})
    :ok
  end

  defp send_orchestrator_update(_pid, _issue, _event), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  # -- Worker host selection --

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
