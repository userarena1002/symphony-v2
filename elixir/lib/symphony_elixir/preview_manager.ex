defmodule SymphonyElixir.PreviewManager do
  @moduledoc """
  Manages per-issue preview server ports.

  When an agent completes work on an issue, the preview manager can start
  a dev server in the workspace on a unique port so the user can test the
  feature in a browser. Each issue gets its own port from a configurable range.

  Preview URLs are exposed on 0.0.0.0 so they're accessible from other
  devices on the network (e.g., via Tailscale).

  ## Usage

      {:ok, port} = PreviewManager.start_preview(issue_id, workspace_path)
      url = PreviewManager.preview_url(issue_id)
      PreviewManager.stop_preview(issue_id)
  """

  use GenServer
  require Logger

  @default_port_range_start 4100
  @default_port_range_end 4199
  @default_start_command "npm run dev -- --port {port} --host 0.0.0.0"

  defstruct [
    :port_range_start,
    :port_range_end,
    :start_command,
    previews: %{},
    port_assignments: %{}
  ]

  @type preview :: %{
          port: non_neg_integer(),
          workspace: Path.t(),
          pid: port() | nil,
          started_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start_preview(String.t(), Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def start_preview(issue_id, workspace_path, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:start_preview, issue_id, workspace_path})
  end

  @spec stop_preview(String.t(), keyword()) :: :ok
  def stop_preview(issue_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:stop_preview, issue_id})
  end

  @spec preview_url(String.t(), keyword()) :: String.t() | nil
  def preview_url(issue_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:preview_url, issue_id})
  end

  @spec list_previews(keyword()) :: [%{issue_id: String.t(), port: non_neg_integer(), url: String.t()}]
  def list_previews(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_previews)
  end

  @spec stop_all(keyword()) :: :ok
  def stop_all(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :stop_all)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      port_range_start: Keyword.get(opts, :port_range_start, @default_port_range_start),
      port_range_end: Keyword.get(opts, :port_range_end, @default_port_range_end),
      start_command: Keyword.get(opts, :start_command, @default_start_command)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_preview, issue_id, workspace_path}, _from, state) do
    case Map.get(state.previews, issue_id) do
      %{port: port} ->
        {:reply, {:ok, port}, state}

      nil ->
        case allocate_port(state) do
          {:ok, port} ->
            case start_dev_server(workspace_path, port, state.start_command) do
              {:ok, server_port} ->
                preview = %{
                  port: port,
                  workspace: workspace_path,
                  pid: server_port,
                  started_at: DateTime.utc_now()
                }

                state = %{state |
                  previews: Map.put(state.previews, issue_id, preview),
                  port_assignments: Map.put(state.port_assignments, port, issue_id)
                }

                Logger.info("Started preview for #{issue_id} on port #{port}")
                {:reply, {:ok, port}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, :no_ports_available} ->
            {:reply, {:error, :no_ports_available}, state}
        end
    end
  end

  @impl true
  def handle_call({:stop_preview, issue_id}, _from, state) do
    case Map.get(state.previews, issue_id) do
      %{port: port, pid: pid} ->
        kill_server(pid)
        Logger.info("Stopped preview for #{issue_id} on port #{port}")

        state = %{state |
          previews: Map.delete(state.previews, issue_id),
          port_assignments: Map.delete(state.port_assignments, port)
        }

        {:reply, :ok, state}

      nil ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:preview_url, issue_id}, _from, state) do
    case Map.get(state.previews, issue_id) do
      %{port: port} ->
        {:reply, "http://0.0.0.0:#{port}", state}

      nil ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_call(:list_previews, _from, state) do
    previews =
      state.previews
      |> Enum.map(fn {issue_id, %{port: port}} ->
        %{issue_id: issue_id, port: port, url: "http://0.0.0.0:#{port}"}
      end)
      |> Enum.sort_by(& &1.port)

    {:reply, previews, state}
  end

  @impl true
  def handle_call(:stop_all, _from, state) do
    Enum.each(state.previews, fn {_issue_id, %{pid: pid}} ->
      kill_server(pid)
    end)

    {:reply, :ok, %{state | previews: %{}, port_assignments: %{}}}
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, state) when is_port(port) do
    # Dev server exited — find and remove the preview
    case Enum.find(state.previews, fn {_id, preview} -> preview.pid == port end) do
      {issue_id, %{port: assigned_port}} ->
        Logger.info("Preview server for #{issue_id} exited")

        state = %{state |
          previews: Map.delete(state.previews, issue_id),
          port_assignments: Map.delete(state.port_assignments, assigned_port)
        }

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private helpers --

  defp allocate_port(state) do
    used_ports = Map.keys(state.port_assignments)

    available =
      state.port_range_start..state.port_range_end
      |> Enum.find(fn port -> port not in used_ports end)

    case available do
      nil -> {:error, :no_ports_available}
      port -> {:ok, port}
    end
  end

  defp start_dev_server(workspace, port, command_template) do
    command = String.replace(command_template, "{port}", to_string(port))

    bash = System.find_executable("bash")

    if is_nil(bash) do
      {:error, :bash_not_found}
    else
      # Check if workspace has a package.json or similar
      has_dev_server? =
        File.exists?(Path.join(workspace, "package.json")) or
        File.exists?(Path.join(workspace, "mix.exs")) or
        File.exists?(Path.join(workspace, "Makefile"))

      if has_dev_server? do
        port_handle =
          Port.open(
            {:spawn_executable, String.to_charlist(bash)},
            [
              :binary,
              :exit_status,
              args: [~c"-lc", String.to_charlist(command)],
              cd: String.to_charlist(workspace)
            ]
          )

        {:ok, port_handle}
      else
        Logger.debug("No package.json/mix.exs/Makefile found in #{workspace}, skipping preview server")
        {:error, :no_dev_server_config}
      end
    end
  end

  defp kill_server(nil), do: :ok

  defp kill_server(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      info ->
        case Keyword.get(info, :os_pid) do
          nil ->
            try do
              Port.close(port)
            rescue
              ArgumentError -> :ok
            end

          os_pid ->
            # Kill the process group to ensure child processes are also killed
            System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)

            try do
              Port.close(port)
            rescue
              ArgumentError -> :ok
            end
        end
    end
  end

  defp kill_server(_), do: :ok
end
