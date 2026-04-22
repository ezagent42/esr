defmodule Esr.Admin.Commands.Session.EndTest do
  @moduledoc """
  DI-10 Task 21 — `Esr.Admin.Commands.Session.End` tears down an
  ephemeral esrd + worktree via `scripts/esr-branch.sh end <branch>
  --force`, then removes the branch entry from `branches.yaml` and
  drops `principals[*].targets[<branch>]` across all principals in
  `routing.yaml`. If the submitter's `active` pointed at the ended
  branch, unset (or fall back to the first remaining target name).

  ## Force-only (DI-10)

  DI-10 always passes `--force` to the shell script. MCP
  `session.signal_cleanup` coordination + the 30-s interactive
  timeout are added in DI-11 Task 25.

  ## System.cmd mocking

  Mirrors the `:spawn_fn` injection pattern in
  `Esr.Admin.Commands.Session.New` — tests pass a 1-arity stub that
  receives `{argv}` and returns `{stdout, exit_status}`.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Session.End, as: SessionEnd

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_sessend_#{unique}")
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

  describe "execute/2 happy path" do
    test "removes branch from branches.yaml + drops target across all principals", %{tmp: tmp} do
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(branches_path, """
      branches:
        dev:
          esrd_home: /Users/alice/.esrd-dev
          port: 54321
          status: running
        feature-foo:
          esrd_home: /tmp/esrd-feature-foo
          port: 54399
          status: running
      """)

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
          active: feature-foo
          targets:
            feature-foo:
              esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_bob-feature-foo
      """)

      parent = self()

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {args} ->
        send(parent, {:spawned, args})
        {~s({"ok":true,"branch":"feature-foo"}\n), 0}
      end

      assert {:ok, %{"branch" => "feature-foo"}} =
               SessionEnd.execute(cmd, spawn_fn: stub)

      # Force is always passed in DI-10.
      assert_received {:spawned, args}
      assert "end" in args
      assert "feature-foo" in args
      assert "--force" in args

      # branches.yaml: feature-foo removed; dev preserved.
      {:ok, branches} = YamlElixir.read_from_file(branches_path)
      refute Map.has_key?(branches["branches"], "feature-foo")
      assert Map.has_key?(branches["branches"], "dev")

      # routing.yaml: targets[feature-foo] dropped from BOTH principals.
      {:ok, routing} = YamlElixir.read_from_file(routing_path)

      alice_targets = routing["principals"]["ou_alice"]["targets"]
      refute Map.has_key?(alice_targets, "feature-foo")
      assert Map.has_key?(alice_targets, "dev")

      bob_targets = routing["principals"]["ou_bob"]["targets"] || %{}
      refute Map.has_key?(bob_targets, "feature-foo")
    end

    test "unsets active when ended branch was submitter's active (no remaining targets)", %{
      tmp: tmp
    } do
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(branches_path, """
      branches:
        feature-foo:
          esrd_home: /tmp/esrd-feature-foo
          port: 54399
          status: running
      """)

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: feature-foo
          targets:
            feature-foo:
              esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_alice-feature-foo
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {_args} -> {~s({"ok":true,"branch":"feature-foo"}\n), 0} end

      assert {:ok, _} = SessionEnd.execute(cmd, spawn_fn: stub)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      # Active unset — no remaining targets to fall back to.
      assert routing["principals"]["ou_alice"]["active"] in [nil, ""]
    end

    test "falls back active to first remaining target name when ended branch was active", %{
      tmp: tmp
    } do
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(branches_path, """
      branches:
        dev:
          esrd_home: /Users/alice/.esrd-dev
          port: 54321
          status: running
        feature-foo:
          esrd_home: /tmp/esrd-feature-foo
          port: 54399
          status: running
      """)

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: feature-foo
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
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {_args} -> {~s({"ok":true,"branch":"feature-foo"}\n), 0} end

      assert {:ok, _} = SessionEnd.execute(cmd, spawn_fn: stub)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      # Active fell back to "dev" (the only remaining target).
      assert routing["principals"]["ou_alice"]["active"] == "dev"
    end

    test "leaves active unchanged if ended branch was NOT the submitter's active", %{tmp: tmp} do
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(branches_path, """
      branches:
        dev:
          esrd_home: /Users/alice/.esrd-dev
          port: 54321
          status: running
        feature-foo:
          esrd_home: /tmp/esrd-feature-foo
          port: 54399
          status: running
      """)

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
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {_args} -> {~s({"ok":true,"branch":"feature-foo"}\n), 0} end

      assert {:ok, _} = SessionEnd.execute(cmd, spawn_fn: stub)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      assert routing["principals"]["ou_alice"]["active"] == "dev"
    end
  end

  describe "execute/2 error paths" do
    test "branch missing from branches.yaml → no_such_branch (no shell call)", %{tmp: tmp} do
      branches_path = Path.join([tmp, "default", "branches.yaml"])

      File.write!(branches_path, """
      branches:
        dev:
          esrd_home: /Users/alice/.esrd-dev
          port: 54321
          status: running
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "never-created"}
      }

      stub = fn {_args} -> flunk("spawn should not be called when branch is absent") end

      assert {:error, %{"type" => "no_such_branch"}} =
               SessionEnd.execute(cmd, spawn_fn: stub)
    end

    test "missing branches.yaml entirely → no_such_branch" do
      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {_args} -> flunk("spawn should not be called") end

      assert {:error, %{"type" => "no_such_branch"}} =
               SessionEnd.execute(cmd, spawn_fn: stub)
    end

    test "esr-branch.sh end fails → pass through error", %{tmp: tmp} do
      branches_path = Path.join([tmp, "default", "branches.yaml"])

      File.write!(branches_path, """
      branches:
        feature-foo:
          esrd_home: /tmp/esrd-feature-foo
          port: 54399
          status: running
      """)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo", "force" => true}
      }

      stub = fn {_args} ->
        {~s({"ok":false,"error":"git worktree remove failed"}\n), 1}
      end

      assert {:error, %{"type" => "branch_end_failed", "details" => "git worktree remove failed"}} =
               SessionEnd.execute(cmd, spawn_fn: stub)
    end

    test "missing args.branch → invalid_args" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      stub = fn {_args} -> flunk("spawn should not be called") end

      assert {:error, %{"type" => "invalid_args"}} =
               SessionEnd.execute(cmd, spawn_fn: stub)
    end
  end
end
