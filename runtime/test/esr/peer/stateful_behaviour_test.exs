defmodule Esr.Peer.StatefulBehaviourTest do
  @moduledoc """
  P5-6 — Esr.Peer.Stateful must NOT declare @callback init/1.
  init is GenServer's (or Esr.OSProcess's) callback; Stateful owns the
  chain-specific upstream/downstream callbacks only. This guards
  against the conflicting-behaviour compile warning regressing.
  """
  use ExUnit.Case, async: true

  test "Esr.Peer.Stateful does not declare init/1 as a callback" do
    callbacks = Esr.Peer.Stateful.behaviour_info(:callbacks)
    refute {:init, 1} in callbacks,
      "Esr.Peer.Stateful should leave init/1 to GenServer"
  end

  test "Esr.Peer.Stateful still declares handle_upstream/2 and handle_downstream/2" do
    callbacks = Esr.Peer.Stateful.behaviour_info(:callbacks)
    assert {:handle_upstream, 2} in callbacks
    assert {:handle_downstream, 2} in callbacks
  end
end
