defmodule Esr.AdaptersTest do
  @moduledoc """
  Round-trip + reserved-name + tolerance tests for the per-thing
  adapter directory layout (yaml-layout-v2 spec § 4.3, § 5.1).

  All tests use `:home` opt to point at a tmp dir — never touches the
  user's `~/.esrd`.
  """

  use ExUnit.Case, async: true

  setup do
    home =
      System.tmp_dir!()
      |> Path.join("esr_adapters_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  describe "round-trip lifecycle" do
    test "add → list → disable → list/list_disabled → enable → remove → get :not_found",
         %{home: home} do
      opts = [home: home]

      # add
      assert :ok = Esr.Adapters.add("app_a", "feishu", %{"app_id" => "cli_x"}, opts)
      assert Esr.Adapters.exists?("app_a", opts)
      refute Esr.Adapters.disabled?("app_a", opts)

      assert {:ok, %{name: "app_a", type: "feishu", config: %{"app_id" => "cli_x"}}} =
               Esr.Adapters.get("app_a", opts)

      assert [%{name: "app_a", type: "feishu"}] = Esr.Adapters.list(opts)
      assert [] = Esr.Adapters.list_disabled(opts)

      # disable
      assert :ok = Esr.Adapters.disable("app_a", opts)
      refute Esr.Adapters.exists?("app_a", opts)
      assert Esr.Adapters.disabled?("app_a", opts)

      assert [] = Esr.Adapters.list(opts)
      assert [%{name: "app_a"}] = Esr.Adapters.list_disabled(opts)

      # enable
      assert :ok = Esr.Adapters.enable("app_a", opts)
      assert Esr.Adapters.exists?("app_a", opts)
      refute Esr.Adapters.disabled?("app_a", opts)

      # remove
      assert :ok = Esr.Adapters.remove("app_a", opts)
      assert {:error, :not_found} = Esr.Adapters.get("app_a", opts)
      refute Esr.Adapters.exists?("app_a", opts)
    end

    test "rename moves the directory + new name available; old returns :not_found", %{home: home} do
      opts = [home: home]

      assert :ok = Esr.Adapters.add("orig", "feishu", %{}, opts)
      assert :ok = Esr.Adapters.rename("orig", "renamed", opts)
      assert {:error, :not_found} = Esr.Adapters.get("orig", opts)
      assert {:ok, %{name: "renamed"}} = Esr.Adapters.get("renamed", opts)
    end
  end

  describe "name validation" do
    test "rejects reserved-prefix names", %{home: home} do
      opts = [home: home]
      assert {:error, :invalid_name} = Esr.Adapters.add("_disabled", "feishu", %{}, opts)
      assert {:error, :invalid_name} = Esr.Adapters.add("_anything", "feishu", %{}, opts)
    end

    test "rejects empty / non-ASCII / slash / leading-digit", %{home: home} do
      opts = [home: home]
      assert {:error, :invalid_name} = Esr.Adapters.add("", "feishu", %{}, opts)
      assert {:error, :invalid_name} = Esr.Adapters.add("with/slash", "feishu", %{}, opts)
      assert {:error, :invalid_name} = Esr.Adapters.add("中文名", "feishu", %{}, opts)
      assert {:error, :invalid_name} = Esr.Adapters.add("9starts", "feishu", %{}, opts)
    end

    test "rename rejects invalid new name", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("orig", "feishu", %{}, opts)
      assert {:error, :invalid_name} = Esr.Adapters.rename("orig", "_bad", opts)
    end
  end

  describe "list tolerance" do
    test "ignores any directory whose name starts with `_`", %{home: home} do
      adapters = Path.join(home, "adapters")
      File.mkdir_p!(Path.join([adapters, "_trash", "extra"]))
      File.write!(Path.join([adapters, "_trash", "config.yaml"]), "type: feishu\nconfig: {}\n")
      File.mkdir_p!(Path.join([adapters, "_disabled", "shadow"]))
      File.write!(
        Path.join([adapters, "_disabled", "shadow", "config.yaml"]),
        "type: feishu\nconfig: {}\n"
      )

      assert :ok = Esr.Adapters.add("real", "feishu", %{}, home: home)
      assert [%{name: "real"}] = Esr.Adapters.list(home: home)
    end

    test "ignores stray `<name>/config.yaml.bak` and other non-config.yaml files", %{home: home} do
      adapters = Path.join(home, "adapters")
      File.mkdir_p!(Path.join([adapters, "ghost"]))
      # No config.yaml — list still must drop it cleanly.
      File.write!(Path.join([adapters, "ghost", "config.yaml.bak"]), "type: feishu\n")

      assert [] = Esr.Adapters.list(home: home)
    end

    test "list_disabled enumerates the parking lot", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("a", "feishu", %{}, opts)
      assert :ok = Esr.Adapters.add("b", "feishu", %{}, opts)
      assert :ok = Esr.Adapters.disable("b", opts)

      assert [%{name: "a"}] = Esr.Adapters.list(opts)
      assert [%{name: "b"}] = Esr.Adapters.list_disabled(opts)
    end
  end

  describe "error paths" do
    test "remove returns :not_found for missing instance", %{home: home} do
      assert {:error, :not_found} = Esr.Adapters.remove("nope", home: home)
    end

    test "disable returns :not_found if neither active nor disabled", %{home: home} do
      assert {:error, :not_found} = Esr.Adapters.disable("nope", home: home)
    end

    test "disable returns :already_disabled when entry is on the disabled side", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("x", "feishu", %{}, opts)
      assert :ok = Esr.Adapters.disable("x", opts)
      assert {:error, :already_disabled} = Esr.Adapters.disable("x", opts)
    end

    test "enable returns :not_disabled if disabled-side entry missing", %{home: home} do
      assert {:error, :not_disabled} = Esr.Adapters.enable("nope", home: home)
    end

    test "rename src missing returns :not_found", %{home: home} do
      assert {:error, :not_found} = Esr.Adapters.rename("missing", "newname", home: home)
    end

    test "rename target collision returns :already_exists", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("a", "feishu", %{}, opts)
      assert :ok = Esr.Adapters.add("b", "feishu", %{}, opts)
      assert {:error, :already_exists} = Esr.Adapters.rename("a", "b", opts)
    end

    test "add fails when instance already exists", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("a", "feishu", %{}, opts)
      assert {:error, :already_exists} = Esr.Adapters.add("a", "feishu", %{}, opts)
    end
  end

  describe "atomicity" do
    test "add writes via tmp+rename (no partial config.yaml on a normal write)", %{home: home} do
      opts = [home: home]
      assert :ok = Esr.Adapters.add("atomic", "feishu", %{"app_id" => "cli_atom"}, opts)

      path = Path.join([home, "adapters", "atomic", "config.yaml"])
      assert File.exists?(path)

      # No leftover .tmp.* siblings should remain after a clean write.
      siblings = File.ls!(Path.dirname(path))
      assert Enum.all?(siblings, fn s -> not String.contains?(s, ".tmp.") end)
    end
  end
end
