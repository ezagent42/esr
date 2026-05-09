defmodule Esr.Commands.Agent.AddChatCurrentFallbackTest do
  @moduledoc """
  fix/chat-envelope-arg-fallback — `Esr.Commands.Agent.Add` accepts the
  envelope-injected `chat_id` + `app_id` and resolves session_id from
  the chat-current binding when the operator omits `session_id=`.

  Mirrors the resolution shape used by `Esr.Commands.Agent.List` and
  `Esr.Commands.Agent.Primary`, both of which already read
  `Esr.Session.ChatRouting.Registry.current_session/2`. /agent:add was
  the lone outlier that required an explicit session_id and hard-failed
  with `invalid_args` against bare slash submissions like
  `/agent:add type=cc name=test-cc`.

  Negative path: when neither session_id NOR resolvable chat-current
  context is present, the new error type is `no_session_target` (not
  generic `invalid_args`) so the operator sees which gate failed.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Agent.Add
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  setup do
    # Same minimal boot the other agent/* tests use — InstanceRegistry +
    # ChatRouting.Registry started under the test supervisor (idempotent
    # if a sibling test already booted them).
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(ChatRouting) do
      nil -> start_supervised!(ChatRouting)
      _ -> :ok
    end

    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  describe "chat-current fallback (no session_id=)" do
    test "resolves session_id from chat-current binding and proceeds" do
      # Bind the chat to a synthetic session_id so the fallback clause
      # has something to resolve to. The actor-spawn path then runs
      # against that sid; without a real Scope.Supervisor up it returns
      # `spawn_failed` — which is fine here, what we're pinning is that
      # /agent:add NO LONGER returns invalid_args / no_session_target
      # when chat-current resolution succeeds.
      chat = "oc_add_fallback"
      app = "esr_helper_add_fallback"
      sid = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      :ok = ChatRouting.attach_session(chat, app, sid)

      cmd = %{
        "args" => %{
          "chat_id" => chat,
          "app_id" => app,
          "type" => "cc",
          "name" => "test-cc-#{:rand.uniform(99_999)}"
        }
      }

      result = Add.execute(cmd)

      # The fallback resolved session_id and recursed into the real
      # execute clause — proven by reaching InstanceRegistry's
      # spawn-attempt error (no Scope here), NOT a `no_session_target`
      # / `invalid_args` short-circuit.
      assert {:error, err} = result
      refute err["type"] == "no_session_target",
             "expected fallback to resolve sid, but got no_session_target"

      refute err["type"] == "invalid_args",
             "expected fallback to resolve sid, but got invalid_args"

      assert err["type"] == "spawn_failed"
    end
  end

  describe "no session target (no chat-current AND no session_id=)" do
    test "returns no_session_target when chat_id+app_id present but unbound" do
      # Chat exists in the envelope but has no current session attached.
      # The new clause matches → ChatRouting.current_session/2 returns
      # :not_found → structured `no_session_target` error.
      cmd = %{
        "args" => %{
          "chat_id" => "oc_add_unbound",
          "app_id" => "esr_helper_add_unbound",
          "type" => "cc",
          "name" => "x"
        }
      }

      assert {:error, %{"type" => "no_session_target", "message" => msg}} =
               Add.execute(cmd)

      assert msg =~ "session_id="
      assert msg =~ "/session:new"
    end

    test "returns no_session_target when no chat_id+app_id are present at all" do
      # Direct admin-CLI submit: no envelope chat context, no session_id.
      # Pre-fix this fell through to the catch-all `invalid_args`. The
      # new behaviour is `no_session_target` so the operator sees which
      # gate failed.
      cmd = %{"args" => %{"type" => "cc", "name" => "x"}}

      assert {:error, %{"type" => "no_session_target", "message" => msg}} =
               Add.execute(cmd)

      assert msg =~ "session_id="
    end
  end

  describe "invalid_args still fires for actually-malformed input" do
    test "missing both type and name returns invalid_args (not no_session_target)" do
      # Reserved for genuinely malformed / empty args — pin this so
      # future changes to the chat-current fallback don't accidentally
      # swallow the catch-all clause's purpose.
      assert {:error, %{"type" => "invalid_args"}} = Add.execute(%{"args" => %{}})
      assert {:error, %{"type" => "invalid_args"}} = Add.execute(%{})
    end
  end
end
