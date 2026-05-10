defmodule Esr.ChannelTest do
  @moduledoc """
  Tests for the `Esr.Channel` behaviour module.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 1.
  """
  use ExUnit.Case, async: true

  test "Esr.Channel declares the four required callbacks" do
    callbacks = Esr.Channel.behaviour_info(:callbacks)
    assert {:start_link, 1} in callbacks
    assert {:dispatch, 2} in callbacks
    assert {:subscribe, 3} in callbacks
    # config_schema/0 is optional
    optional = Esr.Channel.behaviour_info(:optional_callbacks)
    assert {:config_schema, 0} in optional
  end

  test "a stub impl with all required callbacks compiles + runs" do
    defmodule Esr.ChannelTest.NoOpChannel do
      @behaviour Esr.Channel

      def start_link(_opts) do
        {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
      end

      def dispatch(_pid, _msg), do: :ok
      def subscribe(_pid, _listener, _topic), do: :ok
    end

    assert {:ok, pid} = Esr.ChannelTest.NoOpChannel.start_link([])
    assert is_pid(pid)
    assert :ok = Esr.ChannelTest.NoOpChannel.dispatch(pid, "hello")
    assert :ok = Esr.ChannelTest.NoOpChannel.subscribe(pid, self(), "topic")
  end
end
