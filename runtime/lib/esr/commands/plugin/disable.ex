defmodule Esr.Commands.Plugin.Disable do
  @moduledoc """
  `/plugin disable <name>` — remove `name` from plugins.yaml.

  Track 0 Task 0.6. Takes effect after restart.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, term()}

  @spec execute(map()) :: result()
  def execute(cmd) do
    name = cmd["args"]["name"] || cmd[:args][:name] || ""

    if name == "" do
      {:ok, %{"text" => "usage: /plugin disable <name>"}}
    else
      case Esr.Plugin.PluginsYaml.disable(name) do
        :ok ->
          {:ok,
           %{
             "text" =>
               "disabled plugin: #{name}\nrestart esrd to take effect: " <>
                 "`scripts/esrd.sh restart`"
           }}

        {:error, reason} ->
          {:ok, %{"text" => "failed to write plugins.yaml: #{inspect(reason)}"}}
      end
    end
  end
end
