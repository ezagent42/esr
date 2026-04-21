defmodule Esr.Admin.PermissionsTest do
  use ExUnit.Case, async: false

  alias Esr.Permissions.Bootstrap
  alias Esr.Permissions.Registry

  setup do
    # Registry is started by Esr.Application. Other async: false suites
    # call Registry.reset/0 in their own setups, so re-run Bootstrap here
    # to guarantee Admin's permissions are present regardless of order.
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end

    Registry.reset()
    :ok = Bootstrap.bootstrap()
    :ok
  end

  test "admin permissions registered at boot" do
    for perm <- Esr.Admin.permissions() do
      assert Registry.declared?(perm),
        "expected #{perm} to be declared"
    end
  end
end
