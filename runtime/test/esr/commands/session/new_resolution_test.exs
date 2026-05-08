defmodule Esr.Commands.Session.NewResolutionTest do
  @moduledoc """
  Phase 5.1 / 5.3 + Phase 6 (M-5) — unit tests for
  `Esr.Commands.Session.New.resolve_workspace_if_needed/1`.

  These tests exercise the workspace resolution chain directly via the
  `@doc false` public function, without setting up the full session machinery.

  Resolution order (post-M-5, delegated to `Esr.Commands.Workspace.Resolve`):
    1. Explicit — `args["workspace"]` is non-empty.
    2. Chat default — `ChatScope.Registry.get_default_workspace(chat_id, app_id)`
       returns a UUID → look up workspace by UUID → return its name.
    3. User default — `User.Registry.get_default_workspace(submitter_username)`.

  Pre-M-5 there was a 4th layer "fallback to literal 'default' workspace";
  M-5 removed it (spec § specificity ladder). Test coverage for that
  removal lives in the M-5 describe block at the bottom of this file.

  Short-circuits:
    * When `args["workspace"]` is already set → `:no_resolution_needed`.
    * When `args["agent"]` is set (legacy agent-only mode) → `:no_resolution_needed`.

  Returns `{:error, %{"type" => "no_workspace_resolvable", ...}}` when none match.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Session.New, as: SessionNew
  alias Esr.Resource.Workspace.{Registry, Struct, NameIndex}
  alias Esr.Session.ChatRouting.Registry, as: ChatReg

  @name_index_table :esr_workspace_name_index

  # Helpers to insert a minimal workspace struct into the Registry + NameIndex
  # without touching disk, so tests are isolated and fast.

  defp register_workspace(name, id \\ nil) do
    uuid = id || UUID.uuid4()

    ws = %Struct{
      id: uuid,
      name: name,
      owner: "test-owner",
      location: nil
    }

    # put/1 does an upsert into both ETS tables and calls NameIndex.put.
    :ok = Registry.put(ws)
    uuid
  end

  defp clean_workspace(name) do
    case NameIndex.id_for_name(@name_index_table, name) do
      {:ok, id} -> Registry.delete_by_id(id)
      :not_found -> :ok
    end
  end

  setup do
    # Ensure the relevant GenServers are running (started by Esr.Application).
    assert is_pid(Process.whereis(Registry))
    assert is_pid(Process.whereis(ChatReg))

    :ok
  end

  # ---------------------------------------------------------------------------
  # Test 1: explicit workspace arg → :no_resolution_needed
  # ---------------------------------------------------------------------------

  describe "explicit workspace in args" do
    test "returns :no_resolution_needed — no fallback chain runs" do
      args = %{"workspace" => "ws-explicit", "dir" => "/tmp/x"}

      assert :no_resolution_needed = SessionNew.resolve_workspace_if_needed(args)
    end

    test "non-empty workspace wins even when chat default is set" do
      uuid = register_workspace("ws-chatdef-explicit-conflict")
      :ok = ChatReg.set_default_workspace("oc_explicit", "cli_explicit", uuid)

      on_exit(fn ->
        ChatReg.clear_default_workspace("oc_explicit", "cli_explicit")
        clean_workspace("ws-chatdef-explicit-conflict")
      end)

      args = %{
        "workspace" => "ws-explicit-wins",
        "chat_id" => "oc_explicit",
        "app_id" => "cli_explicit"
      }

      # The explicit workspace short-circuits — no lookup happens.
      assert :no_resolution_needed = SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: no workspace + chat default set → {:ok, chat_default_name}
  # ---------------------------------------------------------------------------

  describe "chat default fallback" do
    test "resolves to the chat-default workspace name" do
      uuid = register_workspace("ws-chatdef")
      :ok = ChatReg.set_default_workspace("oc_chat", "cli_chat", uuid)

      on_exit(fn ->
        ChatReg.clear_default_workspace("oc_chat", "cli_chat")
        clean_workspace("ws-chatdef")
      end)

      args = %{
        "chat_id" => "oc_chat",
        "app_id" => "cli_chat",
        "dir" => "/tmp/x"
      }

      assert {:ok, "ws-chatdef"} = SessionNew.resolve_workspace_if_needed(args)
    end

    test "chat default is ignored when chat_id is absent" do
      uuid = register_workspace("ws-chatdef-no-chatid")
      :ok = ChatReg.set_default_workspace("oc_orphan", "cli_orphan", uuid)

      on_exit(fn ->
        ChatReg.clear_default_workspace("oc_orphan", "cli_orphan")
        clean_workspace("ws-chatdef-no-chatid")
      end)

      # No chat_id in args → chat-default layer skips. No submitter →
      # user-default layer skips. M-5 chain ends in :no_match — even if
      # a literal "default" workspace exists in registry, it's no longer
      # preferred (specificity ladder: chat-default → user-default → error).
      args = %{"dir" => "/tmp/x"}

      assert {:error, %{"type" => "no_workspace_resolvable"}} =
               SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: M-5 — no_workspace_resolvable when no chain layer matches.
  #
  # Pre-M-5 this slot held a "fallback to literal 'default'" test. After M-5
  # the literal-default fallback is gone (spec § specificity ladder); only
  # chat-default and user-default fire. Replaced with the negative case.
  # ---------------------------------------------------------------------------

  describe "no_workspace_resolvable error" do
    test "returns structured error when no chain layer matches" do
      # No explicit workspace, no chat context, no user-default link.
      # Even if a literal "default" workspace happens to exist on the
      # registry from prior state, M-5 no longer falls through to it.
      args = %{"dir" => "/tmp/x"}

      assert {:error,
              %{
                "type" => "no_workspace_resolvable",
                "message" => msg
              }} = SessionNew.resolve_workspace_if_needed(args)

      # New error message wording (spec §): points operator at /user:use
      # or explicit workspace= arg, no longer mentions literal "default".
      assert msg =~ "workspace not specified"
      assert msg =~ "no chat-default set"
      assert msg =~ "no user-default"
      assert msg =~ "/user:use"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5: no workspace + no chat default + agent given → :no_resolution_needed
  #         (legacy "agent-only" mode — admin-CLI paths)
  # ---------------------------------------------------------------------------

  describe "legacy agent-only mode (no workspace)" do
    test "explicit agent short-circuits resolution chain" do
      clean_workspace("default")

      args = %{"agent" => "cc", "dir" => "/tmp/x"}

      # With an agent given and no workspace, resolution is skipped entirely.
      # The downstream execute/2 will proceed with the agent, possibly failing
      # at validate_args(agent, nil) for missing dir or at verify_caps — but
      # NOT with no_workspace_resolvable.
      assert :no_resolution_needed = SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6 Task 6.2 — M-5 chain: user-default replaces literal "default"
  # ---------------------------------------------------------------------------

  describe "resolve_workspace_if_needed/1 — M-5 chain (user-default replaces system default)" do
    setup do
      Esr.Entity.User.Registry.load_snapshot_with_uuids(
        %{
          "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: ["ou_a"]}
        },
        %{"alice" => "alice-uuid"}
      )

      on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
      :ok
    end

    test "no_workspace_resolvable when no chain layer matches" do
      args = %{"submitter_username" => "alice"}
      # No explicit, no chat-default, no user-default
      assert {:error, %{"type" => "no_workspace_resolvable"}} =
               Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end

    test "user-default wins when chat-default absent" do
      ws = Esr.Test.WorkspaceFixture.build(name: "alice-ws", owner: "alice")
      :ok = Esr.Resource.Workspace.Registry.put(ws)
      :ok = Esr.Entity.User.Registry.set_default_workspace("alice", ws.id)

      args = %{"submitter_username" => "alice"}
      assert {:ok, "alice-ws"} = Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end

    test "literal `default` no longer wins as a fallback" do
      # Even if a workspace named literally `default` exists, it must not be
      # preferred — only chat-default / user-default layers fire.
      ws = Esr.Test.WorkspaceFixture.build(name: "default", owner: "alice")
      :ok = Esr.Resource.Workspace.Registry.put(ws)

      # alice has NO user-default link. No chat context.
      args = %{"submitter_username" => "alice"}
      assert {:error, %{"type" => "no_workspace_resolvable"}} =
               Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end
  end
end
