defmodule Esr.Commands.Scope.ListTest do
  @moduledoc """
  DI-10 Task 20 — `Esr.Commands.Scope.List` reads routing.yaml
  + branches.yaml, scopes the output to the submitter's principal
  entry, and returns a summary map:

      %{"active" => active_branch, "targets" => [...], "branches" => [...]}

    * `active` — the submitter's current active branch (or nil if none)
    * `targets` — list of branch names from the submitter's routing
      targets (submitter-scoped)
    * `branches` — list of branch names from branches.yaml (unscoped —
      this is the global branch registry; the router may fan out to
      any of these)
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Scope.List, as: SessionList

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_sesslist_#{unique}")
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
    test "returns submitter-scoped summary map", %{tmp: tmp} do
      File.write!(Path.join([tmp, "default", "routing.yaml"]), """
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
        ou_bob:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_bob-dev
      """)

      File.write!(Path.join([tmp, "default", "branches.yaml"]), """
      branches:
        dev:
          port: 54321
          status: running
          kind: permanent
        feature-foo:
          port: 54399
          status: running
          kind: ephemeral
      """)

      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      assert {:ok, %{"active" => "feature-foo", "targets" => targets, "branches" => branches}} =
               SessionList.execute(cmd)

      assert Enum.sort(targets) == ["dev", "feature-foo"]
      assert Enum.sort(branches) == ["dev", "feature-foo"]
    end

    test "submitter with no principal entry → empty targets, nil active", %{tmp: tmp} do
      File.write!(Path.join([tmp, "default", "routing.yaml"]), """
      principals:
        ou_bob:
          active: dev
          targets:
            dev:
              esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
              cc_session_id: ou_bob-dev
      """)

      File.write!(Path.join([tmp, "default", "branches.yaml"]), """
      branches:
        dev:
          port: 54321
          status: running
          kind: permanent
      """)

      cmd = %{"submitted_by" => "ou_ghost", "args" => %{}}

      assert {:ok, %{"active" => nil, "targets" => [], "branches" => ["dev"]}} =
               SessionList.execute(cmd)
    end

    test "both files missing → empty lists, nil active" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      assert {:ok, %{"active" => nil, "targets" => [], "branches" => []}} =
               SessionList.execute(cmd)
    end

    test "principal with no targets → empty list, active preserved", %{tmp: tmp} do
      File.write!(Path.join([tmp, "default", "routing.yaml"]), """
      principals:
        ou_alice:
          active: dev
      """)

      cmd = %{"submitted_by" => "ou_alice", "args" => %{}}

      assert {:ok, %{"active" => "dev", "targets" => [], "branches" => []}} =
               SessionList.execute(cmd)
    end
  end

  describe "execute/1 error paths" do
    test "missing submitted_by → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = SessionList.execute(%{"args" => %{}})
    end
  end

  describe "execute/1 PR-21j workspace-scoped path" do
    test "returns sessions filtered by (env, username, workspace) URI tuple" do
      assert is_pid(Process.whereis(Esr.Resource.ChatScope.Registry))
      env = "test-list-#{System.unique_integer([:positive])}"

      sid_a = "sid-listA-#{System.unique_integer([:positive])}"
      sid_b = "sid-listB-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Resource.ChatScope.Registry.claim_uri(sid_a, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "alpha",
          worktree_branch: "alpha-br"
        })

      :ok =
        Esr.Resource.ChatScope.Registry.claim_uri(sid_b, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "beta",
          worktree_branch: "beta-br"
        })

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"workspace" => "esr-dev", "username" => "linyilun", "env" => env}
      }

      assert {:ok,
              %{
                "workspace" => "esr-dev",
                "username" => "linyilun",
                "env" => ^env,
                "sessions" => sessions
              }} = SessionList.execute(cmd)

      names = sessions |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["alpha", "beta"]

      # Cleanup
      :ok = Esr.Resource.ChatScope.Registry.unregister_session(sid_a)
      :ok = Esr.Resource.ChatScope.Registry.unregister_session(sid_b)
    end

    test "workspace= without username= → invalid_args" do
      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"workspace" => "esr-dev"}
      }

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SessionList.execute(cmd)

      assert msg =~ "username"
    end

    test "no matching sessions → empty list" do
      env = "empty-#{System.unique_integer([:positive])}"

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"workspace" => "ghost-ws", "username" => "linyilun", "env" => env}
      }

      assert {:ok, %{"sessions" => []}} = SessionList.execute(cmd)
    end
  end
end
