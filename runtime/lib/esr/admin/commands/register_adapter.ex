defmodule Esr.Admin.Commands.RegisterAdapter do
  @moduledoc """
  `Esr.Admin.Commands.RegisterAdapter` — persists a new adapter
  instance and hot-loads it post-boot (dev-prod-isolation spec §6.4
  RegisterAdapter).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `register_adapter`-kind command reaches the front of the queue. Pure
  function module (no GenServer) so it can be spawned and discarded.

  ## Flow

    1. Append the instance entry to `<runtime_home>/adapters.yaml` via
       `Esr.Yaml.Writer` under `instances.<name>`. Missing file is
       created with a fresh `%{"instances" => %{...}}` skeleton.
    2. Append `FEISHU_APP_SECRET_<UPPERCASE_NAME>=<secret>` to
       `<runtime_home>/.env.local`. The file is created if missing and
       chmod'd to `0o600` so secrets aren't world-readable.
    3. Call `Esr.WorkerSupervisor.ensure_adapter(type, name, config,
       url)` — same 4-arity API used at boot by
       `Esr.Application.restore_adapters_from_disk/1`.

  ## Result

    * `{:ok, %{"adapter_id" => name, "running" => true}}` — persisted
      + live adapter subprocess (or `:already_running`).
    * `{:error, %{"type" => "invalid_args", ...}}` — malformed args.

  ## Test injection

  `execute/2` accepts an `opts` keyword where `:spawn_fn` mirrors the
  same hook `Esr.Application.restore_adapters_from_disk/2` uses — a
  1-arity function `fn {type, name, config, url} -> :ok | :already_running | {:error, term} end`.
  Tests pass a stub so no real Python subprocess is spawned.

  The Dispatcher always calls `execute/1`, which delegates to
  `execute/2` with the real `Esr.WorkerSupervisor.ensure_adapter/4`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(
        %{"args" => %{"type" => "feishu", "name" => name, "app_id" => app_id, "app_secret" => secret}},
        opts
      )
      when is_binary(name) and is_binary(app_id) and is_binary(secret) do
    adapters_path = Esr.Paths.adapters_yaml()
    env_path = Path.join(Esr.Paths.runtime_home(), ".env.local")

    with :ok <- append_instance_to_yaml(adapters_path, name, app_id),
         :ok <- append_secret_to_env(env_path, name, secret),
         :ok <- spawn_adapter(name, app_id, opts) do
      {:ok, %{"adapter_id" => name, "running" => true}}
    else
      {:error, reason} ->
        {:error,
         %{"type" => "register_adapter_failed", "detail" => inspect(reason)}}
    end
  end

  def execute(_cmd, _opts) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "register_adapter requires args.{type=\"feishu\", name, app_id, app_secret}"
     }}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp append_instance_to_yaml(path, name, app_id) do
    current =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> %{"instances" => %{}}
      end

    instances = Map.get(current, "instances") || %{}

    updated =
      Map.put(current, "instances",
        Map.put(instances, name, %{
          "type" => "feishu",
          "config" => %{"app_id" => app_id}
        })
      )

    Esr.Yaml.Writer.write(path, updated)
  end

  defp append_secret_to_env(path, name, secret) do
    :ok = File.mkdir_p(Path.dirname(path))
    # Touch + chmod BEFORE writing so the window where the file exists
    # without 0600 is as short as possible.
    _ = File.touch(path)
    _ = File.chmod(path, 0o600)

    existing =
      case File.read(path) do
        {:ok, body} -> body
        _ -> ""
      end

    body =
      existing
      |> ensure_trailing_newline()
      |> Kernel.<>("FEISHU_APP_SECRET_#{String.upcase(name)}=#{secret}\n")

    with :ok <- File.write(path, body),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(s) do
    if String.ends_with?(s, "\n"), do: s, else: s <> "\n"
  end

  defp spawn_adapter(name, app_id, opts) do
    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn {type, instance, config, url} ->
        case Esr.WorkerSupervisor.ensure_adapter(type, instance, config, url) do
          :ok -> :ok
          :already_running -> :ok
          {:error, _} = err -> err
          other -> {:error, {:unexpected_ensure_adapter_return, other}}
        end
      end)

    url = Keyword.get(opts, :adapter_ws_url, default_adapter_ws_url())
    config = %{"app_id" => app_id}

    case spawn_fn.({"feishu", name, config, url}) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_spawn_fn_return, other}}
    end
  end

  # Mirrors Esr.Application.default_adapter_ws_url/0 (kept private
  # there). Prefer EsrWeb.Endpoint config at runtime so this lines up
  # with whatever port Phoenix is actually listening on — BUT the
  # admin watcher's orphan-recovery scan can fire this before the
  # Endpoint has booted (Endpoint is the last supervisor child;
  # register_adapter.execute is called from Admin.Supervisor's child
  # init), which would crash with "ETS table not found". Fall back
  # to the static app config, then 4001.
  defp default_adapter_ws_url do
    port =
      try do
        case EsrWeb.Endpoint.config(:http) do
          opts when is_list(opts) -> Keyword.get(opts, :port, nil)
          _ -> nil
        end
      rescue
        ArgumentError -> nil
      end

    port =
      port ||
        case Application.get_env(:esr, EsrWeb.Endpoint, []) do
          http_opts when is_list(http_opts) ->
            case Keyword.get(http_opts, :http, []) do
              http when is_list(http) -> Keyword.get(http, :port, 4001)
              _ -> 4001
            end

          _ ->
            4001
        end

    "ws://127.0.0.1:" <> Integer.to_string(port) <> "/adapter_hub/socket/websocket?vsn=2.0.0"
  end
end
