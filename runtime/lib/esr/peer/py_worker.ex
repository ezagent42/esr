defmodule Esr.Peer.PyWorker do
  @moduledoc """
  Peer macro for pool-worker peers that own a Python sidecar spawned
  via `Esr.PyProcess` and use a pending-map to correlate request/reply
  over JSON-line IPC.

  Extracted from the shared boilerplate of `Esr.Peers.VoiceASR` and
  `Esr.Peers.VoiceTTS`. Each peer declares its Python module name via
  `use Esr.Peer.PyWorker, module: "voice_asr"` and supplies one
  callback:

    * `extract_reply/1` — map the sidecar's decoded reply payload into
      the value returned from the peer's public call (e.g.
      `%{"text" => t}` → `{:ok, t}`).

  Peers still write their own public functions (e.g. `transcribe/3`,
  `synthesize/3`) that package call-site args into the
  `{:rpc, payload, timeout}` shape this macro's `handle_call/3`
  consumes.

  Not suitable for stream-style peers like `Esr.Peers.VoiceE2E`, which
  uses `handle_cast` + no id correlation — keep those as hand-rolled
  GenServers.

  ## Test hook

  The PyProcess module used at `init/1` and `send_request/2` is
  resolved via `Application.get_env(:esr, :py_process_module,
  Esr.PyProcess)`, letting tests inject a fake. Default is the real
  `Esr.PyProcess`.

  See PR-6 B2 + spec §4.1 Voice cards.
  """

  @callback extract_reply(map()) :: term()

  defmacro __using__(opts) do
    module_name = Keyword.fetch!(opts, :module)

    quote do
      use Esr.Peer.Stateful
      use GenServer
      @behaviour Esr.Peer.PyWorker

      @py_module_name unquote(module_name)

      @impl GenServer
      def init(_args) do
        py_mod = Application.get_env(:esr, :py_process_module, Esr.PyProcess)

        {:ok, py} =
          py_mod.start_link(%{
            entry_point: {:module, @py_module_name},
            subscriber: self()
          })

        {:ok, %{py: py, pending: %{}}}
      end

      @impl GenServer
      def handle_call({:rpc, payload, _timeout}, from, state) do
        id = Esr.Peer.PyWorker.new_request_id()
        py_mod = Application.get_env(:esr, :py_process_module, Esr.PyProcess)
        :ok = py_mod.send_request(state.py, %{id: id, payload: payload})
        {:noreply, put_in(state.pending[id], from)}
      end

      @impl GenServer
      def handle_info(
            {:py_reply, %{"id" => id, "kind" => "reply", "payload" => payload}},
            state
          ) do
        case Map.pop(state.pending, id) do
          {nil, _} ->
            {:noreply, state}

          {from, rest} ->
            GenServer.reply(from, __MODULE__.extract_reply(payload))
            {:noreply, %{state | pending: rest}}
        end
      end

      def handle_info(_other, state), do: {:noreply, state}

      defoverridable init: 1, handle_call: 3, handle_info: 2
    end
  end

  @doc "Short, ASCII, unique request id for JSON-line wire."
  @spec new_request_id() :: String.t()
  def new_request_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end
end
