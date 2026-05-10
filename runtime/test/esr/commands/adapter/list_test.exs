defmodule Esr.Commands.Adapter.ListTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.6) — `/adapter:list` lists active +
  disabled adapter instances from the per-thing-directory layout.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Adapter.List, as: ListCmd

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "adapter_list_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "empty layout → 'no adapter instances configured'" do
    assert {:ok, %{"text" => text}} = ListCmd.execute(%{})
    assert text =~ "no adapter instances configured"
  end

  test "lists active instances + their type/app_id; redacts app_secret" do
    :ok =
      Esr.Adapters.add(
        "alpha",
        "feishu",
        %{"app_id" => "cli_alpha", "app_secret" => "shhh"}
      )

    :ok = Esr.Adapters.add("beta", "cc_mcp", %{})

    assert {:ok, %{"text" => text}} = ListCmd.execute(%{})
    assert text =~ "alpha"
    assert text =~ "type=feishu"
    assert text =~ "app_id=cli_alpha"
    assert text =~ "app_secret=***"
    refute text =~ "shhh"
    assert text =~ "beta"
    assert text =~ "type=cc_mcp"
  end

  test "lists disabled instances under a `_disabled (paused):` heading" do
    :ok = Esr.Adapters.add("paused_one", "feishu", %{"app_id" => "cli_p"})
    :ok = Esr.Adapters.disable("paused_one")

    assert {:ok, %{"text" => text}} = ListCmd.execute(%{})
    assert text =~ "_disabled (paused):"
    assert text =~ "paused_one"
    assert text =~ "type=feishu"
  end

  test "active and disabled sections both render" do
    :ok = Esr.Adapters.add("active_one", "feishu", %{"app_id" => "a1"})
    :ok = Esr.Adapters.add("paused_one", "feishu", %{"app_id" => "a2"})
    :ok = Esr.Adapters.disable("paused_one")

    assert {:ok, %{"text" => text}} = ListCmd.execute(%{})
    assert text =~ "active_one"
    assert text =~ "_disabled (paused):"
    assert text =~ "paused_one"
  end
end
