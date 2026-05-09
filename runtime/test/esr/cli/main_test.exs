defmodule Esr.Cli.MainTest do
  @moduledoc """
  Unit tests for the `Esr.Cli.Main` escript module — focused on
  `resolve_submitter/0` (spec 2026-05-09 § 3.5 chain).

  Three cases (spec § 7 unit test #4):
    1. operator.json present + valid → returns its principal_id
    2. operator.json absent → returns the bootstrap sentinel
    3. operator.json malformed → returns the bootstrap sentinel +
       warning printed to stderr

  ESR_OPERATOR_PRINCIPAL_ID is NOT consulted (spec D3 hard cutover).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Esr.Cli.Main

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("esr_cli_main_test_#{:rand.uniform(999_999)}")
    instance_dir = Path.join(tmp_dir, "default")
    File.mkdir_p!(instance_dir)

    prev_home = System.get_env("ESRD_HOME")
    prev_instance = System.get_env("ESR_INSTANCE")
    prev_operator_env = System.get_env("ESR_OPERATOR_PRINCIPAL_ID")

    System.put_env("ESRD_HOME", tmp_dir)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_env("ESRD_HOME", prev_home)
      restore_env("ESR_INSTANCE", prev_instance)
      restore_env("ESR_OPERATOR_PRINCIPAL_ID", prev_operator_env)
    end)

    {:ok, tmp_dir: tmp_dir, instance_dir: instance_dir}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "resolve_submitter/0 (spec § 3.5 chain)" do
    test "operator.json present + valid → returns its principal_id", %{instance_dir: dir} do
      uuid = "11111111-2222-4333-8444-555555555555"

      File.write!(
        Path.join(dir, "operator.json"),
        Jason.encode!(%{
          "schema_version" => 1,
          "principal_id" => uuid,
          "name" => "linyilun",
          "set_at" => "2026-05-09T00:00:00Z",
          "set_by" => "user_add"
        })
      )

      # No stderr expected on the happy path.
      out =
        capture_io(:stderr, fn ->
          assert ^uuid = Main.resolve_submitter()
        end)

      assert out == ""
    end

    test "operator.json absent → returns sentinel + stderr hint" do
      out =
        capture_io(:stderr, fn ->
          assert "system:bootstrap" = Main.resolve_submitter()
        end)

      assert out =~ "no operator configured"
      assert out =~ "system:bootstrap" or out =~ "bootstrap sentinel"
      # Hint mentions the recovery command.
      assert out =~ "user_add"
    end

    test "operator.json malformed → returns sentinel + warning", %{instance_dir: dir} do
      File.write!(Path.join(dir, "operator.json"), "{not valid json")

      out =
        capture_io(:stderr, fn ->
          assert "system:bootstrap" = Main.resolve_submitter()
        end)

      assert out =~ "malformed"
    end

    test "operator.json missing principal_id field → returns sentinel", %{instance_dir: dir} do
      File.write!(
        Path.join(dir, "operator.json"),
        Jason.encode!(%{"name" => "linyilun"})
      )

      out =
        capture_io(:stderr, fn ->
          assert "system:bootstrap" = Main.resolve_submitter()
        end)

      assert out =~ "malformed"
    end

    test "operator.json with empty principal_id → returns sentinel", %{instance_dir: dir} do
      File.write!(
        Path.join(dir, "operator.json"),
        Jason.encode!(%{"principal_id" => "", "name" => "x"})
      )

      out =
        capture_io(:stderr, fn ->
          assert "system:bootstrap" = Main.resolve_submitter()
        end)

      assert out =~ "malformed"
    end

    test "ESR_OPERATOR_PRINCIPAL_ID env var is IGNORED (spec D3)" do
      # Operator.json absent → must fall to sentinel even if env var set.
      System.put_env("ESR_OPERATOR_PRINCIPAL_ID", "ou_legacy_env")

      out =
        capture_io(:stderr, fn ->
          assert "system:bootstrap" = Main.resolve_submitter()
        end)

      # Sentinel hint, not the env var value.
      assert out =~ "system:bootstrap" or out =~ "bootstrap sentinel"
    end
  end
end
