defmodule SymphonyElixir.SessionRegistry.Session do
  @moduledoc """
  Ecto schema for a completed agent session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "sessions" do
    field :issue_id, :string
    field :issue_identifier, :string
    field :workspace_path, :string
    field :status, :string
    field :total_tokens, :integer, default: 0
    field :cost_usd, :float
    field :duration_ms, :integer
    field :num_turns, :integer
    field :error, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w(id issue_id issue_identifier status started_at)a
  @optional ~w(workspace_path total_tokens cost_usd duration_ms num_turns error completed_at)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
