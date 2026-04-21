defmodule Esr.Launchd.PortWriter do
  @moduledoc "Writes the Phoenix-bound port to $ESRD_HOME/<instance>/esrd.port on start."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # NOTE: `Esr.Paths` does not exist yet (lands in Task 6 of DI-1). Until
    # then, fall back to direct env reads. When `Esr.Paths` lands, defaults
    # migrate to `Esr.Paths.esrd_home()` / `Esr.Paths.current_instance()`.
    esrd_home =
      Keyword.get(opts, :esrd_home) ||
        System.get_env("ESRD_HOME") ||
        Path.expand("~/.esrd")

    instance =
      Keyword.get(opts, :instance) ||
        System.get_env("ESR_INSTANCE", "default")

    port = Keyword.get(opts, :port) || resolve_bound_port()

    path = Path.join([esrd_home, instance, "esrd.port"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Integer.to_string(port))
    Logger.info("launchd: wrote port #{port} to #{path}")
    {:ok, %{path: path, port: port}}
  end

  defp resolve_bound_port do
    # Bandit-bound port read-back. Falls back to configured port.
    case EsrWeb.Endpoint.config(:http) do
      opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
      _ -> 4001
    end
  end
end
