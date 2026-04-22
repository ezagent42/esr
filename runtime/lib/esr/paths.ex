defmodule Esr.Paths do
  @moduledoc """
  Filesystem path helpers. Mirrors `py/src/esr/cli/paths.py` semantically.

  Reads `$ESRD_HOME` (default: `~/.esrd`) and `$ESR_INSTANCE` (default:
  `default`); composes runtime-state paths consistently across Elixir
  and Python sides.
  """

  def esrd_home, do: System.get_env("ESRD_HOME") || Path.expand("~/.esrd")

  def current_instance, do: System.get_env("ESR_INSTANCE", "default")

  def runtime_home, do: Path.join(esrd_home(), current_instance())

  def capabilities_yaml, do: Path.join(runtime_home(), "capabilities.yaml")
  def adapters_yaml, do: Path.join(runtime_home(), "adapters.yaml")
  def workspaces_yaml, do: Path.join(runtime_home(), "workspaces.yaml")
  def commands_compiled_dir, do: Path.join([runtime_home(), "commands", ".compiled"])
  def admin_queue_dir, do: Path.join(runtime_home(), "admin_queue")
end
