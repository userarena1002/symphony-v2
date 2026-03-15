defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace using a headless CLI agent.

  Replaces the previous Codex AppServer JSON-RPC approach. The agent runs
  autonomously as a subprocess — all tool calls happen internally. Events
  are streamed via stdout and broadcast through the EventBus for dashboard
  and memory registry consumption.
  """

  require Logger

  alias SymphonyElixir.{Config, EventBus, Linear.Issue, PromptBuilder, Workspace}
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
    prompt = PromptBuilder.build_prompt(issue, opts)

    on_event = build_event_handler(issue, orchestrator_pid)

    cli_opts = [
      backend: config.agent.backend,
      allowed_tools: config.agent.allowed_tools,
      max_turns: config.agent.max_turns,
      timeout_ms: config.agent.session_timeout_ms
    ]

    case HeadlessCLI.start(workspace, prompt, cli_opts) do
      {:ok, handle} ->
        try do
          case HeadlessCLI.run(handle, on_event: on_event, timeout_ms: config.agent.session_timeout_ms) do
            {:ok, result} ->
              Logger.info("Agent session completed for #{issue_context(issue)} session_id=#{result[:session_id]}")
              :ok

            {:error, reason} ->
              Logger.warning("Agent session ended with error for #{issue_context(issue)}: #{inspect(reason)}")
              {:error, reason}
          end
        after
          HeadlessCLI.stop(handle)
        end

      {:error, reason} ->
        Logger.error("Failed to start agent session for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Event handling --

  defp build_event_handler(%Issue{id: issue_id} = issue, orchestrator_pid) do
    fn event ->
      # Attach issue context to the event
      event = %{event | issue_id: issue_id}

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
