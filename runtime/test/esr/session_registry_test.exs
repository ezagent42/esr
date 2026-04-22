defmodule Esr.SessionRegistryTest do
  use ExUnit.Case, async: false

  setup do
    # Esr.SessionRegistry is started by the application supervisor
    # (see Esr.Application). Tests share this singleton.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    :ok
  end

  test "loads agents.yaml and exposes agent_def/1" do
    path = Path.expand("fixtures/agents/simple.yaml", __DIR__)
    :ok = Esr.SessionRegistry.load_agents(path)

    assert {:ok, agent_def} = Esr.SessionRegistry.agent_def("cc")
    assert agent_def.description == "Claude Code"
    assert "session:default/create" in agent_def.capabilities_required
    assert length(agent_def.pipeline.inbound) == 2
  end

  test "returns error for unknown agent" do
    assert {:error, :not_found} = Esr.SessionRegistry.agent_def("nonexistent")
  end

  test "registers session and looks up by chat_thread" do
    :ok = Esr.SessionRegistry.register_session("session-1", %{chat_id: "c1", thread_id: "t1"}, %{})

    assert {:ok, "session-1", _peer_refs} =
             Esr.SessionRegistry.lookup_by_chat_thread("c1", "t1")
  end

  test "reserved field names in agents.yaml trigger WARN log" do
    path = Path.join(System.tmp_dir!(), "reserved_test.yaml")
    File.write!(path, ~S"""
    agents:
      demo:
        description: "demo"
        capabilities_required: []
        pipeline: {inbound: [], outbound: []}
        proxies: []
        params: []
        rate_limits: {}  # reserved
    """)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Esr.SessionRegistry.load_agents(path)
      end)

    assert log =~ "reserved field"
    File.rm!(path)
  end
end
