defmodule Esr.Resource.Media.LocalAddress do
  @moduledoc """
  Single-source helper exposing the bound host:port of the local
  esrd daemon. The Phoenix Endpoint's `:http` config is the SoT
  (see `runtime/lib/esr/application.ex` boot path); this module
  centralizes access so URI builders don't hardcode "localhost".

  Used by:
  - `Esr.Resource.Media.store/3` to build `esr://<env>@<host>/resources/...`
  - Future cross-host resource fetch (out of scope for this PR; the
    helper currently always returns "localhost" as the host part —
    only the port is read from the Endpoint config).

  See spec `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md`
  decisions D2 + the LocalAddress entry in the file inventory.
  """

  @default_port 4001

  @doc """
  Returns the local esrd's `host:port` as a string for URI builders.

  Reads the Phoenix Endpoint :http config for port; host is
  hardcoded "localhost" in MVP (cross-host resolution is future work
  per spec §"Future work").
  """
  @spec host_port() :: String.t()
  def host_port do
    port =
      case EsrWeb.Endpoint.config(:http) do
        opts when is_list(opts) -> Keyword.get(opts, :port, @default_port)
        _ -> @default_port
      end

    "localhost:#{port}"
  end

  @doc """
  Returns the local esrd's environment name (the `<env>` slot in
  `esr://<env>@<host>/...` URIs). Reads `$ESR_INSTANCE` env var;
  defaults to `"default"` when unset.
  """
  @spec env() :: String.t()
  def env do
    System.get_env("ESR_INSTANCE", "default")
  end
end
