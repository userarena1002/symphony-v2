defmodule SymphonyElixir.SessionRegistry.SessionFile do
  @moduledoc """
  Tracks which files an agent session touched and how.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "session_files" do
    field :session_id, :string
    field :file_path, :string
    field :action, :string
    field :recorded_at, :utc_datetime
  end

  def changeset(file_touch, attrs) do
    file_touch
    |> cast(attrs, [:session_id, :file_path, :action, :recorded_at])
    |> validate_required([:session_id, :file_path, :action])
  end
end
