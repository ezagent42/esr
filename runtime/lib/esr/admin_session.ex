defmodule Esr.AdminSession do
  @moduledoc """
  Top-level permanent Supervisor for AdminSession — the one always-on
  Session hosting session-less peers (FeishuAppAdapter_<app_id>, SlashHandler,
  pool supervisors).

  Bootstrap exception (Risk F, spec §6): AdminSession is started directly
  by `Esr.Supervisor`, NOT by `Esr.SessionRouter` (which doesn't exist
  yet at boot; introduced in PR-3). Children of AdminSession are spawned
  via `Esr.PeerFactory.spawn_peer_bootstrap/4` which bypasses the
  SessionRouter control-plane resolution.

  See spec §3.4 and §6 Risk F.
  """
  use Supervisor

  @default_children_sup_name Esr.AdminSession.ChildrenSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Name of the DynamicSupervisor that hosts admin-scope peers."
  def children_supervisor_name(_admin_sup_name \\ __MODULE__),
    do: Application.get_env(:esr, :admin_children_sup_name, @default_children_sup_name)

  @impl true
  def init(opts) do
    children_sup_name =
      Keyword.get(opts, :children_sup_name, @default_children_sup_name)

    process_name =
      Keyword.get(opts, :process_name, Esr.AdminSessionProcess)

    # Cache the children-sup name so callers can resolve it without
    # plumbing opts through.
    Application.put_env(:esr, :admin_children_sup_name, children_sup_name)

    children = [
      # AdminSessionProcess must start before any admin-scope peer so
      # register_admin_peer/2 can record pids as peers come up.
      {Esr.AdminSessionProcess, [name: process_name]},
      # DynamicSupervisor that hosts admin-scope peers. Empty at init;
      # populated later by `bootstrap_children/0` (P2-9) or test setup.
      {DynamicSupervisor, strategy: :one_for_one, name: children_sup_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Start the VoiceASR/VoiceTTS pools under AdminSession's children
  supervisor. Called from `Esr.Application.start/2` after AdminSession
  is up (Risk F exception — bootstrap bypasses SessionRouter).

  Pool sizes come from `pools.yaml` via `Esr.Pools.pool_max/2`. Each
  `Esr.PeerPool` is registered both as a globally-named process
  (`:voice_asr_pool`, `:voice_tts_pool`) and as an admin peer under
  AdminSessionProcess so session-local proxies can resolve it
  symbolically.

  Returns `:ok` on success; `{:error, _}` if any step fails so the
  caller can decide whether to continue booting with a degraded voice
  plane (missing voice pools are not fatal — the rest of AdminSession
  stays up).

  Expansion P4a-7.
  """
  @spec bootstrap_voice_pools(Path.t() | nil) :: :ok | {:error, term()}
  def bootstrap_voice_pools(pools_yaml_path \\ nil) do
    sup = children_supervisor_name()

    with {:ok, asr_pid} <-
           DynamicSupervisor.start_child(
             sup,
             pool_spec(:voice_asr_pool, Esr.Peers.VoiceASR, pools_yaml_path)
           ),
         :ok <- Esr.AdminSessionProcess.register_admin_peer(:voice_asr_pool, asr_pid),
         {:ok, tts_pid} <-
           DynamicSupervisor.start_child(
             sup,
             pool_spec(:voice_tts_pool, Esr.Peers.VoiceTTS, pools_yaml_path)
           ),
         :ok <- Esr.AdminSessionProcess.register_admin_peer(:voice_tts_pool, tts_pid) do
      :ok
    else
      {:ok, _, _} = ok -> ok
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Start the admin-scope `Esr.Peers.SlashHandler` under AdminSession's
  children supervisor. Called from `Esr.Application.start/2` after
  AdminSession is up (Risk F bootstrap exception — same as voice pools).

  SlashHandler's `init/1` already registers itself under
  `:slash_handler` in `Esr.AdminSessionProcess`, so after this call
  returns `:ok`, `Esr.AdminSessionProcess.slash_handler_ref/0` returns
  `{:ok, pid}`. Without this bootstrap, `FeishuChatProxy`'s slash path
  silently drops every message because no peer is registered.

  Pre-PR-8 T1, SlashHandler was spawned only by integration tests via
  `start_supervised/1` — production never had one. This function closes
  that gap.

  PR-8 T1.
  """
  @spec bootstrap_slash_handler() :: :ok | {:error, term()}
  def bootstrap_slash_handler do
    sup = children_supervisor_name()

    case Esr.PeerFactory.spawn_peer_bootstrap(sup, Esr.Peers.SlashHandler, %{}, []) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Start one `Esr.Peers.FeishuAppAdapter` per `type: feishu` instance
  declared in `adapters.yaml`. Called from `Esr.Application.start/2`
  after `bootstrap_slash_handler` (Risk F bootstrap exception — same
  policy: missing file / spawn failure is logged, not fatal).

  Each peer registers in `Esr.AdminSessionProcess` under
  `:feishu_app_adapter_<instance_id>` (the YAML key — matching the
  Phoenix topic suffix `adapter:feishu/<instance_id>` the Python
  `adapter_runner` joins) so that `EsrWeb.AdapterChannel.forward_to_new_chain/2`
  can route inbound frames. The peer's state additionally carries the
  Feishu-platform `app_id` from `config.app_id` (used for outbound Lark
  REST calls and `workspaces.yaml` `chats[].app_id` matching).

  Idempotent: re-registering an already-running instance is a no-op.
  Unknown adapter types (`cc_tmux`, `cc_mcp`, …) are skipped.

  PR-9 T10.
  """
  @spec bootstrap_feishu_app_adapters(Path.t() | nil) :: :ok
  def bootstrap_feishu_app_adapters(adapters_yaml_path \\ nil) do
    path = adapters_yaml_path || Esr.Paths.adapters_yaml()
    sup = children_supervisor_name()
    require Logger

    if File.exists?(path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(path),
           instances when is_map(instances) <- parsed["instances"] || %{} do
        for {instance_id, row} <- instances,
            row["type"] == "feishu" do
          config = row["config"] || %{}
          app_id = config["app_id"] || instance_id
          spawn_feishu_app_adapter(sup, instance_id, app_id)
        end
      else
        _ -> :ok
      end
    end

    :ok
  end

  @doc """
  PR-L 2026-04-28: terminate the FAA peer for `instance_id`. Counterpart
  to `bootstrap_feishu_app_adapters/1`. Looks up the peer in the
  AdminSession DynamicSupervisor and kills it via `terminate_child/2`.
  Idempotent — returns `:not_found` if the peer isn't running, `:ok`
  otherwise.

  The FAA peer name is `feishu_app_adapter_<instance_id>` (registered
  via `Esr.PeerRegistry` from FeishuAppAdapter.start_link/1).
  """
  @spec terminate_feishu_app_adapter(String.t()) :: :ok | :not_found
  def terminate_feishu_app_adapter(instance_id) when is_binary(instance_id) do
    sup = children_supervisor_name()

    case Esr.PeerRegistry.lookup("feishu_app_adapter_#{instance_id}") do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(sup, pid)
        :ok

      :error ->
        :not_found
    end
  end

  defp spawn_feishu_app_adapter(sup, instance_id, app_id) do
    require Logger

    args = %{
      instance_id: instance_id,
      app_id: app_id,
      neighbors: [],
      proxy_ctx: %{}
    }

    case DynamicSupervisor.start_child(sup, {Esr.Peers.FeishuAppAdapter, args}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "admin_session: feishu_app_adapter spawn failed " <>
            "instance_id=#{inspect(instance_id)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp pool_spec(name, worker_mod, pools_yaml) do
    max = Esr.Pools.pool_max(name, pools_yaml)

    %{
      id: name,
      start: {Esr.PeerPool, :start_link, [[name: name, worker: worker_mod, max: max]]},
      restart: :permanent,
      type: :worker
    }
  end
end
