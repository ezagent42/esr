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

  @behaviour Esr.Role.Control

  alias Esr.Entity.User.NameIndex

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    case NameIndex.id_for_name(:esr_user_name_index, name) do
      {:ok, uuid} ->
        write_operator_json(uuid, name)
        {:ok, %{"action" => "switched", "username" => name, "principal_id" => uuid}}

      :not_found ->
        {:error, %{"type" => "unknown_user", "message" => "user '#{name}' not found"}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{"type" => "invalid_args", "message" => "user_switch requires args.name"}}
  end

  defp write_operator_json(uuid, name) do
    path = Esr.Paths.operator_json()

    doc = %{
      "schema_version" => 1,
      "principal_id" => uuid,
      "name" => name,
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "set_by" => "user_switch"
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(doc, pretty: true))
  end
end
