defmodule Esr.Admin.Commands.Scope.SwitchTest do
  @moduledoc """
  DI-10 Task 20 — `Esr.Admin.Commands.Scope.Switch` flips
  `routing.yaml principals[submitter].active` to the requested branch.
  Pure file update; no shell-out; synchronous but still wrapped in the
  Dispatcher's Task since `execute/1` has a consistent signature across
  all command modules.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Scope.Switch, as: SessionSwitch

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_sessswitch_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "execute/1 happy path" do
    test "flips principals[submitter].active to the target branch", %{tmp: tmp} do
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-dev
            feature-foo:
              esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-feature-foo
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo"}
      }

      assert {:ok, %{"active_branch" => "feature-foo"}} = SessionSwitch.execute(cmd)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      assert routing["principals"]["ou_alice"]["active"] == "feature-foo"
      # Targets preserved.
      assert Map.has_key?(routing["principals"]["ou_alice"]["targets"], "dev")
      assert Map.has_key?(routing["principals"]["ou_alice"]["targets"], "feature-foo")
    end

    test "preserves other principals' entries", %{tmp: tmp} do
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-dev
            feature-foo:
              esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-feature-foo
        ou_bob:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_bob-dev
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo"}
      }

      assert {:ok, _} = SessionSwitch.execute(cmd)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      assert routing["principals"]["ou_alice"]["active"] == "feature-foo"
      assert routing["principals"]["ou_bob"]["active"] == "dev"
    end
  end

  describe "execute/1 error paths" do
    test "submitter not in routing.yaml → no_such_target", %{tmp: tmp} do
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(routing_path, """
      principals:
        ou_bob:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_bob-dev
      """)

      cmd = %{
        "submitted_by" => "ou_ghost",
        "args" => %{"branch" => "dev"}
      }

      assert {:error, %{"type" => "no_such_target"}} = SessionSwitch.execute(cmd)
    end

    test "branch not in submitter's targets → no_such_target", %{tmp: tmp} do
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-dev
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "never-created"}
      }

      assert {:error, %{"type" => "no_such_target"}} = SessionSwitch.execute(cmd)
    end

    test "missing routing.yaml entirely → no_such_target" do
      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "dev"}
      }

      assert {:error, %{"type" => "no_such_target"}} = SessionSwitch.execute(cmd)
    end

    test "missing args.branch → invalid_args" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      assert {:error, %{"type" => "invalid_args"}} = SessionSwitch.execute(cmd)
    end
  end
end
