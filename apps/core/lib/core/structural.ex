defmodule Core.Structural do
  @moduledoc """
  Shared helpers for structural code-intelligence tools.

  Tools validate their own arguments, then dispatch a normalized operation
  through this module. When the configured backend is unavailable, dispatch
  returns a successful `:backend_unavailable` tool result with stable keys so
  the model can fall back to grep/read_file without seeing a tool error.
  """

  alias Core.Structural.Backend
  alias Core.Structural.Backend.Unavailable

  @fallback "structural backend unavailable; use grep and read_file instead"

  @doc """
  Returns the structural backend module from the tool context.
  """
  @spec backend(Core.Tool.context()) :: module()
  def backend(context), do: Map.get(context, :structural_backend, Unavailable)

  @doc """
  Dispatches a validated `operation` to the context backend.

  Backend `:unavailable` becomes a successful `:backend_unavailable` tool result
  carrying `details`. Backend `{:ok, payload}`/`{:error, reason}` pass through.
  """
  @spec dispatch(Backend.operation(), map(), Core.Tool.context(), map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(operation, args, context, details \\ %{}) do
    case backend(context).run(operation, args, context) do
      :unavailable -> {:ok, unavailable_result(operation, details)}
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the stable `:backend_unavailable` result for an operation.
  """
  @spec unavailable_result(Backend.operation(), map()) :: map()
  def unavailable_result(operation, details \\ %{}) do
    name = Atom.to_string(operation)

    Map.merge(
      %{
        status: :backend_unavailable,
        operation: name,
        available: false,
        summary: "#{name}: #{@fallback}",
        output: @fallback
      },
      details
    )
  end
end
