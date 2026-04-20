defmodule Esr.Capabilities.Supervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())

    children = [
      Esr.Permissions.Registry,
      # Bootstrap must sit between Registry and Watcher so declared
      # permissions exist before FileLoader.validate/1 checks them.
      Esr.Permissions.Bootstrap,
      Esr.Capabilities.Grants,
      {Esr.Capabilities.Watcher, path: path}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp default_path do
    esrd_home = System.get_env("ESRD_HOME") || Path.expand("~/.esrd")
    Path.join([esrd_home, "default", "capabilities.yaml"])
  end
end
