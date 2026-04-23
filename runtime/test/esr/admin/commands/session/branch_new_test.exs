defmodule Esr.Admin.Commands.Session.BranchNewTest do
  @moduledoc """
  DI-10 Task 20 — `Esr.Admin.Commands.Session.BranchNew` shells out to
  `scripts/esr-branch.sh new <branch>` via `System.cmd/3` (already
  running inside a Task spawned by the Dispatcher, so blocking is OK),
  parses the single-line JSON stdout, appends the new entry to
  `branches.yaml`, and updates `routing.yaml` so the submitter has a
  `targets[branch]` + `active = branch`.

  PR-3 P3-8 renamed this module from `Session.New` → `Session.BranchNew`
  (dispatcher kind `session_branch_new`); the agent-session command now
  owns the `Session.New` / `session_new` names.

  ## System.cmd mocking

  `execute/2` accepts an `opts` keyword where `:spawn_fn` is a 1-arity
  function receiving `{args :: [String.t()]}` and returning
  `{output :: String.t(), exit_status :: integer()}` — the same shape
  `System.cmd/3` returns. Tests pass a stub; production calls
  `execute/1` which uses the real `System.cmd/3`. Same split pattern as
  `Esr.Admin.Commands.RegisterAdapter.execute/2`.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Session.BranchNew, as: SessionBranchNew

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_sessnew_#{unique}")
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
    test "spawns script, writes branches.yaml + routing.yaml, returns ok", %{tmp: tmp} do
      parent = self()

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature/foo"}
      }

      stub = fn {args} ->
        send(parent, {:spawned, args})

        json = ~s({"ok":true,"branch":"feature-foo","branch_raw":"feature/foo",) <>
                 ~s("port":54399,"worktree_path":"/tmp/wt/feature-foo",) <>
                 ~s("esrd_home":"/tmp/esrd-feature-foo"})

        {json <> "\n", 0}
      end

      assert {:ok, %{"branch" => "feature-foo", "port" => 54399, "worktree_path" => "/tmp/wt/feature-foo"}} =
               SessionBranchNew.execute(cmd, spawn_fn: stub)

      # spawn_fn saw `["new", "feature/foo", ...]`
      assert_received {:spawned, args}
      assert ["new", "feature/foo" | _] = args

      # branches.yaml now has the entry.
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      assert File.exists?(branches_path)
      {:ok, branches} = YamlElixir.read_from_file(branches_path)

      assert %{
               "branches" => %{
                 "feature-foo" => %{
                   "esrd_home" => "/tmp/esrd-feature-foo",
                   "worktree_path" => "/tmp/wt/feature-foo",
                   "port" => 54399,
                   "status" => "running"
                 }
               }
             } = branches

      # routing.yaml now has ou_alice.active = feature-foo and the
      # target entry with canonical esrd_url format.
      routing_path = Path.join([tmp, "default", "routing.yaml"])
      assert File.exists?(routing_path)
      {:ok, routing} = YamlElixir.read_from_file(routing_path)

      assert routing["principals"]["ou_alice"]["active"] == "feature-foo"
      target = routing["principals"]["ou_alice"]["targets"]["feature-foo"]
      assert target["esrd_url"] == "ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0"
      assert target["cc_session_id"] == "ou_alice-feature-foo"
    end

    test "merges into existing branches.yaml without clobbering prior entries", %{tmp: tmp} do
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
        "args" => %{"branch" => "feature/bar"}
      }

      stub = fn {_args} ->
        json = ~s({"ok":true,"branch":"feature-bar","branch_raw":"feature/bar",) <>
                 ~s("port":54400,"worktree_path":"/tmp/wt/feature-bar",) <>
                 ~s("esrd_home":"/tmp/esrd-feature-bar"})

        {json <> "\n", 0}
      end

      assert {:ok, %{"branch" => "feature-bar"}} = SessionBranchNew.execute(cmd, spawn_fn: stub)

      {:ok, branches} = YamlElixir.read_from_file(branches_path)

      assert Map.has_key?(branches["branches"], "dev")
      assert Map.has_key?(branches["branches"], "feature-bar")
      assert branches["branches"]["dev"]["port"] == 54321
      assert branches["branches"]["feature-bar"]["port"] == 54400
    end

    test "merges into existing routing.yaml — preserves other principals", %{tmp: tmp} do
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
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature/baz"}
      }

      stub = fn {_args} ->
        json = ~s({"ok":true,"branch":"feature-baz","branch_raw":"feature/baz",) <>
                 ~s("port":54500,"worktree_path":"/tmp/wt/feature-baz",) <>
                 ~s("esrd_home":"/tmp/esrd-feature-baz"})

        {json <> "\n", 0}
      end

      assert {:ok, _} = SessionBranchNew.execute(cmd, spawn_fn: stub)

      {:ok, routing} = YamlElixir.read_from_file(routing_path)

      assert Map.has_key?(routing["principals"], "ou_bob")
      assert Map.has_key?(routing["principals"], "ou_alice")
      assert routing["principals"]["ou_bob"]["active"] == "dev"
      assert routing["principals"]["ou_alice"]["active"] == "feature-baz"
    end
  end

  describe "execute/2 error paths" do
    test "script exits non-zero with ok:false → branch_spawn_failed" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{"branch" => "bad/branch"}}

      stub = fn {_args} ->
        {~s({"ok":false,"error":"git worktree add failed"}\n), 1}
      end

      assert {:error, %{"type" => "branch_spawn_failed", "details" => "git worktree add failed"}} =
               SessionBranchNew.execute(cmd, spawn_fn: stub)
    end

    test "invalid args (missing branch) → invalid_args" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      stub = fn {_args} -> flunk("spawn should not be called") end

      assert {:error, %{"type" => "invalid_args"}} =
               SessionBranchNew.execute(cmd, spawn_fn: stub)
    end

    test "malformed JSON stdout → branch_spawn_failed" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{"branch" => "x"}}

      stub = fn {_args} -> {"not json\n", 0} end

      assert {:error, %{"type" => "branch_spawn_failed"}} =
               SessionBranchNew.execute(cmd, spawn_fn: stub)
    end
  end
end
