defmodule Esr.Plugins.Feishu.Commands.SelfBind do
  @moduledoc """
  Slash-only self-bind wrapper for `/feishu:bind`. Reads the caller's
  Feishu open_id from the envelope-injected `args["caller_principal_id"]`,
  delegates to BindUser.

  Any args key not in `@allowed_keys` is rejected as `invalid_args` —
  this gives clear feedback for typos and prevents identity-injection
  via stray keys (e.g. user-supplied `target_principal_id=ou_VICTIM`).
  The whitelist enumerates user-typed keys (`name`) plus envelope-
  injected keys (`caller_principal_id`/`chat_id`/`app_id`/`thread_id`).

  Emits `[:esr, :slash, :feishu, :self_bind]` telemetry on every
  invocation.

  Admin-代-bind takes the BindUser path directly via the `feishu_bind`
  internal_kind (CLI submit, gated by `feishu/user-bind`).
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.BindUser

  @allowed_keys ~w(name caller_principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) when is_map(args) do
    result =
      case Map.keys(args) -- @allowed_keys do
        [] -> do_bind(args)
        extras -> reject_extras(extras)
      end

    :telemetry.execute(
      [:esr, :slash, :feishu, :self_bind],
      %{},
      %{
        name: Map.get(args, "name"),
        caller_principal_id: Map.get(args, "caller_principal_id"),
        result: result_tag(result)
      }
    )

    result
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind requires args (envelope must inject caller_principal_id)"}}

  defp do_bind(%{"name" => name, "caller_principal_id" => p} = args)
       when is_binary(name) and name != "" and is_binary(p) and p != "" do
    args = Map.put(args, "feishu_user_id", p)
    BindUser.execute(%{"args" => args})
  end

  defp do_bind(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind needs args.name; caller ou_xxx is auto-injected from the envelope"}}

  defp reject_extras(extras), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind does not accept: #{Enum.join(extras, ", ")}"}}

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %{"type" => t}}), do: t
  defp result_tag(_), do: :unknown
end
