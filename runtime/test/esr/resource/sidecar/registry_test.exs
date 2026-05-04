defmodule Esr.Resource.Sidecar.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Sidecar.Registry

  setup do
    # Registry is started by the Application supervisor. Use a per-test
    # unique adapter_type so concurrent tests don't see each other's writes.
    type = "test_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Registry.unregister(type) end)
    %{type: type}
  end

  test "lookup misses return :error", %{type: type} do
    assert :error == Registry.lookup(type)
  end

  test "register/lookup roundtrip", %{type: type} do
    assert :ok == Registry.register(type, "my_runner")
    assert {:ok, "my_runner"} == Registry.lookup(type)
  end

  test "register is idempotent and last-write-wins", %{type: type} do
    :ok = Registry.register(type, "first")
    :ok = Registry.register(type, "second")
    assert {:ok, "second"} == Registry.lookup(type)
  end

  test "unregister removes mapping", %{type: type} do
    :ok = Registry.register(type, "x")
    :ok = Registry.unregister(type)
    assert :error == Registry.lookup(type)
  end

  test "unregister of unknown type is a no-op" do
    assert :ok == Registry.unregister("never_registered_#{System.unique_integer([:positive])}")
  end

  test "Application boot registers feishu and cc_mcp fallbacks" do
    # Phase-1 fallbacks live in Esr.Application.start/2; verify they survive
    # boot so existing WorkerSupervisor.sidecar_module/1 callers still resolve.
    assert {:ok, "feishu_adapter_runner"} == Registry.lookup("feishu")
    assert {:ok, "cc_adapter_runner"} == Registry.lookup("cc_mcp")
  end

  test "WorkerSupervisor.sidecar_module/1 falls back to generic_adapter_runner" do
    # Validates the registry-miss path through the public API.
    unknown = "definitely_not_a_real_adapter_#{System.unique_integer([:positive])}"
    assert "generic_adapter_runner" == Esr.WorkerSupervisor.sidecar_module(unknown)
  end

  test "WorkerSupervisor.sidecar_module/1 reads from registry", %{type: type} do
    :ok = Registry.register(type, "custom_runner")
    assert "custom_runner" == Esr.WorkerSupervisor.sidecar_module(type)
  end
end
