defmodule Esr.Resource.Media.LocalAddressTest do
  use ExUnit.Case
  alias Esr.Resource.Media.LocalAddress

  test "host_port/0 returns a `host:port` shaped string" do
    hp = LocalAddress.host_port()
    assert is_binary(hp)
    assert hp =~ ~r/^[a-zA-Z0-9.\-]+:[0-9]+$/
  end

  test "env/0 returns ESR_INSTANCE env var or `default`" do
    saved = System.get_env("ESR_INSTANCE")

    System.delete_env("ESR_INSTANCE")
    assert LocalAddress.env() == "default"

    System.put_env("ESR_INSTANCE", "test_env")
    assert LocalAddress.env() == "test_env"

    if saved, do: System.put_env("ESR_INSTANCE", saved), else: System.delete_env("ESR_INSTANCE")
  end
end
