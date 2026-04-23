defmodule Esr.TestSupport.AppSingletons do
  @moduledoc """
  Shared ExUnit setup helper: assert the Esr.Application-booted
  singletons are up before the test body runs. Intended as
  `setup :assert_app_singletons` in integration tests that depend
  on the app-level `SessionRegistry` / `AdminSessionProcess` /
  `SessionsSupervisor` / `Session.Registry`.

  Mirror of the `Esr.TestSupport.TmuxIsolation` pattern. When a test
  needs to load the capabilities Grants registry specifically, pass
  `setup {Esr.TestSupport.AppSingletons, :assert_with_grants}` to
  also verify the Grants process.
  """

  import ExUnit.Assertions, only: [assert: 2]

  @spec assert_app_singletons(map()) :: :ok
  def assert_app_singletons(_ctx) do
    for mod <- [
          Esr.SessionRegistry,
          Esr.AdminSessionProcess,
          Esr.SessionsSupervisor,
          Esr.Session.Registry
        ] do
      assert is_pid(Process.whereis(mod)),
             "Esr.Application singleton #{inspect(mod)} not running"
    end

    :ok
  end

  @spec assert_with_grants(map()) :: :ok
  def assert_with_grants(ctx) do
    :ok = assert_app_singletons(ctx)

    assert is_pid(Process.whereis(Esr.Capabilities.Grants)),
           "Esr.Capabilities.Grants not running"

    :ok
  end
end
