defmodule Esr.Test.NoopCommand do
  @moduledoc """
  Test-only `Esr.Role.Control` implementation. Used by slash-route
  registry tests as a generic, always-loadable sentinel module
  reference — any test that needs *some* concrete `command_module:`
  value but doesn't care about the actual logic should use this.

  Replaces ad-hoc use of `Esr.Commands.Notify` (which is now a real
  feishu-plugin command and shouldn't be reused as a test fixture).
  """

  @behaviour Esr.Role.Control

  @spec execute(map()) :: {:ok, map()}
  def execute(_cmd) do
    {:ok, %{"action" => "noop"}}
  end
end
