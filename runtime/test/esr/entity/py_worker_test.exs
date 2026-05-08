defmodule Esr.Entity.PyWorkerTest do
  @moduledoc """
  PR-6 B2 — `Esr.Entity.PyWorker` macro absorbs the shared pending-map
  + request-id + PyProcess-wiring boilerplate used by pool-worker
  Python sidecar peers.

  Test uses a `FakePyProcess` GenServer injected via the `:esr,
  :py_process_module` app-env override. The macro reads this at init
  time and at `send_request` time so tests can drive reply frames
  synthetically without touching the real Python sidecar.
  """
  use ExUnit.Case, async: false

  defmodule FakePyProcess do
    @moduledoc """
    Minimal PyProcess substitute. Accepts `start_link/1`, records
    every `send_request/2`, and lets tests inject `{:py_reply, _}`
    messages back to the peer via `reply/3`.
    """
    use GenServer

    def start_link(%{subscriber: subscriber}),
      do: GenServer.start_link(__MODULE__, subscriber)

    def send_request(pid, req), do: GenServer.call(pid, {:send_request, req})
    def requests(pid), do: GenServer.call(pid, :requests)

    def reply(pid, id, payload),
      do: GenServer.cast(pid, {:reply, id, payload})

    @impl true
    def init(subscriber), do: {:ok, %{subscriber: subscriber, requests: []}}

    @impl true
    def handle_call({:send_request, req}, _from, state),
      do: {:reply, :ok, %{state | requests: [req | state.requests]}}

    def handle_call(:requests, _from, state),
      do: {:reply, Enum.reverse(state.requests), state}

    @impl true
    def handle_cast({:reply, id, payload}, state) do
      send(
        state.subscriber,
        {:py_reply, %{"id" => id, "kind" => "reply", "payload" => payload}}
      )

      {:noreply, state}
    end
  end

  defmodule EchoPeer do
    @moduledoc "Tiny peer using the macro; echoes replies."
    use Esr.Entity.PyWorker, module: "echo"

    def echo(pid, text, timeout \\ 5_000),
      do: GenServer.call(pid, {:rpc, %{text: text}, timeout}, timeout + 500)

    @impl Esr.Entity.PyWorker
    def extract_reply(%{"echoed" => e}), do: {:ok, e}
    def extract_reply(other), do: {:error, {:unexpected, other}}
  end

  setup do
    Application.put_env(:esr, :py_process_module, FakePyProcess)
    on_exit(fn -> Application.delete_env(:esr, :py_process_module) end)
    :ok
  end

  test "init spawns py with the declared module name and empty pending" do
    {:ok, pid} = EchoPeer.start_link(%{})
    state = :sys.get_state(pid)

    assert is_pid(state.py)
    assert state.pending == %{}

    GenServer.stop(pid)
  end

  test "echo sends a request to the fake PyProcess and resolves on reply" do
    {:ok, pid} = EchoPeer.start_link(%{})
    state = :sys.get_state(pid)
    py = state.py

    # Caller blocks on the reply; drive the reply in a Task.
    caller =
      Task.async(fn -> EchoPeer.echo(pid, "hello", 2_000) end)

    # Wait until the request reaches the fake py process.
    id =
      wait_for_request(py, fn requests ->
        case requests do
          [%{id: id, payload: %{text: "hello"}}] -> id
          _ -> nil
        end
      end)

    FakePyProcess.reply(py, id, %{"echoed" => "hello"})

    assert {:ok, "hello"} = Task.await(caller, 3_000)

    GenServer.stop(pid)
  end

  test "unknown reply id is dropped silently (no crash, pending unchanged)" do
    {:ok, pid} = EchoPeer.start_link(%{})

    # No call issued → pending is empty. Send a bogus reply directly.
    send(pid, {:py_reply, %{"id" => "bogus", "kind" => "reply", "payload" => %{"echoed" => "x"}}})

    # Still alive, pending still empty.
    state = :sys.get_state(pid)
    assert state.pending == %{}

    GenServer.stop(pid)
  end

  test "extract_reply/1 handles unexpected payload shape" do
    {:ok, pid} = EchoPeer.start_link(%{})
    py = :sys.get_state(pid).py

    caller =
      Task.async(fn -> EchoPeer.echo(pid, "oops", 2_000) end)

    id =
      wait_for_request(py, fn
        [%{id: id}] -> id
        _ -> nil
      end)

    FakePyProcess.reply(py, id, %{"weird" => "shape"})

    assert {:error, {:unexpected, %{"weird" => "shape"}}} = Task.await(caller, 3_000)

    GenServer.stop(pid)
  end

  test "concurrent requests resolve by id" do
    {:ok, pid} = EchoPeer.start_link(%{})
    py = :sys.get_state(pid).py

    tasks =
      for t <- ["a", "b", "c", "d"] do
        Task.async(fn -> EchoPeer.echo(pid, t, 3_000) end)
      end

    # Wait for all four requests to arrive at fake py.
    requests =
      wait_for_request(py, fn reqs ->
        if length(reqs) == 4, do: reqs, else: nil
      end)

    # Reply in reversed order — the pending-map must still resolve the
    # right caller.
    Enum.reverse(requests)
    |> Enum.each(fn %{id: id, payload: %{text: t}} ->
      FakePyProcess.reply(py, id, %{"echoed" => t})
    end)

    results = Task.await_many(tasks, 5_000)
    assert Enum.sort(results) == Enum.sort([{:ok, "a"}, {:ok, "b"}, {:ok, "c"}, {:ok, "d"}])

    GenServer.stop(pid)
  end

  # Poll the fake py process's request list until `fun.(requests)`
  # returns a non-nil value, then return that value. Short timeout to
  # avoid hung test hangs.
  defp wait_for_request(py, fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(py, fun, deadline)
  end

  defp do_wait(py, fun, deadline) do
    case fun.(FakePyProcess.requests(py)) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for request"),
          else: (Process.sleep(5); do_wait(py, fun, deadline))

      val ->
        val
    end
  end
end
