defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    # Ensure SQLite database and migrations are run
    :ok = setup_session_registry()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.SessionRegistry.Repo,
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.PreviewManager,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp setup_session_registry do
    repo = SymphonyElixir.SessionRegistry.Repo
    db_path = repo.db_path()

    # Configure the repo at runtime
    Application.put_env(:symphony_elixir, repo,
      database: db_path,
      pool_size: 1
    )

    # Create tables if they don't exist (simple migration)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

    # Start repo temporarily to run migration, then stop it
    # (it will be started properly by the supervision tree)
    case repo.start_link() do
      {:ok, pid} ->
        Ecto.Migrator.run(repo, :up, all: true)
        GenServer.stop(pid)
        :ok

      {:error, {:already_started, _}} ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
