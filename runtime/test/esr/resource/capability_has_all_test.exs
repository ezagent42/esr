defmodule Esr.CapabilitiesHasAllTest do
  @moduledoc """
  P3-8.2 — `Esr.Resource.Capability.has_all?/2` batch-verifies every permission
  in a list, returning `:ok` on full coverage or `{:missing, [...]}` with
  the exact gap. Used by `Esr.Admin.Commands.Scope.New` (D18) to cap-check
  the invoking principal against the agent's `capabilities_required` list
  before a Session is created.
  """
  use ExUnit.Case, async: false

  setup do
    prior =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "ou_alice" => ["session:default/create", "pty:default/spawn"]
    })

    on_exit(fn -> Esr.Resource.Capability.Grants.load_snapshot(prior) end)
    :ok
  end

  test "returns :ok when principal has every required permission" do
    assert :ok =
             Esr.Resource.Capability.has_all?(
               "ou_alice",
               ["session:default/create", "pty:default/spawn"]
             )
  end

  test "returns {:missing, [...]} listing gaps" do
    assert {:missing, ["handler:cc_adapter_runner/invoke"]} =
             Esr.Resource.Capability.has_all?(
               "ou_alice",
               ["session:default/create", "handler:cc_adapter_runner/invoke"]
             )
  end

  test "empty list is trivially :ok" do
    assert :ok = Esr.Resource.Capability.has_all?("ou_alice", [])
  end

  test "wildcard grant satisfies every permission" do
    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_wild" => ["*"]})

    assert :ok =
             Esr.Resource.Capability.has_all?(
               "ou_wild",
               ["session:default/create", "pty:default/spawn", "handler:x/invoke"]
             )
  end

  test "unknown principal → every permission missing" do
    assert {:missing, missing} =
             Esr.Resource.Capability.has_all?(
               "ou_unknown",
               ["session:default/create", "pty:default/spawn"]
             )

    assert Enum.sort(missing) == ["session:default/create", "pty:default/spawn"]
  end
end
