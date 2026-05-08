defmodule Esr.ActorQueryTest do
  @moduledoc """
  M-1.1 contract test for `Esr.ActorQuery`. Each test uses unique
  session_ids so the global ETS indexes (started in `Esr.Application`)
  stay isolated without explicit teardown.
  """

  use ExUnit.Case, async: true

  describe "find_by_name/2" do
    setup do
      session_id = "test-sess-#{System.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "returns {:ok, pid} for registered (session_id, name)", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "helper-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Entity.Registry.register_attrs(actor_id, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      assert {:ok, pid} = Esr.ActorQuery.find_by_name(sid, name)
      assert pid == self()
    end

    test "returns :not_found when name not registered", %{session_id: sid} do
      assert :not_found == Esr.ActorQuery.find_by_name(sid, "nonexistent-#{sid}")
    end

    test "returns :not_found for different session_id", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "helper-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Entity.Registry.register_attrs(actor_id, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      assert :not_found == Esr.ActorQuery.find_by_name("other-session-#{sid}", name)
    end
  end

  describe "list_by_role/2" do
    setup do
      session_id = "test-sess-#{System.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "returns [] for session with no registrations", %{session_id: sid} do
      assert [] == Esr.ActorQuery.list_by_role(sid, :cc_process)
    end

    test "returns [pid] for single-instance role", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Entity.Registry.register_attrs(actor_id, %{
          session_id: sid,
          name: "a-#{System.unique_integer([:positive])}",
          role: :cc_process
        })

      assert [pid] = Esr.ActorQuery.list_by_role(sid, :cc_process)
      assert pid == self()
    end
  end

  describe "find_by_id/1" do
    test "returns {:ok, pid} for registered actor_id" do
      actor_id = "actor-find-by-id-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Esr.Entity.Registry.register(actor_id, self())
      assert {:ok, pid} = Esr.ActorQuery.find_by_id(actor_id)
      assert pid == self()
    end

    test "returns :not_found for unknown actor_id" do
      assert :not_found ==
               Esr.ActorQuery.find_by_id("nonexistent-#{System.unique_integer([:positive])}")
    end
  end

  describe "M-1 invariant gate (per plan §M-1)" do
    test "register_attrs/2 followed by find_by_name/2 returns {:ok, self()}" do
      sid = "invariant-#{System.unique_integer([:positive])}"
      aid = "actor-invariant-#{System.unique_integer([:positive])}"
      name = "peer-invariant-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Entity.Registry.register_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      assert {:ok, pid} = Esr.ActorQuery.find_by_name(sid, name)
      assert pid == self()
    end
  end
end
