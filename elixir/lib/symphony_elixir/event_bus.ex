defmodule SymphonyElixir.EventBus do
  @moduledoc """
  PubSub wrapper for broadcasting agent events to subscribers.

  All agent events flow through the event bus after being normalized by the
  adapter. Subscribers include the dashboard (LiveView), memory registry,
  and structured log writer.

  ## Topics

  - `"agent:events:<issue_id>"` — all normalized events for a specific issue
  - `"agent:lifecycle:<issue_id>"` — lifecycle events only (started, completed, failed)
  - `"orchestrator:state"` — system-wide state updates (for dashboard overview)

  ## Usage

      # Subscribe to all events for an issue
      EventBus.subscribe_events("issue-123")

      # Broadcast an event
      EventBus.broadcast_event("issue-123", event)

      # In a LiveView or GenServer:
      def handle_info({:agent_event, event}, socket) do
        # process event
      end
  """

  alias SymphonyElixir.Event

  @pubsub SymphonyElixir.PubSub

  # -- Broadcasting --

  @doc "Broadcast a normalized event for a specific issue."
  @spec broadcast_event(String.t(), Event.t()) :: :ok | {:error, term()}
  def broadcast_event(issue_id, %Event{} = event) do
    event = %{event | issue_id: issue_id}

    Phoenix.PubSub.broadcast(@pubsub, events_topic(issue_id), {:agent_event, event})

    if lifecycle_event?(event) do
      Phoenix.PubSub.broadcast(@pubsub, lifecycle_topic(issue_id), {:agent_lifecycle, event})
    end

    :ok
  end

  @doc "Broadcast an orchestrator state update."
  @spec broadcast_state(map()) :: :ok | {:error, term()}
  def broadcast_state(state) do
    Phoenix.PubSub.broadcast(@pubsub, orchestrator_topic(), {:orchestrator_state, state})
  end

  # -- Subscribing --

  @doc "Subscribe to all events for a specific issue."
  @spec subscribe_events(String.t()) :: :ok | {:error, term()}
  def subscribe_events(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, events_topic(issue_id))
  end

  @doc "Unsubscribe from events for a specific issue."
  @spec unsubscribe_events(String.t()) :: :ok
  def unsubscribe_events(issue_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, events_topic(issue_id))
  end

  @doc "Subscribe to lifecycle events for a specific issue."
  @spec subscribe_lifecycle(String.t()) :: :ok | {:error, term()}
  def subscribe_lifecycle(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, lifecycle_topic(issue_id))
  end

  @doc "Subscribe to orchestrator state updates."
  @spec subscribe_state() :: :ok | {:error, term()}
  def subscribe_state do
    Phoenix.PubSub.subscribe(@pubsub, orchestrator_topic())
  end

  # -- Topic helpers --

  @spec events_topic(String.t()) :: String.t()
  def events_topic(issue_id), do: "agent:events:#{issue_id}"

  @spec lifecycle_topic(String.t()) :: String.t()
  def lifecycle_topic(issue_id), do: "agent:lifecycle:#{issue_id}"

  @spec orchestrator_topic() :: String.t()
  def orchestrator_topic, do: "orchestrator:state"

  # -- Event classification --

  defp lifecycle_event?(%Event{type: :system, content: %{subtype: subtype}})
       when subtype in [:init, :done, :exit, :timeout, :result] do
    true
  end

  defp lifecycle_event?(%Event{type: :error}), do: true
  defp lifecycle_event?(_event), do: false
end
