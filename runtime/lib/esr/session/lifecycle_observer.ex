defmodule Esr.Session.LifecycleObserver do
  @moduledoc """
  Per-session DOWN-watcher process. Spawned alongside each session by
  `Esr.Session.AgentSpawner.do_create/1` AFTER a successful
  pipeline-integrity check (Task 2.5). Lives under the TOP-LEVEL
  `Esr.Session.LifecycleObservers` DynamicSupervisor, NOT under the
  session subtree it watches — that's the point: when the session
  subtree dies, the observer survives just long enough to:

    1. Emit a chat-visible `:session_terminated` error via
       `Esr.Entity.FeishuAppAdapter.reply_chat_error/4` (FCP-free path,
       Task 3.6a).
    2. Detach the session from the chat-routing slot via
       `Esr.Session.ChatRouting.Registry.detach_session/3`.

  Then `{:stop, :normal, state}` so the LifecycleObservers DynSup
  cleans up automatically.

  Spec: §4.6. Plan: PR-3 Task 3.7.
  """

  use GenServer
  require Logger

  @type args :: %{
          required(:session_id) => String.t(),
          required(:session_sup_pid) => pid(),
          required(:chat_id) => String.t(),
          required(:app_id) => String.t()
        }

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(
        %{
          session_id: sid,
          session_sup_pid: sup_pid,
          chat_id: chat_id,
          app_id: app_id
        } = args
      )
      when is_binary(sid) and is_pid(sup_pid) and is_binary(chat_id) and
             is_binary(app_id) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(%{session_sup_pid: sup_pid} = state) do
    Process.monitor(sup_pid)
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning(
      "lifecycle_observer: session=#{state.session_id} supervisor exited reason=#{inspect(reason)} " <>
        "— emitting chat-visible :session_terminated reply + detaching routing"
    )

    # Best-effort chat reply. FAA.reply_chat_error/4 returns :ok even
    # when no FAA is registered (it logs + drops). The observer must
    # not crash on missing FAA — the session is already dead.
    _ =
      Esr.Entity.FeishuAppAdapter.reply_chat_error(
        state.chat_id,
        state.app_id,
        :session_terminated,
        "session #{state.session_id} 异常终止: #{inspect(reason)}"
      )

    # Clean the chat-routing slot. Idempotent — safe if the AgentSpawner
    # teardown path already detached.
    _ =
      Esr.Session.ChatRouting.Registry.detach_session(
        state.chat_id,
        state.app_id,
        state.session_id
      )

    {:stop, :normal, state}
  end

  # Any other message is unexpected — log + ignore so the observer
  # never traps and stays focused on its single responsibility.
  def handle_info(other, state) do
    Logger.debug(
      "lifecycle_observer: session=#{state.session_id} ignoring unexpected message: #{inspect(other)}"
    )

    {:noreply, state}
  end
end
