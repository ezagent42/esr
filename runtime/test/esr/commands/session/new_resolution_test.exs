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
    * When `args["dir"]` or `args["cwd"]` is set (caller supplied an
      explicit cwd; workspace lookup is just a cwd-discovery mechanism so
      no resolution needed) → `:no_resolution_needed`.

  Returns `{:error, %{"type" => "no_workspace_target", ...}}` when none match.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Session.New, as: SessionNew
  alias Esr.Resource.Workspace.Struct
  alias Esr.Session.ChatRouting.Registry, as: ChatReg

  # Helpers to insert a minimal workspace struct into the URI store
  # without touching disk, so tests are isolated and fast.

  defp register_workspace(name, id \\ nil) do
    uuid = id || UUID.uuid4()

    ws = %Struct{
      id: uuid,
      name: name,
      owner: "test-owner",
      location: nil
    }

    # workspace_put/1 does an upsert into the URI store with by-name +
    # by-chat aliases.
    :ok = Esr.Uri.Compat.workspace_put(ws)
    uuid
  end

  defp clean_workspace(name) do
    case Esr.Uri.Compat.uuid_for_workspace_name(name) do
      {:ok, id} -> Esr.Uri.Compat.workspace_delete_by_id(id)
      :not_found -> :ok
    end
  end

  setup do
    # Ensure the relevant GenServers are running (started by Esr.Application).
    assert is_pid(Process.whereis(Esr.Uri.Store))
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
        "app_id" => "cli_chat"
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
      args = %{}

      assert {:error, %{"type" => "no_workspace_target"}} =
               SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: M-5 — no_workspace_target when no chain layer matches.
  #
  # Pre-M-5 this slot held a "fallback to literal 'default'" test. After M-5
  # the literal-default fallback is gone (spec § specificity ladder); only
  # chat-default and user-default fire. Replaced with the negative case.
  # ---------------------------------------------------------------------------

  describe "no_workspace_target error" do
    test "returns structured error when no chain layer matches" do
      # No explicit workspace, no chat context, no user-default link.
      # Even if a literal "default" workspace happens to exist on the
      # registry from prior state, M-5 no longer falls through to it.
      args = %{}

      assert {:error,
              %{
                "type" => "no_workspace_target",
                "message" => msg
              }} = SessionNew.resolve_workspace_if_needed(args)

      # New error message wording (fix/chat-envelope-arg-fallback): points
      # operator at /workspace:bind-chat or /user:use or explicit workspace=
      # arg, names the missing layers explicitly.
      assert msg =~ "no explicit workspace="
      assert msg =~ "no chat-current binding"
      assert msg =~ "no user-default"
      assert msg =~ "/user:use"
      assert msg =~ "/workspace:bind-chat"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5: explicit dir/cwd short-circuits the M-5 chain.
  #
  # 2026-05-12 cutover replaced the legacy "agent-only" short-circuit
  # with a "caller-supplied cwd" short-circuit. Workspace lookup's only
  # purpose is to discover a default cwd; if the caller already supplied
  # one, the chain has nothing to do.
  # ---------------------------------------------------------------------------

  describe "explicit cwd short-circuits (no workspace lookup)" do
    test "explicit dir= short-circuits resolution chain" do
      clean_workspace("default")

      args = %{"agent" => "cc", "dir" => "/tmp/x"}

      assert :no_resolution_needed = SessionNew.resolve_workspace_if_needed(args)
    end

    test "explicit cwd= short-circuits resolution chain" do
      args = %{"agent" => "cc", "cwd" => "/tmp/y"}

      assert :no_resolution_needed = SessionNew.resolve_workspace_if_needed(args)
    end

    test "agent alone (no dir, no cwd, no workspace) does NOT short-circuit" do
      # Regression for the live-bug from 2026-05-12: slash-route's
      # `default: cc` for the agent field used to trip the legacy
      # "agent-only" backdoor, bypassing M-5. With (b) replaced by
      # cwd-only, an args map with agent but no dir/cwd MUST walk M-5.
      args = %{"agent" => "cc"}

      # No chat-default, no user-default for this anonymous args → :no_match.
      assert {:error, %{"type" => "no_workspace_target"}} =
               SessionNew.resolve_workspace_if_needed(args)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6 Task 6.2 — M-5 chain: user-default replaces literal "default"
  # ---------------------------------------------------------------------------

  describe "resolve_workspace_if_needed/1 — M-5 chain (user-default replaces system default)" do
    setup do
      Esr.Test.UserFixture.load_snapshot(
        %{
          "alice" => %Esr.Entity.User.Struct{username: "alice", feishu_ids: ["ou_a"]}
        },
        %{"alice" => "alice-uuid"}
      )

      on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
      :ok
    end

    test "no_workspace_target when no chain layer matches" do
      args = %{"submitter_username" => "alice"}
      # No explicit, no chat-default, no user-default
      assert {:error, %{"type" => "no_workspace_target"}} =
               Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end

    test "user-default wins when chat-default absent" do
      ws = Esr.Test.WorkspaceFixture.build(name: "alice-ws", owner: "alice")
      :ok = Esr.Uri.Compat.workspace_put(ws)
      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws.id)

      args = %{"submitter_username" => "alice"}
      assert {:ok, "alice-ws"} = Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end

    test "literal `default` no longer wins as a fallback" do
      # Even if a workspace named literally `default` exists, it must not be
      # preferred — only chat-default / user-default layers fire.
      ws = Esr.Test.WorkspaceFixture.build(name: "default", owner: "alice")
      :ok = Esr.Uri.Compat.workspace_put(ws)

      # alice has NO user-default link. No chat context.
      args = %{"submitter_username" => "alice"}
      assert {:error, %{"type" => "no_workspace_target"}} =
               Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end

    test "regression: resolver accepts `username` key from slash_handler" do
      # 2026-05-12 register/lookup key parity fix: slash_handler.ex:759
      # injects args["username"] for session_new, but the resolver used
      # to only accept args["submitter_username"]. The mismatch caused
      # the M-5 user-default chain to silently miss for every Feishu
      # /session:new — exactly the live-test failure that day.
      ws = Esr.Test.WorkspaceFixture.build(name: "alice-via-username-key", owner: "alice")
      :ok = Esr.Uri.Compat.workspace_put(ws)
      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws.id)

      args = %{"username" => "alice"}

      assert {:ok, "alice-via-username-key"} =
               Esr.Commands.Session.New.resolve_workspace_if_needed(args)
    end
  end
end
