defmodule Esr.Integration.VoiceE2ETest do
  @moduledoc """
  P4a-10 — end-to-end for the `voice-e2e` agent.

  Flow:
    FeishuAppAdapter (simulated inbound audio frame)
      → FeishuChatProxy (session_id hit via SessionRegistry)
      → VoiceE2E (per-session, owns voice_e2e Python sidecar)
      → streams {:voice_chunk, _, seq} + :voice_end back to subscriber

  Subscriber is the test pid. `VoiceE2E.start_link/1` defaults
  `:subscriber` to `self()` (the DynamicSupervisor that hosts the
  peer), so the test patches the live state via `:sys.replace_state/2`
  to route chunks to the test pid instead. Idiomatic test-only
  instrumentation — no production code touched.

  Uses the stub voice_e2e Python engine (ships today per P4a-4), so the
  integration exercises the real PyProcess → sidecar → PyProcess round
  trip without depending on Volcengine.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  @fixture Path.expand("../fixtures/agents/voice.yaml", __DIR__)

  setup do
    # App-level singletons booted by Esr.Application.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    assert is_pid(Process.whereis(Esr.Capabilities.Grants))

    # "*" grants everything so any downstream cap checks pass.
    prior_grants = snapshot_grants()

    :ok =
      Esr.Capabilities.Grants.load_snapshot(
        Map.put(prior_grants, "ou_voice_e2e", ["*"])
      )

    :ok = Esr.SessionRegistry.load_agents(@fixture)

    # SessionRouter is not booted by the Application in PR-3 (drift
    # note in session_router.ex moduledoc). Start it under the test
    # supervisor so each test gets a clean instance.
    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    on_exit(fn ->
      Esr.Capabilities.Grants.load_snapshot(prior_grants)

      # Wipe any Sessions started by this test so
      # Esr.SessionsSupervisor stays clean for sibling tests.
      case Process.whereis(Esr.SessionsSupervisor) do
        nil ->
          :ok

        sup ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(sup) do
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end
      end
    end)

    :ok
  end

  @tag timeout: 15_000
  test "voice-e2e session receives 3 stream_chunk messages + :voice_end" do
    chat_id = "oc_voice_e2e_#{System.unique_integer([:positive])}"
    thread_id = "om_voice_e2e_#{System.unique_integer([:positive])}"

    {:ok, sid} =
      Esr.SessionRouter.create_session(%{
        agent: "voice-e2e",
        principal_id: "ou_voice_e2e",
        chat_id: chat_id,
        thread_id: thread_id
      })

    # Resolve VoiceE2E pid from SessionRegistry refs.
    assert {:ok, ^sid, refs} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)

    voice_pid = refs[:voice_e2e]
    assert is_pid(voice_pid)
    assert Process.alive?(voice_pid)

    # Patch the subscriber field to the test pid so chunks land here.
    # VoiceE2E.start_link defaults :subscriber to self() (the
    # DynamicSupervisor) because spawn_peer goes through
    # DynamicSupervisor.start_child, so we must override after spawn.
    #
    # Note: `:sys.replace_state/2` runs the mutator function INSIDE the
    # target GenServer process, so we capture the test pid in a closure
    # rather than calling self() inside the mutator (which would bind
    # to the GenServer itself and silently drop all replies).
    test_pid = self()
    :sys.replace_state(voice_pid, fn s -> %{s | subscriber: test_pid} end)

    # Synthetic-injection at the peer boundary: call VoiceE2E.turn/2
    # directly. Stub voice_e2e sidecar emits 3 stream_chunk frames +
    # stream_end for any input. Base64("hello") = "aGVsbG8=".
    :ok = Esr.Peers.VoiceE2E.turn(voice_pid, "aGVsbG8=")

    for seq <- 0..2 do
      assert_receive {:voice_chunk, _audio_b64, ^seq}, 3_000
    end

    assert_receive :voice_end, 3_000

    # Cleanup via SessionRouter.
    :ok = Esr.SessionRouter.end_session(sid)

    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end
end
