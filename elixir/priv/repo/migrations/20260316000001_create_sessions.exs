defmodule SymphonyElixir.SessionRegistry.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :issue_id, :string, null: false
      add :issue_identifier, :string, null: false
      add :workspace_path, :string
      add :status, :string, null: false
      add :total_tokens, :integer, default: 0
      add :cost_usd, :float
      add :duration_ms, :integer
      add :num_turns, :integer
      add :error, :string
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:issue_id])
    create index(:sessions, [:issue_identifier])
    create index(:sessions, [:status])

    create table(:session_files) do
      add :session_id, :string, null: false
      add :file_path, :string, null: false
      add :action, :string, null: false
      add :recorded_at, :utc_datetime
    end

    create index(:session_files, [:session_id])
    create index(:session_files, [:file_path])

    create table(:session_summaries, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :summary, :text, null: false
      add :codebase_areas, :text
      add :files_modified, :text
      add :workpad_content, :text
      add :generated_at, :utc_datetime
    end
  end
end
