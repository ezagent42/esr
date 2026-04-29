defmodule Esr.SessionsSupervisor do
  @moduledoc """
  DynamicSupervisor hosting all user Sessions. Spec §3.4 D17:
  max_children = 128 (bounds concurrent tmux sessions at 128).

  Overflow behaviour: start_session/1 returns `{:error, :max_children}`;
  surfaced to the user by the SlashHandler as `session limit reached`.
  """

  @behaviour Esr.Role.OTP
  use DynamicSupervisor

  @default_max 128

  def start_link(opts \\ []) do
    max = Keyword.get(opts, :max_children, @default_max)
    DynamicSupervisor.start_link(__MODULE__, max, name: __MODULE__)
  end

  @impl true
  def init(max), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: max)

  @spec start_session(map()) :: {:ok, pid} | {:error, term()}
  def start_session(session_args) do
    DynamicSupervisor.start_child(__MODULE__, {Esr.Session, session_args})
  end

  def stop_session(session_sup_pid) when is_pid(session_sup_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, session_sup_pid)
  end
end
