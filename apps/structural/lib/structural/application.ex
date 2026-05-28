defmodule Structural.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Structural.Index, name: Structural.Index, path: db_path()}
    ]

    opts = [strategy: :one_for_one, name: Structural.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # SQLite database path. Defaults to an in-memory index; set
  # `config :structural, :db_path, "/path/to/index.db"` for a persistent one.
  defp db_path, do: Application.get_env(:structural, :db_path, ":memory:")
end
