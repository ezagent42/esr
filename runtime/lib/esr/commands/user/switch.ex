defmodule Esr.Commands.User.Switch do
  @moduledoc """
  `user_switch` — change the active CLI operator (writes operator.json).

  CLI-only command; no slash entry. Switching the active CLI operator
  from a Feishu envelope makes no semantic sense: envelopes always
  identify the operator from the inbound `user_id`. Slash routes for
  this kind would be a footgun.

  Permission `user.manage` is required (consistent with user_remove);
  the bootstrap-sentinel does NOT bypass this — switching active user
  requires being admin already.

  Spec: docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md § 3.6.
  """

  use Esr.Commands.Meta

  command :user_switch do
    slash         :none
    category      "Users"
    description   "切换当前 CLI operator（写 operator.json；CLI-only）"
    permission    "user.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "目标 username（必须已注册）"

    error :unknown_user,  "user '%{name}' not found"
    error :invalid_args,  "user_switch requires args.name"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    case Esr.Uri.Compat.uuid_for_user_name(name) do
      {:ok, uuid} ->
        write_operator_json(uuid, name)
        {:ok, %{"action" => "switched", "username" => name, "target_principal_id" => uuid}}

      :not_found ->
        Render.error(__MODULE__.command_meta(), :unknown_user, %{name: name})
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp write_operator_json(uuid, name) do
    path = Esr.Paths.operator_json()

    doc = %{
      "schema_version" => 1,
      "caller_principal_id" => uuid,
      "name" => name,
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "set_by" => "user_switch"
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(doc, pretty: true))
  end
end
