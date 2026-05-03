defmodule Esr.TestSupport.AppSingletons do
  @moduledoc """
  Shared ExUnit setup helper: assert the Esr.Application-booted
  singletons are up before the test body runs. Intended as
  `setup :assert_app_singletons` in integration tests that depend
  on the app-level `SessionRegistry` / `Scope.Admin.Process` /
  `Scope.Supervisor` / `Session.Registry`.

  When a test needs to load the capabilities Grants registry
  specifically, pass `setup {Esr.TestSupport.AppSingletons,
  :assert_with_grants}` to also verify the Grants process.
  """

  import ExUnit.Assertions, only: [assert: 2]

  @spec assert_app_singletons(map()) :: :ok
  def assert_app_singletons(_ctx) do
    for mod <- [
          Esr.SessionRegistry,
          Esr.Scope.Admin.Process,
          Esr.Scope.Supervisor,
          Esr.Scope.Registry
        ] do
      assert is_pid(Process.whereis(mod)),
             "Esr.Application singleton #{inspect(mod)} not running"
    end

    :ok
  end

  @spec assert_with_grants(map()) :: :ok
  def assert_with_grants(ctx) do
    :ok = assert_app_singletons(ctx)

    assert is_pid(Process.whereis(Esr.Resource.Capability.Grants)),
           "Esr.Resource.Capability.Grants not running"

    :ok
  end
end
