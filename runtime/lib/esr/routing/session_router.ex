defmodule Esr.Routing.SessionRouter do
  @moduledoc """
  GenServer that dispatches inbound Feishu `msg_received` envelopes
  (spec §6.5, dev-prod-isolation Task 17).

  Two paths:

    1. **Slash commands** (`/new-session`, `/switch-session`,
       `/end-session`, `/sessions` / `/list-sessions`, `/reload`) are
       parsed into the admin-command shape
       `%{"id" => _, "kind" => _, "submitted_by" => _, "args" => %{}}`
       and cast to `Esr.Admin.Dispatcher` with reply-to
       `{:pid, self(), ref}`. On `{:command_result, ref, result}`, the
       Router emits a Feishu `reply` directive via Phoenix.PubSub.

    2. **Non-command messages** are forwarded to the sender's active
       branch by looking up
       `routing["principals"][principal_id]["targets"][active]["esrd_url"]`
       in the on-disk `routing.yaml`, then broadcasting
       `{:forward, envelope}` on the PubSub topic `route:<esrd_url>`.
       Downstream esrd instances subscribe to their own `route:<url>`
       topic in a later task.

  ## PubSub name

  The Phoenix.PubSub name is `EsrWeb.PubSub` — the single PubSub server
  started in `Esr.Application`. The dev-prod-isolation spec references
  it as `Esr.PubSub` but the concrete registered name is `EsrWeb.PubSub`
  (see `application.ex:24`). Same divergence noted in
  `Esr.Admin.Commands.Notify`.

  ## State

      %__MODULE__{
        routing:       map(),  # parsed routing.yaml (or %{} if missing)
        branches:      map(),  # parsed branches.yaml (or %{} if missing)
        pending_refs:  map()   # ref → envelope (for correlating reply)
      }

  ## Subscription

  `init/1` subscribes to the `"msg_received"` topic. No producer is
  currently publishing on this topic — that publisher arrives in a
  later task (the Feishu adapter pushes inbound messages into the
  PeerServer today; a downstream fan-out to `msg_received` is still
  pending). Subscribing eagerly now means the Router is ready the
  moment the publisher is wired up.

  ## ID generation

  `generate_id/0` uses 12 bytes of crypto-strong randomness encoded as
  unpadded Base32 — not a real ULID, but unique enough for the
  `admin_queue/pending/<id>.yaml` naming. Downstream Commands keyed by
  `submitted_by` and `kind` don't depend on ID ordering.
  """

  use GenServer
  require Logger

  defstruct routing: %{}, branches: %{}, pending_refs: %{}

  @pubsub EsrWeb.PubSub
  @msg_topic "msg_received"
  @reply_topic "feishu_reply"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      routing: load_yaml(Path.join(Esr.Paths.runtime_home(), "routing.yaml")),
      branches: load_yaml(Path.join(Esr.Paths.runtime_home(), "branches.yaml"))
    }

    _ = Phoenix.PubSub.subscribe(@pubsub, @msg_topic)

    {:ok, state}
  end

  # ------------------------------------------------------------------
  # Msg-received dispatch
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:msg_received, envelope}, state) when is_map(envelope) do
    text = get_in(envelope, ["payload", "args", "text"]) || ""

    case parse_command(text) do
      {:slash, kind, args} ->
        {:noreply, dispatch_slash(kind, args, envelope, state)}

      :not_command ->
        route_to_active(envelope, state)
        {:noreply, state}
    end
  end

  # Dispatcher reply — correlate by ref, emit reply, drop from state.
  @impl true
  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_refs, ref) do
      {nil, _} ->
        # Unknown ref — log and ignore. Avoids crash if the Dispatcher
        # sends a stale result (e.g. Router was restarted between
        # cast and reply).
        Logger.warning("routing.session_router: unknown command_result ref — ignoring")

        {:noreply, state}

      {envelope, rest} ->
        emit_reply(envelope, format_result(result))
        {:noreply, %{state | pending_refs: rest}}
    end
  end

  # Swallow unknown infos (e.g. late Phoenix.Socket.Broadcast frames
  # if anyone re-uses the topic for a different payload shape).
  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Parser — pure, public for test coverage
  # ------------------------------------------------------------------

  @typedoc "Outcome of parsing a message body against the slash grammar."
  @type parsed ::
          {:slash, kind :: String.t(), args :: map()}
          | :not_command

  @doc """
  Parse a message body into a slash-command tuple or `:not_command`.

  Leading whitespace is NOT stripped — the commands must start at
  column 0. This mirrors Slack/Feishu conventions and prevents
  accidental matches in quoted text.
  """
  @spec parse_command(String.t()) :: parsed()
  def parse_command("/new-session " <> rest), do: parse_session_new(rest)
  def parse_command("/switch-session " <> rest), do: parse_session_switch(rest)
  def parse_command("/end-session " <> rest), do: parse_session_end(rest)
  def parse_command("/sessions"), do: {:slash, "session_list", %{}}
  def parse_command("/list-sessions"), do: {:slash, "session_list", %{}}
  def parse_command("/reload"), do: {:slash, "reload", %{"acknowledge_breaking" => false}}
  def parse_command("/reload " <> rest), do: parse_reload(rest)
  def parse_command(_), do: :not_command

  # ------------------------------------------------------------------
  # Parser internals
  # ------------------------------------------------------------------

  defp parse_session_new(rest) do
    case tokenize(rest) do
      [branch | flags] ->
        {:slash, "session_new",
         %{"branch" => branch, "new_worktree" => "--new-worktree" in flags}}

      [] ->
        :not_command
    end
  end

  defp parse_session_switch(rest) do
    case tokenize(rest) do
      [branch | _] -> {:slash, "session_switch", %{"branch" => branch}}
      [] -> :not_command
    end
  end

  defp parse_session_end(rest) do
    case tokenize(rest) do
      [branch | flags] ->
        {:slash, "session_end", %{"branch" => branch, "force" => "--force" in flags}}

      [] ->
        :not_command
    end
  end

  defp parse_reload(rest) do
    flags = tokenize(rest)
    {:slash, "reload", %{"acknowledge_breaking" => "--acknowledge-breaking" in flags}}
  end

  defp tokenize(rest),
    do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  # ------------------------------------------------------------------
  # Slash path — cast + ref storage
  # ------------------------------------------------------------------

  defp dispatch_slash(kind, args, envelope, state) do
    ref = make_ref()
    principal_id = envelope["principal_id"] || "ou_unknown"

    cmd = %{
      "id" => generate_id(),
      "kind" => kind,
      "submitted_by" => principal_id,
      "args" => args
    }

    GenServer.cast(
      Esr.Admin.Dispatcher,
      {:execute, cmd, {:reply_to, {:pid, self(), ref}}}
    )

    %{state | pending_refs: Map.put(state.pending_refs, ref, envelope)}
  end

  # ------------------------------------------------------------------
  # Non-command path — forward to the active branch's esrd_url
  # ------------------------------------------------------------------

  defp route_to_active(envelope, state) do
    principal_id = envelope["principal_id"]
    active = get_in(state.routing, ["principals", principal_id, "active"])

    target_url =
      active &&
        get_in(state.routing, ["principals", principal_id, "targets", active, "esrd_url"])

    if is_binary(target_url) and target_url != "" do
      Phoenix.PubSub.broadcast(@pubsub, "route:#{target_url}", {:forward, envelope})
    else
      Logger.debug(
        "routing.session_router: no active route for principal=#{inspect(principal_id)}"
      )
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Reply emission — broadcast a Feishu `reply` directive
  # ------------------------------------------------------------------

  defp emit_reply(envelope, text) do
    chat_id = get_in(envelope, ["payload", "args", "chat_id"])

    directive = %{
      "kind" => "reply",
      "args" => %{"chat_id" => chat_id, "text" => text}
    }

    Phoenix.PubSub.broadcast(@pubsub, @reply_topic, {:directive, directive})
    :ok
  end

  # ------------------------------------------------------------------
  # Result formatting — human-readable text for the Feishu reply
  # ------------------------------------------------------------------

  defp format_result({:ok, %{"branch" => br, "port" => port}}),
    do: "session #{br} ready on port #{port}"

  defp format_result({:ok, %{"branches" => branches}}) when is_list(branches),
    do: "sessions: " <> Enum.join(branches, ", ")

  defp format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)
  defp format_result({:ok, other}), do: "ok: " <> inspect(other)

  defp format_result({:error, %{"type" => "unauthorized"}}), do: "error: unauthorized"

  defp format_result({:error, %{"type" => type}}) when is_binary(type),
    do: "error: " <> type

  defp format_result({:error, other}), do: "error: " <> inspect(other)
  defp format_result(other), do: "result: " <> inspect(other)

  # ------------------------------------------------------------------
  # YAML loading — missing file → empty map (not an error)
  # ------------------------------------------------------------------

  defp load_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # ------------------------------------------------------------------
  # ID generation — 12 bytes, unpadded Base32. Unique enough for queue
  # file naming; not a real ULID (lexicographic-sortable by time).
  # ------------------------------------------------------------------

  defp generate_id,
    do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
end
