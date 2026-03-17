defmodule SymphonyElixir.SessionRegistry.Repo do
  @moduledoc """
  Ecto repository backed by SQLite for session persistence.
  Database stored at ~/.cache/symphony_v2/sessions.db
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @spec db_path() :: String.t()
  def db_path do
    dir = Path.expand("~/.cache/symphony_v2")
    File.mkdir_p!(dir)
    Path.join(dir, "sessions.db")
  end
end
