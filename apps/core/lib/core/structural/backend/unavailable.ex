defmodule Core.Structural.Backend.Unavailable do
  @moduledoc """
  Default structural backend used until a real index is wired up.

  Every operation reports `:unavailable` so structural tools return a visible
  `:backend_unavailable` result instead of pretending to have an index. This
  lets the model discover the structural tool surface and fall back to
  grep/read_file on its own.
  """

  @behaviour Core.Structural.Backend

  @impl true
  def available?, do: false

  @impl true
  def run(_operation, _args, _context), do: :unavailable
end
