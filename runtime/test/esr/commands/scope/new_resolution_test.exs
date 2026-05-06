defmodule Esr.Commands.Scope.NewResolutionTest do
  @moduledoc """
  Phase 5.1 + 5.3 — unit tests for `Esr.Commands.Scope.New.resolve_workspace_if_needed/1`.

  These tests exercise the 3-step workspace resolution chain directly via the
  `@doc false` public function, without setting up the full session machinery.

  Resolution order:
    1. Explicit — `args["workspace"]` is non-empty.
    2. Chat default — `ChatScope.Registry.get_default_workspace(chat_id, app_id)`
       returns a UUID → look up workspace by UUID → return its name.
    3. Fallback — "default" workspace exists in NameIndex.

  Short-circuits:
    * When `args["workspace"]` is already set → `:no_resolution_needed`.
    * When `args["agent"]` is set (legacy agent-only mode) → `:no_resolution_needed`.

  Returns `{:error, %{"type" => "no_workspace_resolvable", ...}}` when none match.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Scope.New, as: SessionNew
  alias Esr.Resource.Workspace.{Registry, Struct, NameIndex}
  alias Esr.Resource.ChatScope.Registry, as: ChatReg

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
        clean_workspace("default")
      end)

      # No chat_id in args → lookup_chat_default returns nil → falls through.
      # No "default" workspace registered → :no_match.
      args = %{"dir" => "/tmp/x"}

      assert {:error, %{"type" => "no_workspace_resolvable"}} =
               SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: no workspace + no chat default + "default" workspace exists → fallback
  # ---------------------------------------------------------------------------

  describe "fallback to 'default' workspace" do
    test "resolves to 'default' when no workspace or chat default is set" do
      _uuid = register_workspace("default")

      on_exit(fn -> clean_workspace("default") end)

      args = %{"dir" => "/tmp/x"}

      assert {:ok, "default"} = SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4: no workspace + no chat default + no "default" workspace + no agent
  #         → no_workspace_resolvable
  # ---------------------------------------------------------------------------

  describe "no_workspace_resolvable error" do
    test "returns structured error when none of the three steps match" do
      # Ensure no "default" workspace is registered for this test.
      # (clean_workspace is safe when not present)
      clean_workspace("default")

      args = %{"dir" => "/tmp/x"}

      assert {:error,
              %{
                "type" => "no_workspace_resolvable",
                "message" => msg
              }} = SessionNew.resolve_workspace_if_needed(args)

      assert msg =~ "no workspace specified"
      assert msg =~ "no chat default set"
      assert msg =~ "no \"default\" workspace exists"
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
end
