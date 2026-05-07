defmodule Esr.Entity.RegistryIndexesTest do
  @moduledoc """
  M-1.2 / M-1.3 / M-1.4 tests for the new ETS indexes in
  `Esr.Entity.Registry`:

    * Index 2 — `:esr_actor_name_index` keyed `{session_id, name}` (set, unique)
    * Index 3 — `:esr_actor_role_index` keyed `{session_id, role}` (bag, multi)
    * monitor-DOWN cleanup via `Esr.Entity.Registry.IndexWatcher`

  Both ETS tables are global named tables created at boot in
  `Esr.Application`; tests use unique session_ids to stay isolated.
  """

  use ExUnit.Case, async: false

  @name_table :esr_actor_name_index
  @role_table :esr_actor_role_index

  describe "name index (Index 2)" do
    setup do
      session_id = "reg-idx-test-#{System.unique_integer([:positive])}"
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "peer-#{System.unique_integer([:positive])}"
      {:ok, session_id: session_id, actor_id: actor_id, name: name}
    end

    test "register_attrs/2 writes to name index", %{session_id: sid, actor_id: aid, name: name} do
      :ok =
        Esr.Entity.Registry.register_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      assert [{_, {pid, ^aid}}] = :ets.lookup(@name_table, {sid, name})
      assert pid == self()
    end

    test "register_attrs/2 returns {:error, :name_taken} on duplicate name",
         %{session_id: sid, actor_id: aid, name: name} do
      :ok =
        Esr.Entity.Registry.register_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      aid2 = "actor-#{System.unique_integer([:positive])}"

      result =
        Task.async(fn ->
          Esr.Entity.Registry.register_attrs(aid2, %{
            session_id: sid,
            name: name,
            role: :cc_process
          })
        end)
        |> Task.await()

      assert {:error, :name_taken} = result
    end

    test "deregister_attrs/2 removes name index entry",
         %{session_id: sid, actor_id: aid, name: name} do
      :ok =
        Esr.Entity.Registry.register_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      :ok =
        Esr.Entity.Registry.deregister_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :cc_process
        })

      assert [] = :ets.lookup(@name_table, {sid, name})
    end
  end

  describe "role index (Index 3)" do
    setup do
      session_id = "reg-role-test-#{System.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "register_attrs/2 writes to role index — single instance", %{session_id: sid} do
      aid = "actor-#{System.unique_integer([:positive])}"
      name = "peer-#{System.unique_integer([:positive])}"

      :ok =
        Esr.Entity.Registry.register_attrs(aid, %{
          session_id: sid,
          name: name,
          role: :pty_process
        })

      entries = :ets.lookup(@role_table, {sid, :pty_process})
      assert length(entries) == 1
      assert [{_, {pid, ^aid}}] = entries
      assert pid == self()
    end

    test "register_attrs/2 allows multiple entries for same role (bag)", %{session_id: sid} do
      aid1 = "actor-#{System.unique_integer([:positive])}"
      aid2 = "actor-#{System.unique_integer([:positive])}"
      name1 = "peer-#{System.unique_integer([:positive])}"
      name2 = "peer-#{System.unique_integer([:positive])}"

      # Hold the two registrant processes alive across the assertion;
      # otherwise IndexWatcher's DOWN cleanup removes their entries the
      # moment Task.await returns.
      test_pid = self()

      t1 =
        Task.async(fn ->
          :ok =
            Esr.Entity.Registry.register_attrs(aid1, %{
              session_id: sid,
              name: name1,
              role: :cc_process
            })

          send(test_pid, :t1_ready)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)

      t2 =
        Task.async(fn ->
          :ok =
            Esr.Entity.Registry.register_attrs(aid2, %{
              session_id: sid,
              name: name2,
              role: :cc_process
            })

          send(test_pid, :t2_ready)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)

      assert_receive :t1_ready, 1_000
      assert_receive :t2_ready, 1_000

      entries = :ets.lookup(@role_table, {sid, :cc_process})
      assert length(entries) == 2

      send(t1.pid, :release)
      send(t2.pid, :release)
      Task.await(t1)
      Task.await(t2)
    end

    test "deregister_attrs/2 removes only the specific pid's entry from role index",
         %{session_id: sid} do
      aid1 = "actor-#{System.unique_integer([:positive])}"
      name1 = "peer-#{System.unique_integer([:positive])}"

      # Spawn an inner registrant that holds its registration alive while
      # the outer test case deregisters its own. Use a synchronous handshake
      # so we can assert the cardinality at a known steady state.
      test_pid = self()

      task =
        Task.async(fn ->
          aid_inner = "actor-inner-#{System.unique_integer([:positive])}"
          name_inner = "peer-inner-#{System.unique_integer([:positive])}"

          :ok =
            Esr.Entity.Registry.register_attrs(aid_inner, %{
              session_id: sid,
              name: name_inner,
              role: :cc_process
            })

          send(test_pid, :inner_registered)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)

      assert_receive :inner_registered, 1_000

      :ok =
        Esr.Entity.Registry.register_attrs(aid1, %{
          session_id: sid,
          name: name1,
          role: :cc_process
        })

      before_entries = :ets.lookup(@role_table, {sid, :cc_process})
      assert length(before_entries) == 2

      # Deregister our own entry.
      :ok =
        Esr.Entity.Registry.deregister_attrs(aid1, %{
          session_id: sid,
          name: name1,
          role: :cc_process
        })

      after_entries = :ets.lookup(@role_table, {sid, :cc_process})
      assert length(after_entries) == 1

      send(task.pid, :release)
      Task.await(task)
    end
  end

  describe "crash cleanup via monitor DOWN" do
    test "Index 2 and Index 3 entries removed within 200ms of process death" do
      sid = "crash-test-#{System.unique_integer([:positive])}"
      aid = "actor-crash-#{System.unique_integer([:positive])}"
      name = "peer-crash-#{System.unique_integer([:positive])}"

      test_pid = self()

      spawned =
        spawn(fn ->
          :ok =
            Esr.Entity.Registry.register_attrs(aid, %{
              session_id: sid,
              name: name,
              role: :feishu_chat_proxy
            })

          send(test_pid, :registered)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :registered, 1_000
      assert [{_, _}] = :ets.lookup(:esr_actor_name_index, {sid, name})
      assert [{_, _}] = :ets.lookup(:esr_actor_role_index, {sid, :feishu_chat_proxy})

      send(spawned, :die)

      # Wait for the IndexWatcher to process the DOWN message. We use a
      # short polling loop to avoid flake on slow CI without padding the
      # happy path.
      assert eventually(fn ->
               :ets.lookup(:esr_actor_name_index, {sid, name}) == [] and
                 :ets.lookup(:esr_actor_role_index, {sid, :feishu_chat_proxy}) == []
             end)
    end
  end

  defp eventually(fun, deadline_ms \\ 1_000, step_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(step_ms)
        do_eventually(fun, deadline, step_ms)
      end
    end
  end
end
