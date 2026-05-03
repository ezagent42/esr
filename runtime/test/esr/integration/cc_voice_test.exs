defmodule Esr.Integration.CCVoiceTest do
  @moduledoc """
  P4a-10 — end-to-end for the `cc-voice` agent chain.

  Exercises the three-leg data-plane (voice in → text → voice out):

      FeishuAppAdapter (simulated inbound audio envelope)
            |
            v
      FeishuChatProxy
            |                                         ┌───────────────┐
            v                                         │ voice_asr_pool│
      VoiceASRProxy  ── Entity.Pool.acquire ────────────▶│  worker 1..N  │
            |          transcribe(audio_b64)          └───────────────┘
            v
      CCProxy (stateless)                             ┌───────────────┐
            |                                         │ voice_tts_pool│
            v                                         │  worker 1..N  │
      CCProcess (stubbed handler) ── :reply ──────────│   .           │
            |                                         └───────────────┘
            v
      VoiceTTSProxy ── Entity.Pool.acquire ── synthesize(text) ──▶ audio_b64

  ## Drift — same forward-only build_neighbors/1 limitation as cc_e2e

  `Scope.Router.spawn_pipeline/3` spawns peers in inbound order
  (feishu_chat_proxy → voice_asr → cc_proxy → cc_process →
  pty_process) and `build_neighbors/1` is forward-only — each peer
  only sees peers spawned BEFORE it. Because VoiceASRProxy /
  VoiceTTSProxy / CCProxy are all **stateless** `Peer.Proxy` modules
  (no `start_link/1`), they never get spawned; the router records them
  as `{:proxy_module, Module}` markers in the refs map.

  The test therefore exercises each leg at its proxy boundary directly
  (synthetic-injection pattern, like `cc_e2e_test.exs:295`):
    * `VoiceASRProxy.forward/2` — against the live :voice_asr_pool
      booted by Esr.Application (StubASR → "audio:<len>")
    * `CCProcess` handler stub — echoes text via `handler_module_override`
    * `VoiceTTSProxy.forward/2` — against the live :voice_tts_pool
      (StubTTS → base64 of the input text)

  The VoiceASR / VoiceTTS pools are live in test env because
  `Esr.Application.start/2` calls `Scope.Admin.bootstrap_voice_pools/1`
  regardless of `restore_on_start` (spec P4a-7). Stub engines ship
  today (P4a-1..4); Volcengine deferred to PR-5.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]
  setup :assert_with_grants
  setup :wipe_sessions_on_exit
  @moduletag :integration

  @fixture Path.expand("../fixtures/agents/voice.yaml", __DIR__)

  setup do
    # Voice pools must be live (bootstrapped by Esr.Application); if
    # they aren't the test infra regressed and we want to fail loudly
    # rather than paper over the bug.
    assert is_pid(Process.whereis(:voice_asr_pool))
    assert is_pid(Process.whereis(:voice_tts_pool))

    # "*" grants everything — covers session:default/create,
    # handler:cc_adapter_runner/invoke, peer_pool:voice_asr/acquire,
    # peer_pool:voice_tts/acquire, pty:default/spawn.
    :ok = Esr.TestSupport.Grants.with_principal_wildcard("ou_cc_voice")

    :ok = Esr.SessionRegistry.load_agents(@fixture)

    if Process.whereis(Esr.Scope.Router) == nil do
      start_supervised!(Esr.Scope.Router)
    end

    # VoiceASRProxy / VoiceTTSProxy use the Peer.Proxy capability
    # wrapper — short-circuit to `true` in the process dictionary so
    # the proxy's `@required_cap` check doesn't short-circuit the test.
    Process.put(:esr_cap_test_override, fn _, _ -> true end)

    on_exit(fn ->
      Application.delete_env(:esr, :handler_module_override)
    end)

    :ok
  end

  @tag timeout: 30_000
  test "cc-voice three-leg chain: VoiceASRProxy → CCProcess → VoiceTTSProxy" do
    test_pid = self()
    app_id = "ccv_#{System.unique_integer([:positive])}"
    chat_id = "oc_ccv_#{System.unique_integer([:positive])}"
    thread_id = "om_ccv_#{System.unique_integer([:positive])}"

    # 1. FeishuAppAdapter must exist for FeishuAppProxy target
    # resolution (cc-voice's proxies list).
    admin_children_sup = Esr.Scope.Admin.ChildrenSupervisor

    {:ok, faa} =
      DynamicSupervisor.start_child(
        admin_children_sup,
        {Esr.Entities.FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      if Process.alive?(faa) do
        DynamicSupervisor.terminate_child(admin_children_sup, faa)
      end
    end)

    # 2. Stub CCProcess handler: on {:text, t} emit :reply back with
    # "ack". This is the middle leg (ASR → CC → TTS).
    Application.put_env(
      :esr,
      :handler_module_override,
      {:test_fun,
       fn _mod, payload, _timeout ->
         case payload["event"] do
           %{"kind" => "text", "text" => t} ->
             send(test_pid, {:cc_saw_text, t})
             {:ok, %{"turn" => 1}, [%{"type" => "reply", "text" => "ack"}]}

           other ->
             send(test_pid, {:cc_saw_other, other})
             {:ok, %{}, []}
         end
       end}
    )

    # 3. Spawn the cc-voice session — Scope.Router brings up
    # feishu_chat_proxy + cc_process + pty_process as Stateful;
    # voice_asr, cc_proxy, voice_tts are Proxy-module markers in refs.
    {:ok, sid} =
      Esr.Scope.Router.create_session(%{
        agent: "cc-voice",
        dir: "/tmp",
        principal_id: "ou_cc_voice",
        chat_id: chat_id,
        thread_id: thread_id,
        app_id: app_id,
      })

    assert {:ok, ^sid, refs} =
             Esr.SessionRegistry.lookup_by_chat(chat_id, app_id)

    # Stateful peers are live pids.
    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)
    assert is_pid(refs.pty_process)

    # Stateless proxies (in the yaml `proxies:` list) are symbolic
    # markers in refs. `cc_proxy` is in `inbound:` but CCProxy has no
    # start_link (stateless forwarder) and isn't in `proxies:` either,
    # so session_router silently skips it — expected per PR-3 drift.
    assert {:proxy_module, Esr.Entities.VoiceASRProxy} = refs.voice_asr
    assert {:proxy_module, Esr.Entities.VoiceTTSProxy} = refs.voice_tts
    refute Map.has_key?(refs, :cc_proxy)

    cc_pid = refs.cc_process

    # 4. LEG 1 — VoiceASRProxy: simulate 8 bytes of audio in.
    #    StubASR returns "audio:<len>" where len is len(audio_b64).
    audio_in = "AAAAAAAA"
    asr_ctx = %{
      principal_id: "ou_cc_voice",
      pool_name: :voice_asr_pool,
      acquire_timeout: 5_000
    }

    assert {:ok, "audio:8"} =
             Esr.Entities.VoiceASRProxy.forward({:voice_asr, audio_in}, asr_ctx)

    # 5. LEG 2 — CCProcess middle leg: inject the transcribed text
    #    into CCProcess; stubbed handler emits a :reply with "ack".
    #    We send {:text, _} directly to CCProcess (same synthetic
    #    injection as cc_e2e_test.exs:246).
    send(cc_pid, {:text, "audio:8"})
    assert_receive {:cc_saw_text, "audio:8"}, 5_000

    # 6. LEG 3 — VoiceTTSProxy: synthesize the "ack" reply.
    #    StubTTS returns base64(text) — base64("ack") == "YWNr".
    tts_ctx = %{
      principal_id: "ou_cc_voice",
      pool_name: :voice_tts_pool,
      acquire_timeout: 5_000
    }

    assert {:ok, "YWNr"} =
             Esr.Entities.VoiceTTSProxy.forward({:voice_tts, "ack"}, tts_ctx)

    # 7. Cleanup.
    :ok = Esr.Scope.Router.end_session(sid)

    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat(chat_id, app_id)
  end
end
