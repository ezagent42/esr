defmodule Esr.Commands.User.SwitchTest do
  @moduledoc """
  Tests for `Esr.Commands.User.Switch` — change the active CLI operator.

  Spec: docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md § 3.6.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.User.Add
  alias Esr.Commands.User.Switch

  setup do
    # PR-1: User.NameIndex is gone; lookups go through Esr.Uri.Store.
    case Process.whereis(Esr.Uri.Store) do
      nil -> start_supervised!(Esr.Uri.Store)
      _ -> :ok
    end

    Esr.Uri.Store.delete_all_by_kind(:user)

    # Isolated ESRD_HOME so operator.json writes don't escape the test.
    tmp_dir = System.tmp_dir!() |> Path.join("esr_switch_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)
    System.put_env("ESRD_HOME", tmp_dir)
    System.put_env("ESR_INSTANCE", "default")
    File.mkdir_p!(Path.join(tmp_dir, "default"))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "User.Switch — happy path" do
    test "switching to an existing user writes operator.json" do
      # Seed a user via Add so NameIndex is populated for the lookup.
      name = "linyilun-#{System.unique_integer([:positive])}"
      {:ok, %{"id" => uuid}} = Add.execute(%{"args" => %{"name" => name}})

      assert {:ok,
              %{
                "action" => "switched",
                "username" => ^name,
                "target_principal_id" => ^uuid
              }} = Switch.execute(%{"args" => %{"name" => name}})

      operator_path = Esr.Paths.operator_json()
      assert File.exists?(operator_path)

      {:ok, op_doc} = Jason.decode(File.read!(operator_path))
      assert op_doc["caller_principal_id"] == uuid
      assert op_doc["name"] == name
      assert op_doc["set_by"] == "user_switch"
      assert op_doc["schema_version"] == 1
      assert is_binary(op_doc["set_at"])
    end

    test "switching overwrites a prior operator.json" do
      # Two users; switch from first to second.
      n1 = "alpha-#{System.unique_integer([:positive])}"
      n2 = "beta-#{System.unique_integer([:positive])}"
      {:ok, %{"id" => u1}} = Add.execute(%{"args" => %{"name" => n1}})
      {:ok, %{"id" => u2}} = Add.execute(%{"args" => %{"name" => n2}})

      {:ok, _} = Switch.execute(%{"args" => %{"name" => n1}})
      {:ok, op1} = Jason.decode(File.read!(Esr.Paths.operator_json()))
      assert op1["caller_principal_id"] == u1

      {:ok, _} = Switch.execute(%{"args" => %{"name" => n2}})
      {:ok, op2} = Jason.decode(File.read!(Esr.Paths.operator_json()))
      assert op2["caller_principal_id"] == u2
      assert op2["name"] == n2
    end
  end

  describe "User.Switch — error paths" do
    test "unknown user returns unknown_user without writing operator.json" do
      assert {:error, %{"type" => "unknown_user", "message" => msg}} =
               Switch.execute(%{"args" => %{"name" => "ghost-user"}})

      assert msg =~ "ghost-user"

      refute File.exists?(Esr.Paths.operator_json())
    end

    test "missing args.name returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = Switch.execute(%{"args" => %{}})
    end

    test "empty name returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               Switch.execute(%{"args" => %{"name" => ""}})
    end

    test "completely malformed command returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = Switch.execute(%{})
    end
  end
end
