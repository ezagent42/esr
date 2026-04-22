defmodule Esr.Peers.SlashHandler do
  @moduledoc """
  Channel-agnostic slash-command peer. AdminSession-scope (exactly one,
  registered under `:slash_handler` in `Esr.AdminSessionProcess`).

  On `:slash_cmd` from any ChatProxy: parse the command, cast to
  `Esr.Admin.Dispatcher` with a correlation ref, and relay the reply
  back to the originating ChatProxy as `{:reply, text}`.

  Replaces the slash-parsing half of `Esr.Routing.SlashHandler` (which
  stays in place until PR-3 deletes it). Post-P2-17, Feishu slash
  commands route through here unconditionally (the legacy router is
  no longer reachable from `AdapterChannel`).

  Parser enforces spec D11 (`--agent` required on `/new-session`) and
  D13 (`--dir` required) — both are required per the decision-index
  definition in
  `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`.

  Emits admin command kind `session_new` (agent-session create). PR-3
  P3-8 collapsed the legacy `session_new` (branch-worktree) into
  `session_branch_new` and promoted the former `session_agent_new` to
  `session_new`.

  Spec §4.1 SlashHandler card, §5.3, §1.8 D14.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_dispatcher Esr.Admin.Dispatcher

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer.Stateful
  def init(args) do
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, self())

    state = %{
      dispatcher: Map.get(args, :dispatcher, @default_dispatcher),
      session_id: Map.fetch!(args, :session_id),
      # ref -> reply_to_proxy pid
      pending: %{}
    }

    {:ok, state}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream(_, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_, state), do: {:forward, [], state}

  @impl GenServer
  def handle_info({:slash_cmd, envelope, reply_to_proxy}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""
    principal_id = envelope["principal_id"] || "ou_unknown"

    case parse_command(text) do
      {:ok, kind, args} ->
        ref = make_ref()

        cmd = %{
          "id" => generate_id(),
          "kind" => kind,
          "submitted_by" => principal_id,
          "args" => args
        }

        GenServer.cast(
          state.dispatcher,
          {:execute, cmd, {:reply_to, {:pid, self(), ref}}}
        )

        {:noreply, put_in(state.pending[ref], reply_to_proxy)}

      {:error, reason} ->
        send(reply_to_proxy, {:reply, "unknown command: #{reason}"})
        {:noreply, state}
    end
  end

  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        Logger.warning(
          "slash_handler: unknown command_result ref #{inspect(ref)}"
        )

        {:noreply, state}

      {reply_to_proxy, rest} ->
        send(reply_to_proxy, {:reply, format_result(result)})
        {:noreply, %{state | pending: rest}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --------------------------------------------------------------------
  # Parser — D15-compliant tokenization:
  #   /new-session --agent <name> --dir <path>      (both required)
  #   /end-session <session_id>
  #   /list-sessions | /sessions
  #   /list-agents
  # Cap check is the Dispatcher's job, not SlashHandler's.
  # --------------------------------------------------------------------

  defp parse_command("/new-session " <> rest), do: parse_new_session(rest)

  defp parse_command("/new-session"),
    do: {:error, "/new-session requires --agent and --dir"}

  defp parse_command("/end-session " <> rest) do
    case tokenize(rest) do
      [sid | _] -> {:ok, "session_end", %{"session_id" => sid}}
      [] -> {:error, "/end-session requires <session_id>"}
    end
  end

  defp parse_command("/end-session"),
    do: {:error, "/end-session requires <session_id>"}

  defp parse_command("/list-sessions"), do: {:ok, "session_list", %{}}
  defp parse_command("/sessions"), do: {:ok, "session_list", %{}}
  defp parse_command("/list-agents"), do: {:ok, "agent_list", %{}}

  defp parse_command(other),
    do: {:error, inspect(String.slice(other, 0, 32))}

  # --agent <name> --dir <path>; both required per D11/D13.
  defp parse_new_session(rest) do
    toks = tokenize(rest)
    agent = flag_value(toks, "--agent")
    dir = flag_value(toks, "--dir")

    cond do
      is_nil(agent) ->
        {:error, "/new-session requires --agent"}

      is_nil(dir) ->
        {:error,
         "/new-session requires --dir (agent '#{agent}' declares dir required)"}

      true ->
        {:ok, "session_new", %{"agent" => agent, "dir" => dir}}
    end
  end

  defp flag_value(toks, flag) do
    case Enum.drop_while(toks, &(&1 != flag)) do
      [^flag, value | _] -> value
      _ -> nil
    end
  end

  defp tokenize(rest),
    do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  # --------------------------------------------------------------------
  # Result formatting — human-readable text for the ChatProxy reply.
  # --------------------------------------------------------------------

  defp format_result({:ok, %{"branches" => b}}) when is_list(b),
    do: "sessions: " <> Enum.join(b, ", ")

  defp format_result({:ok, %{"session_id" => sid}}),
    do: "session started: #{sid}"

  defp format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)

  # P3-8: Session.New emits string "missing_capabilities" (not atom); match
  # accordingly. Pre-P3-8 the clause matched :missing_capabilities and never
  # fired (see integration/new_session_smoke_test.exs module doc).
  defp format_result({:error, %{"type" => "missing_capabilities", "caps" => caps}}),
    do: "error: missing caps — " <> Enum.join(caps, ", ")

  defp format_result({:error, %{"type" => t}}) when is_binary(t),
    do: "error: " <> t

  defp format_result(other), do: "result: " <> inspect(other)

  defp generate_id,
    do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
end
