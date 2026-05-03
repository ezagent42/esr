defmodule Esr.Admin.Commands.CapTest do
  @moduledoc """
  DI-10 Task 23 — `Esr.Admin.Commands.Cap.Grant` + `Cap.Revoke` write
  `capabilities.yaml` via `Esr.Yaml.Writer`. The existing
  `Esr.Resource.Capability.Watcher` fs_event subscription observes the change
  and atomically reloads the `Esr.Resource.Capability.Grants` ETS snapshot —
  the commands themselves DO NOT poke Grants directly.

  ## Why this test bypasses the fs_event → Grants reload edge

  macOS FSEvents coalescing is flaky on fast-fire test writes (same
  reason `notify_test.exs` casts directly instead of dropping pending
  YAML). The Watcher → FileLoader edge is already covered by the
  dedicated watcher test elsewhere. Here we:

    * assert the on-disk YAML content after Grant / Revoke (the
      command's actual responsibility), and
    * drive one end-to-end "persistence survives reload" case by
      invoking `Esr.Resource.Capability.FileLoader.load/1` directly against
      the written file — the same call the Watcher makes.

  This keeps the test deterministic while still proving the contract:
  a write that Yaml.Writer emits is parseable by FileLoader and lands
  in the Grants ETS under the expected principal.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Cap.Grant
  alias Esr.Admin.Commands.Cap.Revoke
  alias Esr.Resource.Capability.FileLoader
  alias Esr.Resource.Capability.Grants

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_cap_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Grants is a shared singleton — snapshot + restore so a Grant
    # that lands in ETS (via explicit FileLoader.load call) doesn't
    # leak into sibling test files.
    prior_grants = snapshot_grants()

    on_exit(fn ->
      Grants.load_snapshot(prior_grants)

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    path = Path.join([tmp, "default", "capabilities.yaml"])
    {:ok, tmp: tmp, path: path}
  end

  describe "Grant.execute/1" do
    test "creates a new principal entry when the id is absent", %{path: path} do
      refute File.exists?(path)

      assert {:ok,
              %{
                "principal_id" => "ou_new_user",
                "permission" => "workspace:proj-a/session.create",
                "action" => "granted"
              }} =
               Grant.execute(%{
                 "args" => %{
                   "principal_id" => "ou_new_user",
                   "permission" => "workspace:proj-a/session.create"
                 }
               })

      {:ok, doc} = YamlElixir.read_from_file(path)

      assert %{
               "principals" => [
                 %{
                   "id" => "ou_new_user",
                   "kind" => "feishu_user",
                   "capabilities" => ["workspace:proj-a/session.create"]
                 }
               ]
             } = doc
    end

    test "appends permission to an existing principal without duplicating other entries",
         %{path: path} do
      File.write!(path, """
      principals:
        - id: ou_alice
          kind: feishu_user
          capabilities:
            - "workspace:proj-a/session.create"
        - id: ou_bob
          kind: feishu_user
          capabilities:
            - "workspace:proj-b/session.end"
      """)

      assert {:ok, %{"action" => "granted"}} =
               Grant.execute(%{
                 "args" => %{
                   "principal_id" => "ou_alice",
                   "permission" => "workspace:proj-a/session.end"
                 }
               })

      {:ok, doc} = YamlElixir.read_from_file(path)
      principals = doc["principals"]
      assert length(principals) == 2

      alice = Enum.find(principals, &(&1["id"] == "ou_alice"))
      bob = Enum.find(principals, &(&1["id"] == "ou_bob"))

      assert "workspace:proj-a/session.create" in alice["capabilities"]
      assert "workspace:proj-a/session.end" in alice["capabilities"]
      assert bob["capabilities"] == ["workspace:proj-b/session.end"]
    end

    test "is idempotent — granting an already-held permission is a no-op on the list",
         %{path: path} do
      File.write!(path, """
      principals:
        - id: ou_alice
          kind: feishu_user
          capabilities:
            - "workspace:proj-a/session.create"
      """)

      assert {:ok, %{"action" => "granted"}} =
               Grant.execute(%{
                 "args" => %{
                   "principal_id" => "ou_alice",
                   "permission" => "workspace:proj-a/session.create"
                 }
               })

      {:ok, doc} = YamlElixir.read_from_file(path)
      alice = Enum.find(doc["principals"], &(&1["id"] == "ou_alice"))
      # Permission appears exactly once (not doubled by idempotent re-grant).
      assert alice["capabilities"] == ["workspace:proj-a/session.create"]
    end

    test "persists through an explicit FileLoader reload (Watcher contract)",
         %{path: path} do
      assert {:ok, _} =
               Grant.execute(%{
                 "args" => %{
                   "principal_id" => "ou_loader_test",
                   "permission" => "workspace:proj-loader/session.create"
                 }
               })

      # Simulate the fs_event → FileLoader.load pipeline. This is the
      # exact call `Esr.Resource.Capability.Watcher` makes on file change; if
      # Yaml.Writer emitted something the parser can't validate, this
      # would return {:error, _} and keep the old snapshot.
      assert :ok = FileLoader.load(path)

      assert Grants.has?("ou_loader_test", "workspace:proj-loader/session.create")
    end

    test "invalid args — missing permission returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               Grant.execute(%{"args" => %{"principal_id" => "ou_x"}})
    end

    test "invalid args — empty strings rejected" do
      assert {:error, %{"type" => "invalid_args"}} =
               Grant.execute(%{"args" => %{"principal_id" => "", "permission" => "x"}})
    end
  end

  describe "Revoke.execute/1" do
    test "removes an existing grant from the principal's capabilities list",
         %{path: path} do
      File.write!(path, """
      principals:
        - id: ou_alice
          kind: feishu_user
          capabilities:
            - "workspace:proj-a/session.create"
            - "workspace:proj-a/session.end"
      """)

      assert {:ok,
              %{
                "principal_id" => "ou_alice",
                "permission" => "workspace:proj-a/session.end",
                "action" => "revoked"
              }} =
               Revoke.execute(%{
                 "args" => %{
                   "principal_id" => "ou_alice",
                   "permission" => "workspace:proj-a/session.end"
                 }
               })

      {:ok, doc} = YamlElixir.read_from_file(path)
      alice = Enum.find(doc["principals"], &(&1["id"] == "ou_alice"))
      assert alice["capabilities"] == ["workspace:proj-a/session.create"]
    end

    test "not held — returns no_matching_capability without touching file",
         %{path: path} do
      File.write!(path, """
      principals:
        - id: ou_alice
          kind: feishu_user
          capabilities:
            - "workspace:proj-a/session.create"
      """)

      before = File.read!(path)

      assert {:error, %{"type" => "no_matching_capability"}} =
               Revoke.execute(%{
                 "args" => %{
                   "principal_id" => "ou_alice",
                   "permission" => "workspace:proj-other/session.end"
                 }
               })

      assert File.read!(path) == before
    end

    test "principal absent — returns no_matching_capability", %{path: path} do
      File.write!(path, """
      principals:
        - id: ou_alice
          kind: feishu_user
          capabilities:
            - "workspace:proj-a/session.create"
      """)

      assert {:error, %{"type" => "no_matching_capability"}} =
               Revoke.execute(%{
                 "args" => %{
                   "principal_id" => "ou_nobody",
                   "permission" => "workspace:proj-a/session.create"
                 }
               })
    end

    test "file missing entirely — returns no_matching_capability", %{path: path} do
      refute File.exists?(path)

      assert {:error, %{"type" => "no_matching_capability"}} =
               Revoke.execute(%{
                 "args" => %{
                   "principal_id" => "ou_alice",
                   "permission" => "workspace:proj-a/session.create"
                 }
               })

      # Revoke must not create a file when there's nothing to revoke.
      refute File.exists?(path)
    end

    test "invalid args — missing permission returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               Revoke.execute(%{"args" => %{"principal_id" => "ou_x"}})
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end
end
