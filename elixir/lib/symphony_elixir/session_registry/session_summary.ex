defmodule SymphonyElixir.SessionRegistry.SessionSummary do
  @moduledoc """
  Stores a summary of what a session accomplished for use by the router.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}

  schema "session_summaries" do
    field :summary, :string
    field :codebase_areas, :string
    field :files_modified, :string
    field :workpad_content, :string
    field :generated_at, :utc_datetime
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:session_id, :summary, :codebase_areas, :files_modified, :workpad_content, :generated_at])
    |> validate_required([:session_id, :summary])
  end
end
