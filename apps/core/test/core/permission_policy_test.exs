defmodule Core.PermissionPolicyTest do
  use ExUnit.Case, async: true

  alias Core.PermissionPolicy

  test "trusted mode allows every safety level" do
    for safety <- [:read_only, :write, :shell, :risky] do
      assert :ok = PermissionPolicy.authorize(:trusted, "tool", safety)
    end
  end

  test "read only mode denies mutating and shell tools" do
    assert :ok = PermissionPolicy.authorize(:read_only, "read_file", :read_only)

    assert {:error, {:permission_denied, :read_only, "write_file", :write}} =
             PermissionPolicy.authorize(:read_only, "write_file", :write)

    assert {:error, {:permission_denied, :read_only, "shell", :shell}} =
             PermissionPolicy.authorize(:read_only, "shell", :shell)
  end
end
