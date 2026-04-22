defmodule EsrWeb.AdapterChannelFeatureFlagTest do
  use ExUnit.Case, async: false

  test "feature flag USE_NEW_PEER_CHAIN reads from Application env" do
    # Default: false (legacy path)
    Application.put_env(:esr, :use_new_peer_chain, false)
    refute EsrWeb.AdapterChannel.new_peer_chain?()

    Application.put_env(:esr, :use_new_peer_chain, true)
    assert EsrWeb.AdapterChannel.new_peer_chain?()
  after
    Application.delete_env(:esr, :use_new_peer_chain)
  end

  test "ESR_USE_NEW_PEER_CHAIN env var overrides app config" do
    Application.put_env(:esr, :use_new_peer_chain, false)
    System.put_env("ESR_USE_NEW_PEER_CHAIN", "1")
    assert EsrWeb.AdapterChannel.new_peer_chain?()
  after
    System.delete_env("ESR_USE_NEW_PEER_CHAIN")
    Application.delete_env(:esr, :use_new_peer_chain)
  end
end
