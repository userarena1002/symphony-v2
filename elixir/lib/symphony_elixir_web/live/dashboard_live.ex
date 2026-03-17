defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony V2.

  Features:
  - Real-time agent list with status indicators
  - Expandable per-agent live event streams (tool calls, reasoning, diffs)
  - Chat input for human-in-the-loop message injection
  - Preview links for testing completed features
  - Retry queue visibility
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.EventBus
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @max_events_per_agent 200

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:expanded, MapSet.new())
      |> assign(:agent_events, %{})
      |> assign(:subscribed_issues, MapSet.new())
      |> assign(:completed_agents, [])
      |> assign(:known_running_ids, MapSet.new())
      |> assign(:routing_events, [])

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      :ok = EventBus.subscribe_state()
      :ok = SymphonyElixir.Router.subscribe_routing()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    payload = load_payload()

    # Auto-subscribe to events for any running issues we haven't subscribed to yet
    socket = maybe_subscribe_running_issues(socket, payload)

    # Detect agents that finished (were running, now aren't) and add to completed list
    socket = track_completed_agents(socket, payload)

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info({:orchestrator_state, _state}, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  # Routing events from the Router
  def handle_info({:routing_event, event}, socket) do
    # Keep last 5 routing events, newest first
    events = Enum.take([event | socket.assigns.routing_events], 5)
    {:noreply, assign(socket, :routing_events, events)}
  end

  def handle_info({:agent_event, event}, socket) do
    issue_id = event.issue_id

    if issue_id && MapSet.member?(socket.assigns.expanded, issue_id) do
      events = Map.get(socket.assigns.agent_events, issue_id, [])
      updated = Enum.take([event | events], @max_events_per_agent)
      agent_events = Map.put(socket.assigns.agent_events, issue_id, updated)
      {:noreply, assign(socket, :agent_events, agent_events)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Events from the UI --

  @impl true
  def handle_event("toggle_expand", %{"issue-id" => issue_id}, socket) do
    expanded = socket.assigns.expanded

    socket =
      if MapSet.member?(expanded, issue_id) do
        EventBus.unsubscribe_events(issue_id)

        socket
        |> assign(:expanded, MapSet.delete(expanded, issue_id))
        |> assign(:subscribed_issues, MapSet.delete(socket.assigns.subscribed_issues, issue_id))
      else
        EventBus.subscribe_events(issue_id)

        socket
        |> assign(:expanded, MapSet.put(expanded, issue_id))
        |> assign(:subscribed_issues, MapSet.put(socket.assigns.subscribed_issues, issue_id))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => message, "issue-id" => issue_id}, socket)
      when is_binary(message) and message != "" do
    # Broadcast a user event through the EventBus
    user_event = SymphonyElixir.Event.user(message, :dashboard)
    EventBus.broadcast_event(issue_id, user_event)

    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony V2</p>
            <h1 class="hero-title">Operations Dashboard</h1>
            <p class="hero-copy">
              Live agent streams, preview links, and orchestration health.
            </p>
          </div>
          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span> Live
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <%!-- Metric cards --%>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Total Tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
          </article>
        </section>

        <%!-- Router activity --%>
        <%= if @routing_events != [] do %>
          <section class="section-card router-section">
            <div class="section-header">
              <h2 class="section-title">Router</h2>
            </div>
            <div class="router-events">
              <%= for event <- @routing_events do %>
                <div class={"router-event router-phase-#{event.phase}"}>
                  <div class="router-event-header">
                    <span class={"router-phase-badge router-badge-#{event.phase}"}>
                      <%= router_phase_label(event.phase) %>
                    </span>
                    <span class="router-issue"><%= event.issue_identifier %></span>
                    <span class="router-title muted"><%= event.issue_title %></span>
                    <span class="router-time mono muted"><%= format_event_time(event.timestamp) %></span>
                  </div>

                  <%= if event.phase == :evaluating do %>
                    <div class="router-candidates">
                      <div class="router-flow-line"></div>
                      <%= for session <- (event.data[:sessions] || []) do %>
                        <div class="router-candidate">
                          <span class="router-candidate-dot"></span>
                          <span class="router-candidate-id"><%= session.issue_identifier %></span>
                          <span class="muted">
                            <%= Enum.join(Enum.take(session.files_modified || [], 3), ", ") %>
                          </span>
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <%= if event.phase == :decided do %>
                    <div class={"router-decision #{if event.data[:decision][:action] == :reuse_session, do: "router-decision-reuse", else: "router-decision-new"}"}>
                      <div class="router-decision-icon">
                        <%= if event.data[:decision][:action] == :reuse_session do %>
                          <span class="router-icon-reuse">&#x21BB;</span>
                        <% else %>
                          <span class="router-icon-new">+</span>
                        <% end %>
                      </div>
                      <div class="router-decision-text">
                        <strong>
                          <%= if event.data[:decision][:action] == :reuse_session do %>
                            Reusing existing session
                          <% else %>
                            Starting fresh session
                          <% end %>
                        </strong>
                        <p class="muted"><%= event.data[:decision][:reasoning] %></p>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>

        <%!-- Running agents --%>
        <section class="section-card">
          <div class="section-header">
            <h2 class="section-title">Active Agents</h2>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions. Issues in active states will be picked up on the next poll.</p>
          <% else %>
            <div class="agent-list">
              <%= for entry <- @payload.running do %>
                <% is_expanded = MapSet.member?(@expanded, entry.issue_id) %>
                <div class={"agent-card #{if is_expanded, do: "agent-card-expanded", else: ""}"}>
                  <%!-- Agent row (always visible) --%>
                  <div class="agent-row" phx-click="toggle_expand" phx-value-issue-id={entry.issue_id}>
                    <div class="agent-row-main">
                      <span class="agent-identifier"><%= entry.issue_identifier %></span>
                      <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                      <span class="agent-session mono"><%= compact_session(entry.session_id) %></span>
                    </div>
                    <div class="agent-row-meta">
                      <span class="agent-runtime numeric">
                        <%= format_runtime(entry.started_at, @now) %>
                        <%= if entry.turn_count > 0 do %>
                          / <%= entry.turn_count %> turns
                        <% end %>
                      </span>
                      <span class="agent-tokens numeric"><%= format_int(entry.tokens.total_tokens) %> tokens</span>
                      <span class="agent-expand-icon"><%= if is_expanded, do: "▾", else: "▸" %></span>
                    </div>
                  </div>

                  <%!-- Expanded: live event stream + chat --%>
                  <%= if is_expanded do %>
                    <div class="agent-detail">
                      <%!-- Preview link --%>
                      <div class="agent-preview-bar">
                        <span class="muted">Workspace: <code><%= entry.workspace_path || "pending" %></code></span>
                        <%!-- Preview URL will be populated when available --%>
                      </div>

                      <%!-- Event stream --%>
                      <div class="event-stream" id={"stream-#{entry.issue_id}"} phx-update="stream">
                        <%= for event <- Enum.reverse(Map.get(@agent_events, entry.issue_id, [])) do %>
                          <div class={"event-line event-#{event.type}"} id={"evt-#{:erlang.phash2(event)}"}>
                            <span class="event-time mono"><%= format_event_time(event.timestamp) %></span>
                            <span class="event-badge"><%= event_badge(event) %></span>
                            <span class="event-content"><%= event_content(event) %></span>
                          </div>
                        <% end %>

                        <%= if Map.get(@agent_events, entry.issue_id, []) == [] do %>
                          <div class="event-line event-system">
                            <span class="muted">Waiting for events...</span>
                          </div>
                        <% end %>
                      </div>

                      <%!-- Chat input --%>
                      <form class="chat-form" phx-submit="send_message">
                        <input type="hidden" name="issue-id" value={entry.issue_id} />
                        <input
                          type="text"
                          name="message"
                          placeholder="Send a message to this agent..."
                          class="chat-input"
                          autocomplete="off"
                        />
                        <button type="submit" class="chat-send">Send</button>
                      </form>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </section>

        <%!-- Retry queue --%>
        <%= if @payload.retrying != [] do %>
          <section class="section-card">
            <div class="section-header">
              <h2 class="section-title">Retry Queue</h2>
            </div>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td><span class="issue-id"><%= entry.issue_identifier %></span></td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <%!-- Completed / idle agents --%>
        <%= if @completed_agents != [] do %>
          <section class="section-card">
            <div class="section-header">
              <h2 class="section-title">Idle Agents</h2>
              <p class="section-copy">Previously completed sessions from this runtime.</p>
            </div>
            <div class="agent-list">
              <%= for entry <- @completed_agents do %>
                <div class="agent-card agent-card-idle">
                  <div class="agent-row">
                    <div class="agent-row-main">
                      <span class="agent-identifier"><%= entry.issue_identifier %></span>
                      <span class="state-badge state-badge-idle">Completed</span>
                    </div>
                    <div class="agent-row-meta">
                      <span class="agent-runtime numeric muted">
                        <%= format_time_ago(entry.completed_at, @now) %> ago
                      </span>
                      <span class="agent-tokens numeric muted"><%= entry.event_count %> events</span>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>
      <% end %>
    </section>
    """
  end

  # -- Private helpers --

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp maybe_subscribe_running_issues(socket, payload) do
    case payload do
      %{running: running} when is_list(running) ->
        running_ids = running |> Enum.map(& &1.issue_id) |> MapSet.new()
        already_subscribed = socket.assigns.subscribed_issues

        # Subscribe to new running issues
        new_ids = MapSet.difference(running_ids, already_subscribed)
        Enum.each(new_ids, &EventBus.subscribe_events/1)

        assign(socket, :subscribed_issues, MapSet.union(already_subscribed, new_ids))

      _ ->
        socket
    end
  end

  defp track_completed_agents(socket, payload) do
    current_running_ids =
      case payload do
        %{running: running} when is_list(running) ->
          running |> Enum.map(& &1.issue_id) |> MapSet.new()
        _ ->
          MapSet.new()
      end

    prev_running_ids = socket.assigns.known_running_ids

    # Find agents that were running but aren't anymore
    finished_ids = MapSet.difference(prev_running_ids, current_running_ids)

    completed_agents =
      if MapSet.size(finished_ids) > 0 do
        new_completed =
          finished_ids
          |> Enum.map(fn id ->
            events = Map.get(socket.assigns.agent_events, id, [])
            %{
              issue_id: id,
              issue_identifier: find_identifier(events, id),
              completed_at: DateTime.utc_now(),
              event_count: length(events)
            }
          end)

        # Merge: if same issue_id already in completed, update it (don't duplicate)
        existing = socket.assigns.completed_agents
        merged = Enum.reduce(new_completed, existing, fn new_entry, acc ->
          case Enum.find_index(acc, &(&1.issue_id == new_entry.issue_id)) do
            nil ->
              # New issue — prepend
              [new_entry | acc]

            idx ->
              # Same issue — update in place (Edit continuation)
              old = Enum.at(acc, idx)
              updated = %{old |
                completed_at: new_entry.completed_at,
                event_count: old.event_count + new_entry.event_count
              }
              List.replace_at(acc, idx, updated)
          end
        end)

        Enum.take(merged, 20)
      else
        socket.assigns.completed_agents
      end

    socket
    |> assign(:completed_agents, completed_agents)
    |> assign(:known_running_ids, current_running_ids)
  end

  defp find_identifier(events, fallback_id) do
    # Try to find the identifier from event context, fall back to issue_id
    case events do
      [first | _] -> first.issue_id || fallback_id
      _ -> fallback_id
    end
  end

  defp total_runtime_seconds(payload, now) do
    completed = Map.get(payload.codex_totals, :seconds_running, 0)

    active =
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_since(entry.started_at, now)
      end)

    completed + active
  end

  defp runtime_seconds_since(%DateTime{} = started, %DateTime{} = now) do
    max(DateTime.diff(now, started, :second), 0)
  end

  defp runtime_seconds_since(started, %DateTime{} = now) when is_binary(started) do
    case DateTime.from_iso8601(started) do
      {:ok, parsed, _} -> runtime_seconds_since(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_since(_, _), do: 0

  defp format_runtime(started_at, now) do
    format_runtime_seconds(runtime_seconds_since(started_at, now))
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole = max(trunc(seconds), 0)
    mins = div(whole, 60)
    secs = rem(whole, 60)
    "#{mins}m #{secs}s"
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_), do: "0"

  defp compact_session(nil), do: "pending"
  defp compact_session(id) when is_binary(id), do: String.slice(id, 0, 12) <> "..."

  defp router_phase_label(:started), do: "ROUTING"
  defp router_phase_label(:evaluating), do: "EVALUATING"
  defp router_phase_label(:decided), do: "DECIDED"
  defp router_phase_label(phase), do: to_string(phase) |> String.upcase()

  defp format_time_ago(%DateTime{} = completed, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, completed, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_time_ago(_, _), do: "?"

  defp format_event_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_event_time(_), do: ""

  defp event_badge(%{type: :assistant}), do: "AI"
  defp event_badge(%{type: :tool_use}), do: "TOOL"
  defp event_badge(%{type: :tool_result, content: %{success: true}}), do: "OK"
  defp event_badge(%{type: :tool_result, content: %{success: false}}), do: "ERR"
  defp event_badge(%{type: :tool_result}), do: "RESULT"
  defp event_badge(%{type: :system}), do: "SYS"
  defp event_badge(%{type: :user}), do: "YOU"
  defp event_badge(%{type: :error}), do: "ERR"
  defp event_badge(_), do: "?"

  defp event_content(%{type: :assistant, content: %{message: msg}}) when is_binary(msg) do
    String.slice(msg, 0, 500)
  end

  defp event_content(%{type: :tool_use, content: %{tool: tool, input: input}}) do
    case tool do
      t when t in ["Read", "read", "read_file"] ->
        "Reading #{input["file_path"] || input[:file_path] || "file"}"

      t when t in ["Write", "write", "write_file"] ->
        "Writing #{input["file_path"] || input[:file_path] || "file"}"

      t when t in ["Edit", "edit", "edit_file"] ->
        "Editing #{input["file_path"] || input[:file_path] || "file"}"

      t when t in ["Bash", "bash", "shell"] ->
        cmd = input["command"] || input[:command] || ""
        "Running: #{String.slice(cmd, 0, 100)}"

      t when t in ["Glob", "glob"] ->
        "Searching: #{input["pattern"] || input[:pattern] || ""}"

      t when t in ["Grep", "grep"] ->
        "Grep: #{input["pattern"] || input[:pattern] || ""}"

      _ ->
        "#{tool}(#{inspect(input) |> String.slice(0, 100)})"
    end
  end

  defp event_content(%{type: :tool_result, content: %{tool: tool, output: output, success: success}}) do
    status = if success, do: "ok", else: "failed"
    output_preview = if is_binary(output), do: String.slice(output, 0, 200), else: ""
    "#{tool} #{status}: #{output_preview}"
  end

  defp event_content(%{type: :system, content: %{subtype: subtype}}) do
    "System: #{subtype}"
  end

  defp event_content(%{type: :user, content: %{message: msg}}) when is_binary(msg) do
    msg
  end

  defp event_content(%{type: :error, content: %{reason: reason}}) do
    "Error: #{inspect(reason)}"
  end

  defp event_content(_event), do: ""

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["edit"]) -> "#{base} state-badge-edit"
      String.contains?(normalized, ["review"]) -> "#{base} state-badge-review"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
