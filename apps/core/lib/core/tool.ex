defmodule Core.Tool do
  @moduledoc """
  Behaviour implemented by tools exposed to the model loop.
  """

  @type name :: String.t()
  @type safety :: :read_only | :write | :shell | :risky
  @type args :: map()
  @type context :: %{
          required(:workspace_root) => Path.t(),
          optional(:permission_mode) => Core.PermissionPolicy.mode(),
          optional(:file_lock_manager) => GenServer.server()
        }
  @type result :: %{
          optional(:output) => String.t(),
          optional(:summary) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Returns the model-facing tool name.
  """
  @callback name() :: name()

  @doc """
  Returns a concise model-facing description.
  """
  @callback description() :: String.t()

  @doc """
  Returns a JSON-schema-like argument schema.
  """
  @callback schema() :: map()

  @doc """
  Classifies tool risk for scheduling and permission policy.
  """
  @callback safety() :: safety()

  @doc """
  Runs the tool with validated context.
  """
  @callback run(args(), context()) :: {:ok, result()} | {:error, term()}
end
